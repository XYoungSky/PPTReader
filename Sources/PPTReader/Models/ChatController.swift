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
    /// 当前课件所属的课程文件夹（课程说明按它保存）。
    private(set) var course: URL?
    /// 最近一次请求的上下文组成与缓存情况，显示在面板顶部（参考 Claude Code 的 /context、/usage）。
    private(set) var report: ContextReport?
    /// 较早对话整理成的学习记录。
    private(set) var record: StudyRecord?
    /// 正在整理学习记录。
    private(set) var isRecording = false

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
    @ObservationIgnored private var recordTask: Task<Void, Never>?
    /// 标识当前的整理任务：被取消的旧任务结束时，不能清掉之后新开始的任务。
    @ObservationIgnored private var recordToken: UUID?
    /// 上次整理失败时要覆盖到的消息：同一目标不再反复尝试，等下一次丢弃时再整理。
    @ObservationIgnored private var recordFailedThrough: UUID?
    /// 正在生成的回答上显示的临时状态（读取课件、整理记录、重新连接）。
    @ObservationIgnored private var statuses: [UUID: String] = [:]

    init(settings: AppSettings, store: ChatStore, stats: StatsStore) {
        self.settings = settings
        self.store = store
        self.stats = stats
        web.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - 课件切换

    func attach(reader: ReaderModel, thread: ChatThread, course: URL) {
        interruptForSwitch()
        self.reader = reader
        self.thread = thread
        self.course = course
        messages = thread.messages
        record = thread.record
        report = nil
        hasMessages = !messages.isEmpty
        pushAll()
        if settings.autoExplain { scheduleAutoExplain(delay: 1.0) }
    }

    func detach() {
        interruptForSwitch()
        reader = nil
        thread = nil
        course = nil
        messages = []
        record = nil
        report = nil
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
        cancelRecord()
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
        cancelRecord()
        messages = []
        record = nil
        report = nil
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

    /// 一次请求的可调整项。请求因参数问题被拒绝时，按 `recovery` 调整后重试。
    private struct Attempt {
        var withImage = true
        var sendMaxTokens = true
        /// 上下文超长又读不出真实上限时，按比例缩小预算。
        var budgetScale = 1.0
        var retries = 0
        /// 原因不明时试探着去掉了截图 / max_tokens：重试成功后才记下来，避免误判后永久生效。
        var guessedNoVision = false
        var guessedNoMaxTokens = false
    }

    /// 已经组装好的请求，以及出错时判断原因、成功后校准估算需要的信息。
    private struct PreparedRequest {
        var body: Data
        var optionalParameters: [String]
        var maxTokens: Int?
        var sentImage: Bool
        /// 不含截图的 token 估算（未经校准）。
        var estimatedTokens: Int
    }

    /// 没有学到上限时 max_tokens 最多发这么多：足够长的讲解，又不至于在按 max_tokens 计算限额的服务上占用太多。
    private static let defaultMaxOutput = 32_768

    private func startStream(auto: Bool, attempt: Attempt = Attempt()) {
        guard let reader, let questionIndex = messages.indices.last, messages[questionIndex].role == .user else { return }
        let questionID = messages[questionIndex].id
        // 截图取提问时所在的页（重新生成时读者可能已经翻到别处）
        let page = messages[questionIndex].page ?? reader.currentPage
        let config = settings.connection

        var reply = ChatMessage(role: .assistant, content: "")
        reply.model = config.model
        streamingID = reply.id
        streamIsAuto = auto
        isStreaming = true
        append(reply)
        let id = reply.id

        streamTask = Task { [weak self] in
            var failure: Error?
            var prepared: PreparedRequest?
            do {
                // 课件文字还没提取出来时先等一等，否则系统提示里没有课件，之后也无法和后续请求共用缓存
                if reader.promptText == nil { self?.setStatus(tr("正在读取课件文字…", "Reading the deck…"), for: id) }
                await reader.waitForPromptText()
                try Task.checkCancellation()
                guard let self else { return }
                let request = try await self.prepare(questionID: questionID, replyID: id, page: page, config: config, attempt: attempt)
                prepared = request
                for try await event in OpenAIClient.stream(config: config, body: request.body) {
                    self.apply(event, to: id)
                }
            } catch {
                failure = error
            }
            self?.finish(id, auto: auto, error: failure, config: config, attempt: attempt, request: prepared)
        }
    }

    /// 组装请求：截图、上下文、max_tokens 和这个模型已知的限制。
    private func prepare(questionID: UUID, replyID: UUID, page: Int, config: ConnectionConfig, attempt: Attempt) async throws -> PreparedRequest {
        guard let reader else { throw CancellationError() }
        // 较早的对话要被丢掉时，先整理成学习记录（通常回答结束后已在后台整理好；
        // 刚升级、上次整理被打断等情况在这里补上）
        if settings.compactHistory, let questionIndex = messages.firstIndex(where: { $0.id == questionID }) {
            if recordTask == nil { startRecordIfNeeded(end: questionIndex, config: config) }
            if recordTask != nil {
                setStatus(tr("正在整理较早的对话…", "Condensing earlier messages…"), for: replyID)
                while recordTask != nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                setStatus(nil, for: replyID)
            }
        }
        let image = attempt.withImage && settings.sendsImages ? await reader.pageImage(page) : nil
        try Task.checkCancellation()
        guard let questionIndex = messages.firstIndex(where: { $0.id == questionID }) else { throw CancellationError() }

        let quirks = settings.quirks(config.providerID, config.model)
        let tokenScale = quirks.tokenScale ?? 1
        let context = makeContext(reader, config: config, image: image, budgetScale: attempt.budgetScale)
        // 记下这条提问实际发出的文字，之后原样作为历史发送（重新生成时按当前的讲解方式重写）
        messages[questionIndex].sentText = PromptBuilder.composeText(messages[questionIndex], context: context)
        persist()
        let built = PromptBuilder.requestMessages(history: Array(messages[historyStart...questionIndex]), context: context)

        // max_tokens：把上下文窗口里输入用剩的部分留给回答（留 10% 余量），并受这个模型已知的上限约束。
        // 不发送时服务商用自己的默认值，往往远小于留出的空间，回答容易被截断。
        var maxTokens: Int?
        if attempt.sendMaxTokens, quirks.maxOutput != 0 {
            let window = settings.contextWindow(config.providerID, config.model)
            let input = Int(Double(built.estimatedTokens) * tokenScale) + (image == nil ? 0 : TokenEstimate.image)
            let room = window - input * 11 / 10 - 512
            if room >= 1_024 { maxTokens = min(room, quirks.maxOutput ?? Self.defaultMaxOutput) }
        }
        let options = OpenAIClient.RequestOptions(maxTokens: maxTokens, omit: Set(quirks.omit), cacheKey: cacheKey)
        let body = try OpenAIClient.makeBody(config: config, messages: built.messages, options: options)
        report = ContextReport(breakdown: built.breakdown, budget: context.tokenBudget ?? 0,
                               window: settings.contextWindow(config.providerID, config.model), tokenScale: tokenScale,
                               requestedAt: Date(), cacheLifetime: config.cacheLifetime,
                               previousCacheHitRate: report?.cacheHitRate)
        return PreparedRequest(body: body.data, optionalParameters: body.optionalParameters, maxTokens: maxTokens,
                               sentImage: image != nil, estimatedTokens: built.estimatedTokens)
    }

    /// 一次请求的上下文：课件、学习档案、学习记录和预算。正式请求和整理学习记录共用，保证两者的前缀一致。
    private func makeContext(_ reader: ReaderModel, config: ConnectionConfig, image: Data?, budgetScale: Double = 1) -> PromptBuilder.Context {
        let tokenScale = settings.quirks(config.providerID, config.model).tokenScale ?? 1
        // 估算偏低的模型按校准系数缩小预算，让实际用量仍落在设置的比例内
        let budget = Int(Double(settings.contextTokenBudget) * budgetScale / tokenScale)
        var context = PromptBuilder.Context(
            title: reader.title,
            pageCount: reader.pageCount,
            currentPage: reader.currentPage,
            text: reader.promptText,
            latestText: reader.text,
            charLimit: settings.contextCharLimit,
            historyLimit: settings.historyLimit,
            tokenBudget: budget,
            pageImageJPEG: image,
            explanationStyle: settings.explanationStyle
        )
        context.profile = String(settings.learnerProfile.prefix(AppSettings.profileLimit))
        context.courseNotes = course.map { settings.courseNotes(for: $0) } ?? ""
        context.record = record?.text
        context.recordAllowance = settings.compactHistory ? PromptBuilder.recordAllowance : 0
        return context
    }

    /// 历史从学习记录之后开始；更早的消息已经整理进记录。
    private var historyStart: Int {
        guard let id = record?.throughID, let index = messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return index + 1
    }

    /// 同一份课件的请求共用的缓存路由键（只发给 OpenAI）。
    private var cacheKey: String? {
        thread.map { "pptreader-" + AppPaths.hash($0.sourcePath) }
    }

    private func apply(_ event: StreamEvent, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .reasoning(let text): messages[index].reasoning = (messages[index].reasoning ?? "") + text
        case .content(let text): messages[index].content += text
        case .usage(let usage): messages[index].usage = usage
        case .finish(let reason): messages[index].truncated = reason == "length" ? true : nil
        case .retrying(let attempt, let total):
            statuses[id] = tr("连接中断，正在重试（\(attempt)/\(total)）…", "Connection lost, retrying (\(attempt)/\(total))…")
        }
        if case .retrying = event {} else { statuses[id] = nil }
        scheduleFlush(id)
    }

    private func setStatus(_ text: String?, for id: UUID) {
        statuses[id] = text
        if let message = messages.first(where: { $0.id == id }) { push(message) }
    }

    // MARK: - 学习记录

    /// 如果下一次请求会丢掉较早的对话，就在后台把它们整理成学习记录。
    /// - Parameter end: 参与判断的消息到这里为止（不含）；默认为全部消息。
    private func startRecordIfNeeded(end: Int? = nil, config: ConnectionConfig) {
        guard settings.compactHistory, recordTask == nil, let reader, let thread else { return }
        let end = end ?? messages.count
        let start = historyStart
        guard start < end else { return }
        let past = Array(messages[start..<end])
        let context = makeContext(reader, config: config, image: nil)
        guard let last = PromptBuilder.lastDroppedMessage(past: past, context: context),
              last.id != recordFailedThrough else { return }
        let covered = (record?.messageCount ?? 0) + (past.firstIndex { $0.id == last.id }.map { $0 + 1 } ?? past.count)
        let request = PromptBuilder.recordRequest(past: past, context: context)
        let quirks = settings.quirks(config.providerID, config.model)
        let options = OpenAIClient.RequestOptions(maxTokens: quirks.maxOutput == 0 ? nil : min(8_192, quirks.maxOutput ?? 8_192),
                                                  omit: Set(quirks.omit), cacheKey: cacheKey)
        guard let body = try? OpenAIClient.makeBody(config: config, messages: request.messages, options: options) else { return }

        isRecording = true
        let source = thread.sourcePath
        let token = UUID()
        recordToken = token
        recordTask = Task { [weak self] in
            var text = ""
            var usage: TokenUsage?
            var failed = false
            do {
                for try await event in OpenAIClient.stream(config: config, body: body.data) {
                    switch event {
                    case .content(let chunk): text += chunk
                    case .usage(let value): usage = value
                    default: break
                    }
                }
            } catch {
                failed = true
            }
            guard let self, self.recordToken == token else { return }
            defer {
                self.recordTask = nil
                self.recordToken = nil
                self.isRecording = false
            }
            guard !Task.isCancelled, self.thread?.sourcePath == source else { return }
            self.stats.recordReply(deck: source, page: nil, model: config.model, kind: .housekeeping, usage: usage, at: Date())
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !failed, !trimmed.isEmpty else {
                // 整理失败就照旧丢弃较早的对话，下一次需要丢弃时再试
                self.recordFailedThrough = last.id
                return
            }
            self.record = StudyRecord(text: String(trimmed.prefix(PromptBuilder.recordCharLimit)), throughID: last.id, messageCount: covered)
            self.persist()
        }
    }

    /// 清除学习记录：之前整理掉的消息重新作为历史，下次超出上限时再整理。
    func clearRecord() {
        cancelRecord()
        record = nil
        recordFailedThrough = nil
        persist()
    }

    private func cancelRecord() {
        recordTask?.cancel()
        recordTask = nil
        recordToken = nil
        isRecording = false
    }

    private func finish(_ id: UUID, auto: Bool, error: Error?, config: ConnectionConfig, attempt: Attempt, request: PreparedRequest?) {
        let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        // 被打断的旧请求可能晚于新请求结束，此时不能清掉新请求的状态
        if streamingID == id {
            streamTask = nil
            streamingID = nil
            isStreaming = false
        }
        statuses[id] = nil
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
            if messages[index].content.isEmpty, let next = recovery(for: error, config: config, attempt: attempt, request: request) {
                messages.remove(at: index)
                web.call("PPT.remove", id.uuidString)
                startStream(auto: auto, attempt: next)
                return
            }
            messages[index].error = error.localizedDescription
        } else {
            learn(from: messages[index], config: config, attempt: attempt, request: request)
            report?.usage = messages[index].usage
            // 趁学生读回答的时候，把下一次请求要丢掉的较早对话整理好
            startRecordIfNeeded(config: config)
        }
        record(messages[index], at: index)
        push(messages[index])
        persist()
    }

    /// 请求因参数问题被拒绝（400 类）时，判断原因并给出调整后的重试；不该重试时返回 nil。
    /// 原因明确的（图片、上下文超长、max_tokens、不认识的参数）立即记下；原因不明的先试探，成功后再记。
    private func recovery(for error: Error, config: ConnectionConfig, attempt: Attempt, request: PreparedRequest?) -> Attempt? {
        guard attempt.retries < 3, let apiError = error as? APIError, apiError.isBadRequest, let request else { return nil }
        let model = config.model
        var next = attempt
        next.retries += 1
        next.guessedNoVision = false
        next.guessedNoMaxTokens = false
        switch apiError.requestProblem(sentParameters: request.optionalParameters, maxTokens: request.maxTokens) {
        case .image:
            guard request.sentImage else { return nil }
            settings.markNoVision(model)
            next.withImage = false
        case .contextLength(let limit):
            // 读到了真实上限就按它重算；否则（多半是本地估算偏低）缩小预算
            if limit.map({ settings.recordContextLimit($0, config.providerID, model) }) != true {
                guard next.budgetScale > 0.3 else { return nil }
                next.budgetScale *= 0.7
            }
        case .maxTokens(let limit):
            guard request.maxTokens != nil else { return nil }
            settings.updateQuirks(config.providerID, model) { $0.maxOutput = limit ?? 0 }
        case .unsupported(let parameter):
            settings.updateQuirks(config.providerID, model) { $0.omit.append(parameter) }
        case nil:
            // 原因不明：依次试探去掉截图、去掉 max_tokens（每次只改一项，才知道是哪一项的问题）
            if request.sentImage && !attempt.guessedNoVision && attempt.withImage {
                next.withImage = false
                next.guessedNoVision = true
            } else if request.maxTokens != nil {
                next.withImage = attempt.guessedNoVision ? true : attempt.withImage
                next.sendMaxTokens = false
                next.guessedNoMaxTokens = true
            } else {
                return nil
            }
        }
        return next
    }

    /// 请求成功后：确认试探的结果，并用真实的 prompt token 数校准估算。
    private func learn(from reply: ChatMessage, config: ConnectionConfig, attempt: Attempt, request: PreparedRequest?) {
        guard !reply.content.isEmpty else { return }
        if attempt.guessedNoVision { settings.markNoVision(config.model) }
        if attempt.guessedNoMaxTokens { settings.updateQuirks(config.providerID, config.model) { $0.maxOutput = 0 } }
        // 截图的 token 数各家算法差别很大，只用不带截图的请求来校准
        if let request, !request.sentImage, let usage = reply.usage {
            settings.calibrate(config.providerID, config.model, actual: usage.prompt, estimate: request.estimatedTokens)
        }
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
        case .continueAnswer(let id):
            // 只有最后一条回答被截断时才能接着写
            if messages.last?.id == id, messages.last?.truncated == true, !isStreaming { perform(.continuation) }
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
            "truncated": message.truncated == true,
        ]
        if let reasoning = message.reasoning { dict["reasoning"] = reasoning }
        if let page = message.page { dict["page"] = page }
        if let model = message.model, !model.isEmpty { dict["model"] = model }
        if let selection = message.selection { dict["selection"] = selection }
        if let error = message.error { dict["error"] = error }
        if let status = statuses[message.id] { dict["status"] = status }
        if let usage = message.usage {
            dict["usage"] = ["prompt": usage.prompt, "completion": usage.completion, "cacheHit": usage.cacheHit ?? 0,
                             "cacheWrite": usage.cacheWrite ?? 0]
        }
        return dict
    }

    private func persist() {
        guard var thread else { return }
        thread.messages = messages
        thread.record = record
        thread.updatedAt = Date()
        self.thread = thread
        store.save(thread)
    }
}

/// 最近一次请求的上下文组成与缓存情况。
struct ContextReport: Equatable {
    var breakdown: PromptBuilder.Breakdown
    /// 设置允许的输入预算（已按校准系数换算成估算单位）。
    var budget: Int
    var window: Int
    var tokenScale: Double
    var requestedAt: Date
    /// 服务商缓存大约能保留多久；为空表示较长或不清楚。
    var cacheLifetime: TimeInterval?
    /// 这次回答结束前，沿用上一次的命中率显示。
    var previousCacheHitRate: Double?
    var usage: TokenUsage?

    /// 估算的实际输入 token（按校准系数换算）。
    var estimatedTokens: Int { Int(Double(breakdown.total) * tokenScale) }

    /// 输入占上下文窗口的比例：有真实用量时用真实值。
    var windowFraction: Double {
        let used = usage.map { Double($0.prompt) } ?? Double(estimatedTokens)
        return window > 0 ? min(used / Double(window), 1) : 0
    }

    var cacheHitRate: Double? {
        guard let usage, usage.prompt > 0, let hit = usage.cacheHit else { return previousCacheHitRate }
        return Double(hit) / Double(usage.prompt)
    }

    /// 距离上次请求已经超过缓存的保留时间，下一问大概率要全价重算。
    func cacheLikelyExpired(at date: Date) -> Bool {
        guard let lifetime = cacheLifetime else { return false }
        return date.timeIntervalSince(requestedAt) > lifetime
    }
}
