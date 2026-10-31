import AppKit
import Observation
import PDFKit

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
    /// OCR 进度：(已完成, 总数)；nil 表示没有需要 OCR 的页面或已完成。
    private(set) var ocrProgress: (done: Int, total: Int)?
    var continuousScroll: Bool
    /// 当前缩放比例（1 = 100%）。
    var scale: Double = 1

    @ObservationIgnored let pdf = PDFController()
    @ObservationIgnored var onPageChange: ((Int) -> Void)?
    @ObservationIgnored private var extraction: Task<Void, Never>?

    init(sourceURL: URL, pdfURL: URL, kind: CourseFileKind, document: PDFDocument, initialPage: Int) {
        self.sourceURL = sourceURL
        self.pdfURL = pdfURL
        self.kind = kind
        self.document = document
        pageCount = document.pageCount
        currentPage = min(max(initialPage, 1), max(document.pageCount, 1))
        continuousScroll = kind != .slides
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
    }

    func close() {
        extraction?.cancel()
    }

    /// 当前页截图（JPEG），供支持图像输入的模型使用。
    func currentPageImage() -> Data? {
        guard let page = document.page(at: currentPage - 1) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = 1600 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
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
