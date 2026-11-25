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
    /// 框选的区域（Shift + 拖动，或在设置里改成默认框选）。提问时附上框内截图和文字。
    private(set) var region: PageRegion?
    /// 框内的文字（框选时取出）。
    private(set) var regionText = ""
    /// 框在阅读区中的位置（左上角为原点）：拖动过程中和框选之后都用它画框；滚出可视区域时为 nil。
    var regionRect: CGRect?
    /// 框选完成后显示的浮动工具条。
    var regionBarVisible = false
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

    func setRegion(_ region: PageRegion, text: String) {
        self.region = region
        regionText = text
        regionBarVisible = true
    }

    func clearRegion() {
        region = nil
        regionText = ""
        regionRect = nil
        regionBarVisible = false
    }

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

    /// 框选区域的截图（JPEG）。只渲染框内的部分，框很小时也不会生成一张巨大的整页图。
    func regionImage(_ region: PageRegion) async -> Data? {
        await renderer.jpeg(region: region)
    }

    /// 对话气泡里显示的缩略图（长边 480 像素）。
    func regionThumbnail(_ region: PageRegion) async -> Data? {
        await renderer.jpeg(region: region, thumbnail: true)
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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = Self.encode(cgImage) else { return nil }
        cache[number] = jpeg
        recent.append(number)
        if recent.count > 6 { cache[recent.removeFirst()] = nil }
        return jpeg
    }

    /// 框选区域的截图。和阅读区一样按裁切框（cropBox）显示方向渲染；`draw(with:to:)` 会按页面旋转摆正。
    func jpeg(region: PageRegion, thumbnail: Bool = false) -> Data? {
        if document == nil { document = PDFDocument(url: url) }
        guard let page = document?.page(at: region.page - 1) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation / 90) % 4 + 4) % 4
        let pageSize = quarterTurns % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let area = region.pointRect(pageSize: pageSize)
        let scale = thumbnail ? PageRegion.thumbnailScale(for: area.size) : PageRegion.renderScale(for: area.size)
        let (width, height) = PageRegion.pixelSize(for: area.size, scale: scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return Self.encode(image)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
        let continuous = view.displayMode == .singlePageContinuous || view.displayMode == .twoUpContinuous
        guard !Motion.reduced, continuous, let scrollView = view.documentView?.enclosingScrollView else {
            crossfade(view, duration: 0.18)
            view.go(to: page)
            return
        }
        smoothScroll(view, scrollView, to: page)
    }

    private func crossfade(_ view: PDFView, duration: CFTimeInterval) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "pageTransition")
    }

    /// 先让 PDFView 自己跳到目标页：当前页立即更新（发出换页通知），也得到和直接跳转完全一样的位置；
    /// 再在同一帧里回到原处、用动画滚过去。只用动画改滚动位置时，PDFView 不会更新当前页，
    /// 路线图、AI 面板和上一页 / 下一页都会以为还停在原来那页。距离太远（超过几屏）时直接跳，加淡入淡出。
    private func smoothScroll(_ view: PDFView, _ scrollView: NSScrollView, to page: PDFPage) {
        let clip = scrollView.contentView
        let start = clip.bounds.origin
        view.go(to: page)
        let target = clip.bounds.origin
        let distance = abs(target.y - start.y)
        guard distance > 1 else { return }
        guard distance < clip.bounds.height * 5 else {
            crossfade(view, duration: 0.18)
            return
        }
        clip.setBoundsOrigin(start)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = min(0.45, 0.25 + Double(distance / clip.bounds.height) * 0.05)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
