import AppKit
import WebKit

enum WebEvent {
    case ready
    case gotoPage(Int)
    case copy(String)
    case retry(UUID)
    case regenerate(UUID)
    case quick(QuickAction)
    case contextMenu(WebContextInfo)
    /// 点按图表放大查看。
    case figure([String: Any])
}

/// 讲解区右键时网页回传的信息。
struct WebContextInfo {
    var point: NSPoint
    var selection: String
    var link: URL?
    var messageID: UUID?
    var isAssistant: Bool
    var page: Int?
}

/// 讲解面板的 WKWebView 与 Swift 之间的桥。
@MainActor
final class ChatWebBridge: NSObject {
    let webView: WKWebView
    var onEvent: ((WebEvent) -> Void)?
    private(set) var isReady = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        webView = ChatWKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(WeakScriptHandler(self), name: "bridge")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        load()
    }

    private func load() {
        guard let directory = WebAssets.directory else {
            webView.loadHTMLString("<p style='font:13px -apple-system;color:#c00;padding:20px'>Missing Resources/Web</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
    }

    /// 调用网页中的函数，参数以 JSON 传入。
    func call(_ function: String, _ arguments: Any...) {
        guard isReady else { return }
        let encoded = arguments.compactMap { argument -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard encoded.count == arguments.count else { return }
        webView.evaluateJavaScript("\(function)(\(encoded.joined(separator: ",")))") { _, error in
            if let error { NSLog("PPTReader JS error: \(error)") }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            onEvent?(.ready)
        case "gotoPage":
            if let page = dict["page"] as? Int { onEvent?(.gotoPage(page)) }
        case "copy":
            if let text = dict["text"] as? String { onEvent?(.copy(text)) }
        case "retry":
            if let id = (dict["id"] as? String).flatMap(UUID.init) { onEvent?(.retry(id)) }
        case "regenerate":
            if let id = (dict["id"] as? String).flatMap(UUID.init) { onEvent?(.regenerate(id)) }
        case "quick":
            if let action = (dict["action"] as? String).flatMap(QuickAction.init) { onEvent?(.quick(action)) }
        case "contextmenu":
            let x = dict["x"] as? Double ?? 0
            let y = dict["y"] as? Double ?? 0
            // 网页坐标（左上为原点）→ 屏幕坐标
            guard let window = webView.window else { return }
            let local = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            let point = window.convertPoint(toScreen: webView.convert(local, to: nil))
            onEvent?(.contextMenu(WebContextInfo(
                point: point,
                selection: dict["selection"] as? String ?? "",
                link: (dict["link"] as? String).flatMap(URL.init(string:)),
                messageID: (dict["id"] as? String).flatMap(UUID.init),
                isAssistant: dict["role"] as? String == "assistant",
                page: dict["page"] as? Int
            )))
        case "figure":
            onEvent?(.figure(dict))
        case "log":
            NSLog("PPTReader web: \(dict["message"] ?? "")")
        default:
            break
        }
    }
}

extension ChatWebBridge: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.isFileURL && navigationAction.navigationType == .other { return .allow }
        if url.scheme == "about" { return .allow }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        load()
    }
}

/// 避免 WKUserContentController 强引用桥对象。
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: ChatWebBridge?
    init(_ bridge: ChatWebBridge) { self.bridge = bridge }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { bridge?.receive(body) }
    }
}

/// 去掉右键菜单中的“重新载入”等与网页浏览相关的项目。
private final class ChatWKWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let hidden: Set<String> = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
                                   "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                                   "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage"]
        menu.items.removeAll { hidden.contains($0.identifier?.rawValue ?? "") }
        super.willOpenMenu(menu, with: event)
    }
}

enum WebAssets {
    /// .app 中位于 Contents/Resources/Web；用 `swift run` 开发时向上查找仓库里的 Resources/Web。
    static let directory: URL? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web"),
           fm.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        var url = Bundle.main.executableURL?.deletingLastPathComponent()
        while let current = url, current.path != "/" {
            let candidate = current.appendingPathComponent("Resources/Web")
            if fm.fileExists(atPath: candidate.appendingPathComponent("index.html").path) { return candidate }
            url = current.deletingLastPathComponent()
        }
        return nil
    }()
}
