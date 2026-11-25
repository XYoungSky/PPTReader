import AppKit
import UniformTypeIdentifiers
import WebKit

/// 图表放大预览：浮在主窗口上方的面板，可以移动、调整大小、调节透明度，边看课件边参考。
@MainActor
final class FigurePreview: NSObject {
    static let shared = FigurePreview()

    private var panel: FigurePanel?
    private var webView: FigureWebView?
    private var isReady = false
    private var pending: [String: Any]?
    private var title = ""
    private var exporting = false
    /// 记住透明度用；由打开预览的一方传入。
    private weak var settings: AppSettings?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ payload: [String: Any], from parent: NSWindow?, settings: AppSettings?) {
        let panel = self.panel ?? makePanel()
        self.settings = settings
        title = (payload["title"] as? String) ?? ""
        panel.title = tr("图表预览", "Figure Preview")
        if !panel.isVisible { place(panel, payload: payload, over: parent) }
        let opacity = settings?.figureOpacity ?? 1
        panel.alphaValue = opacity
        var payload = payload
        payload["opacity"] = opacity
        pending = payload
        deliver()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
    }

    func close() {
        panel?.close()
    }

    // MARK: - 窗口

    private func makePanel() -> FigurePanel {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ScriptMessageProxy { [weak self] body in self?.receive(body) }, name: "figure")
        let webView = FigureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.onMagnify = { [weak self] magnification, point in
            self?.evaluate("Figure.pinch(\(magnification), \(point.x), \(point.y))")
        }
        webView.onSmartMagnify = { [weak self] point in
            self?.evaluate("Figure.smartMagnify(\(point.x), \(point.y))")
        }
        webView.onModifiersChanged = { [weak self] option in
            self?.evaluate("Figure.setMoveMode(\(option))")
        }

        let panel = FigurePanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = Theme.canvasNSColor
        panel.minSize = NSSize(width: 440, height: 300)
        panel.contentView = webView
        panel.onClose = { [weak self] in self?.pending = nil }

        self.panel = panel
        self.webView = webView
        if let directory = WebAssets.directory {
            webView.loadFileURL(directory.appendingPathComponent("figure.html"), allowingReadAccessTo: directory)
        }
        return panel
    }

    /// 首次打开：按图表的自然尺寸决定窗口大小（不超过主窗口的 86%），居中于主窗口。
    private func place(_ panel: NSPanel, payload: [String: Any], over parent: NSWindow?) {
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = parent?.frame ?? visible
        let maxWidth = min(area.width * 0.86, visible.width - 40)
        let maxHeight = min(area.height * 0.86, visible.height - 40)
        // 与 figure.js 一致：卡片留白 24×2，四周边距 32×2，上 44、下 78
        let chromeWidth: CGFloat = 64, chromeHeight: CGFloat = 122, padding: CGFloat = 48
        var width = maxWidth, height = maxHeight
        if let naturalWidth = payload["width"] as? Double, let naturalHeight = payload["height"] as? Double,
           naturalWidth > 0, naturalHeight > 0 {
            let cardWidth = CGFloat(naturalWidth) + padding, cardHeight = CGFloat(naturalHeight) + padding
            let scale = min(1.6, (maxWidth - chromeWidth) / cardWidth, (maxHeight - chromeHeight) / cardHeight)
            width = cardWidth * scale + chromeWidth
            height = cardHeight * scale + chromeHeight
        }
        width = min(max(width, 520), maxWidth)
        height = min(max(height, 400), maxHeight)
        var origin = NSPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    // MARK: - 网页通信

    private func deliver() {
        guard isReady, let payload = pending else { return }
        pending = nil
        call("Figure.show", payload)
    }

    private func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            deliver()
        case "close":
            panel?.close()
        case "export":
            export(save: dict["action"] as? String == "save")
        case "opacity":
            guard let value = (dict["value"] as? NSNumber)?.doubleValue else { return }
            let range = AppSettings.figureOpacityRange
            let opacity = min(max(value, range.lowerBound), range.upperBound)
            panel?.alphaValue = opacity
            settings?.figureOpacity = opacity
        default:
            break
        }
    }

    private func call(_ function: String, _ arguments: Any...) {
        let encoded = arguments.compactMap { argument -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard encoded.count == arguments.count else { return }
        evaluate("\(function)(\(encoded.joined(separator: ",")))")
    }

    private func evaluate(_ script: String) {
        guard isReady else { return }
        webView?.evaluateJavaScript(script) { _, error in
            if let error { NSLog("PPTReader figure JS error: \(error)") }
        }
    }

    // MARK: - 导出

    /// 网页先切到「适合窗口」并隐藏工具条，再截取卡片区域；输出不小于图表的自然尺寸。
    private func export(save: Bool) {
        guard let webView, isReady, !exporting else { return }
        exporting = true
        webView.evaluateJavaScript("Figure.beginExport()") { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let rect = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
                  width > 1, height > 1 else {
                self.finishExport(nil)
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: x, y: y, width: width, height: height)
            let target = min(max(width, rect["naturalWidth"] ?? width), 4096)
            configuration.snapshotWidth = NSNumber(value: target)
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self else { return }
                guard let image, let png = Self.png(from: image) else {
                    self.finishExport(tr("导出失败", "Export failed"))
                    return
                }
                if save {
                    self.finishExport(nil)
                    self.savePNG(png)
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.declareTypes([.png, .tiff], owner: nil)
                    pasteboard.setData(png, forType: .png)
                    if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
                    self.finishExport(tr("已拷贝图片", "Image copied"))
                }
            }
        }
    }

    private func finishExport(_ message: String?) {
        exporting = false
        call("Figure.endExport", message ?? "")
    }

    private func savePNG(_ data: Data) {
        guard let panel else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        let base = title.isEmpty ? tr("图表", "Figure") : title + " " + tr("图表", "Figure")
        savePanel.nameFieldStringValue = base.replacingOccurrences(of: "/", with: "-") + ".png"
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.call("Figure.endExport", tr("已存储", "Saved"))
            } catch {
                self?.call("Figure.endExport", error.localizedDescription)
            }
        }
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension FigurePreview: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        return url.isFileURL || url.scheme == "about" ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        panel?.close()
        if let directory = WebAssets.directory {
            webView.loadFileURL(directory.appendingPathComponent("figure.html"), allowingReadAccessTo: directory)
        }
    }
}

final class FigurePanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// 把触控板捏合、智能缩放转发给网页，由网页自己缩放图表；顶部拖动条和 ⌥ + 拖动用来移动窗口。
final class FigureWebView: WKWebView {
    /// 顶部这么高的区域用来拖动窗口（和标题栏同高，红绿灯在这一行）。与 figure.css 的 #drag-strip 一致。
    static let dragStripHeight: CGFloat = 28

    var onMagnify: ((CGFloat, NSPoint) -> Void)?
    var onSmartMagnify: ((NSPoint) -> Void)?
    /// ⌥ 按下 / 松开，网页据此切换光标。
    var onModifiersChanged: ((Bool) -> Void)?
    private var optionDown = false

    /// 移动窗口要在原生端同步处理：`performDrag(with:)` 需要原始的按下事件，
    /// 让网页 postMessage 通知过来时已经晚了。拖动窗口时不交给网页，图表也就不会跟着平移。
    override func mouseDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        if let window, option || pagePoint(event).y < Self.dragStripHeight {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let option = event.modifierFlags.contains(.option)
        guard option != optionDown else { return }
        optionDown = option
        onModifiersChanged?(option)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification, pagePoint(event))
    }

    override func smartMagnify(with event: NSEvent) {
        onSmartMagnify?(pagePoint(event))
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll()
        super.willOpenMenu(menu, with: event)
    }

    /// 窗口坐标 → 网页坐标（左上为原点）。
    private func pagePoint(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return isFlipped ? local : NSPoint(x: local.x, y: bounds.height - local.y)
    }
}

/// 不强引用接收者的脚本消息处理器。
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let handler: @MainActor (Any) -> Void

    init(_ handler: @escaping @MainActor (Any) -> Void) {
        self.handler = handler
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { handler(body) }
    }
}
