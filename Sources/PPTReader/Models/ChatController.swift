import AppKit
import Observation

/// 讲解面板的对话逻辑：组织上下文、流式请求、自动讲解、保存记录。
@MainActor
@Observable
final class ChatController {
    private(set) var isStreaming = false
    private(set) var hasMessages = false
    var draft = ""
    /// 递增以请求输入框获得焦点。
    private(set) var focusRequest = 0

    @ObservationIgnored let web = ChatWebBridge()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let stats: StatsStore
    @ObservationIgnored private var messages: [ChatMessage] = []
    @ObservationIgnored private var thread: ChatThread?
    @ObservationIgnored private weak var reader: ReaderModel?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamingID: UUID?
    @ObservationIgnored private var streamIsAuto = false
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var flushPending = false
    @ObservationIgnored private var lastPageSave: Task<Void, Never>?

    init(settings: AppSettings, store: ChatStore, stats: StatsStore) {
        self.settings = settings
        self.store = store
        self.stats = stats
        web.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - 课件切换

    func attach(reader: ReaderModel, thread: ChatThread) {
        interruptForSwitch()
        self.reader = reader
        self.thread = thread
        messages = thread.messages
        hasMessages = !messages.isEmpty
        pushAll()
        if settings.autoExplain { scheduleAutoExplain(delay: 1.0) }
    }

    func detach() {
        interruptForSwitch()
        reader = nil
        thread = nil
        messages = []
        hasMessages = false
        pushAll()
    }

    func pageDidChange(_ page: Int) {
        thread?.lastPage = page
        lastPageSave?.cancel()
        lastPageSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.persist()
        }
        if settings.autoExplain { scheduleAutoExplain(delay: settings.autoExplainDelay) }
    }

    func autoExplainToggled() {
        if settings.autoExplain {
            scheduleAutoExplain(delay: 0.2)
        } else {
            autoTask?.cancel()
        }
    }

    func requestFocus() { focusRequest += 1 }

    /// 切换课件时保存正在生成的回答，避免旧课件的对话丢失。
    private func interruptForSwitch() {
        autoTask?.cancel()
        if let id = streamingID, let index = messages.firstIndex(where: { $0.id == id }) {
            if messages[index].content.isEmpty && (messages[index].reasoning ?? "").isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].stopped = true
                record(messages[index], at: index)
            }
            persist()
        }
        stop()
    }

    // MARK: - 发送

    func perform(_ intent: ChatIntent) {
        guard let reader else { return }
        if isStreaming {
            guard streamIsAuto else { return }
            stop()
        }
        var isAuto = false
        if case .explainPage(let auto) = intent { isAuto = auto }
        if !isAuto { autoTask?.cancel() }

        let message = PromptBuilder.userMessage(for: intent, page: reader.currentPage)
        append(message)
        startStream(auto: isAuto)
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming || streamIsAuto else { return }
        let selection = reader?.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        perform(.question(text, selection: selection?.isEmpty == false ? selection : nil))
        reader?.pdf.clearSelection()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func clear() {
        stop()
        messages = []
        hasMessages = false
        persist()
        pushAll()
    }

    private func retry(_ id: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .assistant else { return }
        let removed = messages[index]
        messages.remove(at: index)
        web.call("PPT.remove", removed.id.uuidString)
        // 只有当它前面是用户消息时才重新请求
        guard index > 0, messages[index - 1].role == .user, index == messages.count else { return }
        startStream(auto: messages[index - 1].isAuto)
    }

    // MARK: - 流式请求

    /// - Parameter withImage: 是否附上当前页截图（模型拒绝图片后会以 false 重试）。
    private func startStream(auto: Bool, withImage: Bool = true) {
        guard let reader else { return }
        let image = withImage && settings.sendsImages ? reader.currentPageImage() : nil
        let context = PromptBuilder.Context(
            title: reader.title,
            pageCount: reader.pageCount,
            currentPage: reader.currentPage,
            text: reader.text,
            charLimit: settings.contextCharLimit,
            historyLimit: settings.historyLimit,
            pageImageJPEG: image,
            explanationStyle: settings.explanationStyle
        )
        let payload = PromptBuilder.requestMessages(history: messages, context: context)

        let config = settings.connection
        var reply = ChatMessage(role: .assistant, content: "")
        reply.model = config.model
        streamingID = reply.id
        streamIsAuto = auto
        isStreaming = true
        append(reply)

        let id = reply.id
        let sentImage = image != nil
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
        streamTask = Task { [weak self] in
            var failure: Error?
            do {
                for try await event in OpenAIClient.stream(config: config, messages: body) {
                    self?.apply(event, to: id)
                }
            } catch {
                failure = error
            }
            self?.finish(id, auto: auto, error: failure, retryWithoutImage: sentImage ? config.model : nil)
        }
    }

    private func apply(_ event: StreamEvent, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .reasoning(let text): messages[index].reasoning = (messages[index].reasoning ?? "") + text
        case .content(let text): messages[index].content += text
        case .usage(let usage): messages[index].usage = usage
        }
        scheduleFlush(id)
    }

    /// - Parameter retryWithoutImage: 本次请求附带了截图时为模型名；若模型拒绝图片，去掉截图自动重试一次。
    private func finish(_ id: UUID, auto: Bool, error: Error?, retryWithoutImage model: String?) {
        let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        // 被打断的旧请求可能晚于新请求结束，此时不能清掉新请求的状态
        if streamingID == id {
            streamTask = nil
            streamingID = nil
            isStreaming = false
        }
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        if cancelled {
            let isEmpty = messages[index].content.isEmpty && (messages[index].reasoning ?? "").isEmpty
            if isEmpty {
                // 没有任何输出就被打断（例如翻页取消了自动讲解）：连同提问一起撤回
                messages.remove(at: index)
                web.call("PPT.remove", id.uuidString)
                if auto, index > 0, messages[index - 1].role == .user {
                    let question = messages.remove(at: index - 1)
                    web.call("PPT.remove", question.id.uuidString)
                }
                hasMessages = !messages.isEmpty
                persist()
                return
            }
            messages[index].stopped = true
        } else if let error {
            if let model, (error as? APIError)?.isBadRequest == true, messages[index].content.isEmpty {
                // 这个模型不支持图片：记下来，之后不再发送截图，并立即重试
                settings.markNoVision(model)
                messages.remove(at: index)
                web.call("PPT.remove", id.uuidString)
                startStream(auto: auto, withImage: false)
                return
            }
            messages[index].error = error.localizedDescription
        }
        record(messages[index], at: index)
        push(messages[index])
        persist()
    }

    /// 计入学习统计：只统计有内容的回答。
    private func record(_ reply: ChatMessage, at index: Int) {
        guard reply.error == nil, !reply.content.isEmpty, let thread,
              index > 0, messages[index - 1].role == .user else { return }
        let question = messages[index - 1]
        stats.recordReply(deck: thread.sourcePath, page: question.page, model: reply.model,
                          kind: question.explainsPage != nil ? .explain : .question,
                          usage: reply.usage, at: reply.createdAt)
    }

    // MARK: - 自动讲解

    private func scheduleAutoExplain(delay: Double) {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.settings.autoExplain, let reader = self.reader else { return }
            let page = reader.currentPage
            let alreadyExplained = self.messages.contains { $0.explainsPage == page }
            guard !alreadyExplained, self.settings.hasAPIKey else { return }
            if self.isStreaming && !self.streamIsAuto { return }
            self.perform(.explainPage(auto: true))
        }
    }

    // MARK: - 网页同步

    private func handle(_ event: WebEvent) {
        switch event {
        case .ready:
            pushAll()
        case .gotoPage(let page):
            reader?.pdf.go(to: page)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .retry(let id):
            retry(id)
        case .regenerate(let id):
            if let message = messages.first(where: { $0.id == id }), message.role == .assistant { retry(id) }
        case .quick(let action):
            perform(.quick(action))
        case .contextMenu(let info):
            showContextMenu(info)
        case .figure(let payload):
            FigurePreview.shared.show(payload, from: web.webView.window)
        }
    }

    /// 讲解区右键菜单：根据点击位置（选中文字、链接、页码、消息）组合菜单项。
    private func showContextMenu(_ info: WebContextInfo) {
        var groups: [[PopMenuItem]] = []
        if !info.selection.isEmpty {
            let text = info.selection
            groups.append([
                PopMenuItem(tr("拷贝", "Copy"), icon: "doc.on.doc", shortcut: "⌘C") { Self.copy(text) },
                PopMenuItem(tr("引用到输入框", "Quote in reply"), icon: "text.quote") { [weak self] in self?.quote(text) },
            ])
        }
        if let page = info.page {
            groups.append([PopMenuItem(tr("跳转到第 \(page) 页", "Go to page \(page)"), icon: "arrow.turn.down.right") { [weak self] in self?.reader?.pdf.go(to: page) }])
        }
        if let link = info.link {
            groups.append([
                PopMenuItem(tr("在浏览器中打开", "Open in browser"), icon: "safari") { NSWorkspace.shared.open(link) },
                PopMenuItem(tr("拷贝链接", "Copy link"), icon: "link") { Self.copy(link.absoluteString) },
            ])
        }
        if let id = info.messageID, let message = messages.first(where: { $0.id == id }) {
            if info.isAssistant {
                var group = [PopMenuItem(tr("拷贝整条回答", "Copy answer"), icon: "doc.on.clipboard", enabled: !message.content.isEmpty) { Self.copy(message.content) }]
                if message.id == messages.last?.id {
                    group.append(PopMenuItem(tr("重新生成", "Regenerate"), icon: "arrow.clockwise", enabled: !isStreaming) { [weak self] in self?.retry(id) })
                }
                groups.append(group)
            } else {
                groups.append([PopMenuItem(tr("拷贝提问", "Copy question"), icon: "doc.on.clipboard") { Self.copy(message.content) }])
            }
        }
        let items = groups.enumerated().flatMap { index, group in index == 0 ? group : [.separator] + group }
        PopMenu.shared.show(items, placement: .at(info.point), in: web.webView.window)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 把讲解中的一段话以引用形式放进输入框。
    private func quote(_ text: String) {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        draft = quoted + "\n\n" + draft
        requestFocus()
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        hasMessages = true
        web.call("PPT.upsert", dto(message), ["scroll": true])
        if message.role == .user { persist() }
    }

    private func scheduleFlush(_ id: UUID) {
        guard !flushPending else { return }
        flushPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.flushPending = false
            if let message = self.messages.first(where: { $0.id == id }) { self.push(message) }
        }
    }

    private func push(_ message: ChatMessage) {
        web.call("PPT.upsert", dto(message))
    }

    func pushAll() {
        web.call("PPT.reset", ["messages": messages.map(dto), "meta": meta()])
    }

    func pushMeta() {
        web.call("PPT.setMeta", meta())
    }

    private func meta() -> [String: Any] {
        [
            "title": reader?.title ?? "",
            "pageCount": reader?.pageCount ?? 0,
            "currentPage": reader?.currentPage ?? 0,
            "hasDocument": reader != nil,
            "hasKey": settings.hasAPIKey,
            "fontSize": settings.chatFontSize,
            "serif": settings.chatSerif,
            "lang": Localizer.shared.code,
        ]
    }

    private func dto(_ message: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "content": message.content,
            "auto": message.isAuto,
            "streaming": message.id == streamingID,
            "stopped": message.stopped,
        ]
        if let reasoning = message.reasoning { dict["reasoning"] = reasoning }
        if let page = message.page { dict["page"] = page }
        if let model = message.model, !model.isEmpty { dict["model"] = model }
        if let selection = message.selection { dict["selection"] = selection }
        if let error = message.error { dict["error"] = error }
        if let usage = message.usage {
            dict["usage"] = ["prompt": usage.prompt, "completion": usage.completion, "cacheHit": usage.cacheHit ?? 0]
        }
        return dict
    }

    private func persist() {
        guard var thread else { return }
        thread.messages = messages
        thread.updatedAt = Date()
        self.thread = thread
        store.save(thread)
    }
}
