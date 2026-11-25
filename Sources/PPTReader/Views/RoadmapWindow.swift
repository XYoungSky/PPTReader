import AppKit
import WebKit

/// 学习路线图：单独的面板，可以放在课件旁边一直开着；点节点时主窗口跳到对应的页。
/// 第一次打开某份课件时生成大纲（调用一次模型），之后读缓存；进度从对话记录算出，随提问和翻页更新。
@MainActor
final class RoadmapWindow: NSObject {
    static let shared = RoadmapWindow()

    private var panel: FigurePanel?
    private var webView: FigureWebView?
    private var isReady = false
    /// 最近一次要显示的内容，网页加载好之前先存着。
    private var pending: (function: String, payload: [String: Any])?
    /// 正在显示的课件（路径）和它的大纲。
    private var deck: String?
    private var outline: [OutlineNode]?
    /// 正在生成大纲的课件。换了课件也不取消：已经花了的 token 不白花，生成好就存进缓存。
    private var generating: [String: Task<Void, Never>] = [:]
    /// 每份课件最近的生成进度，换回来时接着显示。
    private var stages: [String: RoadmapBuilder.Stage] = [:]

    private var model: AppModel? { SettingsWindow.model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        if !panel.isVisible { place(panel) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        refresh(generateIfMissing: true)
    }

    /// 换了课件：窗口开着时显示新课件的路线图。没有缓存时不自动生成（要调用模型），等用户点“生成”。
    func deckDidChange() {
        guard isVisible else { return }
        refresh(generateIfMissing: false)
    }

    /// 提问或翻页之后更新进度，不重建大纲。
    func progressDidChange() {
        guard isVisible, outline != nil, let model, let reader = model.reader, model.chat.deckPath == deck else { return }
        send("Roadmap.setProgress", ["touched": model.chat.touchedPages.sorted(), "current": reader.currentPage], remember: false)
    }

    // MARK: - 内容

    private func refresh(generateIfMissing: Bool) {
        guard let model, let reader = model.reader, let path = model.chat.deckPath else {
            deck = nil
            outline = nil
            showStatus("noDeck", message: tr("打开一份课件后，这里会显示它的学习路线图。", "Open a deck to see its study roadmap here."))
            return
        }
        if path != deck {
            deck = path
            outline = nil
        }
        if outline != nil {
            showOutline()
            return
        }
        if generating[path] != nil {
            showStatus("loading", message: (stages[path] ?? .part(1, of: 1)).message)
            return
        }
        showStatus("loading", message: tr("正在读取课件…", "Reading the deck…"))
        generating[path] = Task { [weak self] in
            await reader.waitForPromptText()
            guard let self else { return }
            defer { self.generating[path] = nil; self.stages[path] = nil }
            guard let text = reader.promptText else {
                if self.deck == path { self.showError(RoadmapBuilder.Failure.noText) }
                return
            }
            let keys = RoadmapCache.keys(text: text, file: reader.sourceURL)
            if let cached = RoadmapCache.shared.load(keys) {
                self.loaded(cached, for: path)
                return
            }
            guard generateIfMissing else {
                if self.deck == path {
                    self.showStatus("empty", message: tr("这份课件还没有路线图。生成时会把课件文字交给“生成路线图大纲”任务的模型整理一次，之后读缓存。",
                                                         "This deck has no roadmap yet. Generating sends the deck's text to the Roadmap outline model once; after that it's cached."),
                                    action: tr("生成路线图", "Generate roadmap"))
                }
                return
            }
            await self.generate(text: text, keys: keys, reader: reader, path: path)
        }
    }

    private func generate(text: DocumentText, keys: RoadmapCache.Keys, reader: ReaderModel, path: String) async {
        guard let model else { return }
        do {
            let outline = try await RoadmapBuilder.generate(
                text: text, title: reader.title, pageCount: reader.pageCount, settings: model.settings, stats: model.stats, deck: path
            ) { [weak self] stage in
                guard let self else { return }
                self.stages[path] = stage
                if self.deck == path { self.showStatus("loading", message: stage.message) }
            }
            RoadmapCache.shared.save(outline, keys)
            loaded(outline, for: path)
        } catch {
            guard !(error is CancellationError), deck == path else { return }
            showError(error)
        }
    }

    private func loaded(_ outline: [OutlineNode], for path: String) {
        guard deck == path else { return }
        self.outline = outline
        showOutline()
    }

    /// 重新生成：删掉缓存，再调用一次模型。
    private func regenerate() {
        guard let model, let reader = model.reader, let path = model.chat.deckPath, generating[path] == nil,
              let text = reader.promptText else { return }
        RoadmapCache.shared.remove(RoadmapCache.keys(text: text, file: reader.sourceURL))
        outline = nil
        refresh(generateIfMissing: true)
    }

    private func showOutline() {
        guard let model, let reader = model.reader, let outline else { return }
        send("Roadmap.show", [
            "lang": Localizer.shared.code,
            "title": reader.title,
            "pageCount": reader.pageCount,
            "outline": outline.map(\.json),
            "touched": model.chat.touchedPages.sorted(),
            "current": reader.currentPage,
        ])
    }

    private func showStatus(_ state: String, message: String, action: String? = nil) {
        var payload: [String: Any] = ["lang": Localizer.shared.code, "state": state, "message": message]
        if let reader = model?.reader {
            payload["title"] = reader.title
            payload["pageCount"] = reader.pageCount
        }
        if let action { payload["action"] = action }
        send("Roadmap.showStatus", payload)
    }

    private func showError(_ error: Error) {
        showStatus("error", message: error.localizedDescription, action: tr("重试", "Try again"))
    }

    // MARK: - 窗口

    private func makePanel() -> FigurePanel {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ScriptMessageProxy { [weak self] body in self?.receive(body) }, name: "roadmap")
        let webView = FigureWebView(frame: NSRect(x: 0, y: 0, width: 880, height: 680), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        let panel = FigurePanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.title = tr("学习路线图", "Study Roadmap")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.panelNSColor
        panel.minSize = NSSize(width: 560, height: 420)
        panel.contentView = webView

        self.panel = panel
        self.webView = webView
        if let directory = WebAssets.directory {
            webView.loadFileURL(directory.appendingPathComponent("roadmap.html"), allowingReadAccessTo: directory)
        }
        return panel
    }

    /// 第一次打开放在主窗口右侧；之后记住用户放的位置。
    private func place(_ panel: NSPanel) {
        if panel.setFrameUsingName("RoadmapWindow") { return }
        let parent = NSApp.mainWindow ?? NSApp.windows.first { $0.title == "PPTReader" }
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = parent?.frame ?? visible
        let width = min(880, visible.width - 40), height = min(max(area.height * 0.8, 520), visible.height - 40)
        var origin = NSPoint(x: area.maxX - width - 24, y: area.midY - height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.setFrameAutosaveName("RoadmapWindow")
    }

    // MARK: - 网页通信

    private func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            if let pending { send(pending.function, pending.payload) }
        case "goto":
            if let page = (dict["page"] as? NSNumber)?.intValue { model?.reader?.pdf.go(to: page) }
        case "generate":
            refresh(generateIfMissing: true)
        case "regenerate":
            regenerate()
        default:
            break
        }
    }

    /// - Parameter remember: 记下来，网页加载好时重发（进度更新不记，免得盖掉要显示的大纲）。
    private func send(_ function: String, _ payload: [String: Any], remember: Bool = true) {
        if remember { pending = (function, payload) }
        guard isReady, let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("\(function)(\(json))") { _, error in
            if let error { NSLog("PPTReader roadmap JS error: \(error)") }
        }
    }
}
