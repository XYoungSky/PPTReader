import AppKit
import ImageIO
import Observation
import PDFKit
import UniformTypeIdentifiers

/// 当前打开的课件。
@MainActor
@Observable
final class ReaderModel {
    let sourceURL: URL
    let pdfURL: URL
    let kind: CourseFileKind
    let document: PDFDocument
    let pageCount: Int

    private(set) var currentPage: Int
    var selection = ""
    /// 选中文字在阅读区中的位置（左上角为原点），用于摆放浮动工具条。
    var selectionRect: CGRect?
    /// 松开鼠标后才显示选中工具条，拖选过程中不打扰。
    var selectionBarVisible = false
    private(set) var text: DocumentText?
    /// 发给模型的课件文字。OCR 每识别几页 `text` 就会更新一次，如果直接用它，这段时间里每次请求的系统提示都不同，
    /// 前缀缓存全部失效；所以只在拿到文字层、OCR 每完成约四分之一和全部完成时更新，最多变动几次。
    @ObservationIgnored private(set) var promptText: DocumentText?
    @ObservationIgnored private var promptTextOCRDone = 0
    /// OCR 进度：(已完成, 总数)；nil 表示没有需要 OCR 的页面或已完成。
    private(set) var ocrProgress: (done: Int, total: Int)?
    var continuousScroll: Bool
    /// 当前缩放比例（1 = 100%）。
    var scale: Double = 1

    @ObservationIgnored let pdf = PDFController()
    @ObservationIgnored var onPageChange: ((Int) -> Void)?
    @ObservationIgnored private var extraction: Task<Void, Never>?
    @ObservationIgnored private let renderer: PageRenderer

    init(sourceURL: URL, pdfURL: URL, kind: CourseFileKind, document: PDFDocument, initialPage: Int) {
        self.sourceURL = sourceURL
        self.pdfURL = pdfURL
        self.kind = kind
        self.document = document
        pageCount = document.pageCount
        currentPage = min(max(initialPage, 1), max(document.pageCount, 1))
        continuousScroll = kind != .slides
        renderer = PageRenderer(url: pdfURL)
    }

    var title: String { sourceURL.deletingPathExtension().lastPathComponent }

    func pageDidChange(to page: Int) {
        guard page != currentPage else { return }
        currentPage = page
        onPageChange?(page)
    }

    func startTextExtraction() {
        let url = pdfURL
        let priority = currentPage
        let update: @Sendable (DocumentText, Int, Int) async -> Void = { [weak self] text, done, total in
            guard let self else { return }
            await self.applyExtraction(text, done: done, total: total)
        }
        extraction = Task.detached(priority: .utility) {
            await TextExtractor.extract(pdfURL: url, priorityPage: priority, update: update)
        }
    }

    private func applyExtraction(_ text: DocumentText, done: Int, total: Int) {
        self.text = text
        ocrProgress = done < total ? (done, total) : nil
        if promptText == nil || done >= total || done - promptTextOCRDone >= max(10, total / 4) {
            promptText = text
            promptTextOCRDone = done
        }
    }

    /// 等到课件文字可用（首次打开时提取文字层通常不到一秒）。超时或任务取消后不再等待。
    func waitForPromptText(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        while promptText == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func close() {
        extraction?.cancel()
    }

    /// 某一页的截图（JPEG，页码从 1 开始），供支持图像输入的模型使用。在后台渲染，不卡界面。
    func pageImage(_ number: Int) async -> Data? {
        await renderer.jpeg(page: number)
    }
}

/// 在后台渲染页面截图。单独打开一份文档，避免和界面上的 PDFView 争用同一个对象；最近几页的结果缓存起来，
/// 同一页连续追问时不必重新渲染。
actor PageRenderer {
    private let url: URL
    private var document: PDFDocument?
    private var cache: [Int: Data] = [:]
    private var recent: [Int] = []

    init(url: URL) {
        self.url = url
    }

    func jpeg(page number: Int) -> Data? {
        if let hit = cache[number] { return hit }
        if document == nil { document = PDFDocument(url: url) }
        guard let page = document?.page(at: number - 1) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // 截图每次都按全价计费（排在请求末尾，不会被缓存）：横向的幻灯片长边 1280 已能看清；
        // 竖向的讲义、Word 文档字小，保留 1600
        let longest: CGFloat = bounds.width >= bounds.height ? 1280 : 1600
        let scale = longest / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = data as Data
        cache[number] = jpeg
        recent.append(number)
        if recent.count > 6 { cache[recent.removeFirst()] = nil }
        return jpeg
    }
}

/// 让 SwiftUI 之外的代码（菜单、讲解面板）控制 PDFView。
@MainActor
final class PDFController {
    weak var view: PDFView?

    func go(to page: Int) {
        guard let view, let target = view.document?.page(at: page - 1) else { return }
        navigate(view, to: target)
    }

    func next() { step(1) }
    func previous() { step(-1) }
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fitToWindow() { view?.autoScales = true }
    func clearSelection() { view?.clearSelection() }
    func focus() { view?.window?.makeFirstResponder(view) }

    func setContinuous(_ continuous: Bool) {
        guard let view else { return }
        let page = view.currentPage
        crossfade(view, duration: 0.22)
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        view.autoScales = true
        if let page { view.go(to: page) }
    }

    private func step(_ delta: Int) {
        guard let view, let document = view.document, let current = view.currentPage,
              let target = document.page(at: document.index(for: current) + delta) else { return }
        navigate(view, to: target)
    }

    /// 连续滚动时平滑滚到目标页，单页模式下淡入淡出切换。
    private func navigate(_ view: PDFView, to page: PDFPage) {
        guard !Motion.reduced else {
            view.go(to: page)
            return
        }
        if view.displayMode == .singlePageContinuous || view.displayMode == .twoUpContinuous,
           smoothScroll(view, to: page) {
            return
        }
        crossfade(view, duration: 0.18)
        view.go(to: page)
    }

    private func crossfade(_ view: PDFView, duration: CFTimeInterval) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "pageTransition")
    }

    /// 距离太远（超过几屏）时返回 false，改用淡入淡出直接跳转。
    private func smoothScroll(_ view: PDFView, to page: PDFPage) -> Bool {
        guard let documentView = view.documentView, let scrollView = documentView.enclosingScrollView else { return false }
        let clip = scrollView.contentView
        let pageRect = documentView.convert(view.convert(page.bounds(for: view.displayBox), from: page), from: view)
        let margin = view.pageBreakMargins.top
        var origin = clip.bounds.origin
        origin.y = documentView.isFlipped
            ? pageRect.minY - margin
            : pageRect.maxY + margin - clip.bounds.height
        let maxY = max(documentView.frame.height - clip.bounds.height, 0)
        origin.y = min(max(origin.y, 0), maxY)

        let distance = abs(origin.y - clip.bounds.origin.y)
        guard distance > 1 else { return true }
        guard distance < clip.bounds.height * 5 else { return false }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = min(0.45, 0.25 + Double(distance / clip.bounds.height) * 0.05)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: {
            scrollView.reflectScrolledClipView(clip)
        }
        return true
    }
}
