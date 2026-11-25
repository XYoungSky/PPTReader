import PDFKit
import SwiftUI

struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    let reader: ReaderModel

    var body: some View {
        PDFReaderView(reader: reader, dragSelectsRegion: model.settings.dragSelectsRegion, contextItems: contextItems)
            .overlay { regionBox }
            .overlay { selectionBar }
            .overlay { regionBar }
            .overlay(alignment: .bottom) {
                if let progress = reader.ocrProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(tr("识别扫描页", "OCR") + " \(progress.done)/\(progress.total)")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                    .padding(.bottom, model.lectures.isRecording ? 64 : 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .help(tr("正在识别无文字层的页面", "Recognizing pages without a text layer"))
                }
            }
            .animation(Motion.panel, value: reader.ocrProgress == nil)
    }

    // MARK: 选中工具条

    private var selectionBar: some View {
        GeometryReader { geometry in
            if reader.selectionBarVisible, let rect = reader.selectionRect, !reader.selection.isEmpty {
                FloatingBar(rect: rect, container: geometry.size, width: 320) {
                    SelectionBar { action in run(action, text: reader.selection) }
                }
            }
        }
        .animation(Motion.content, value: reader.selectionBarVisible)
    }

    // MARK: 框选

    /// 框选的框：拖动中和框选之后都显示，跟着页面滚动。
    private var regionBox: some View {
        GeometryReader { _ in
            if let rect = reader.regionRect {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.hover, value: reader.region == nil && reader.regionRect == nil)
    }

    private var regionBar: some View {
        GeometryReader { geometry in
            if reader.regionBarVisible, reader.region != nil, let rect = reader.regionRect {
                FloatingBar(rect: rect, container: geometry.size, width: 380) {
                    SelectionBar(onCancel: { reader.clearRegion() }) { action in runRegion(action) }
                }
            }
        }
        .animation(Motion.content, value: reader.regionBarVisible)
    }

    private func runRegion(_ action: SelectionAction) {
        guard let region = reader.region else { return }
        reader.regionBarVisible = false
        if action == .ask {
            // 框留着，作为输入框里的引用随下一条提问发出
            model.chat.requestFocus()
        } else {
            model.chat.perform(.region(action, region, text: reader.regionText))
            reader.clearRegion()
        }
    }

    private func run(_ action: SelectionAction, text: String) {
        reader.selectionBarVisible = false
        if action == .ask {
            model.chat.requestFocus()
        } else {
            model.chat.perform(.selection(action, text))
            reader.pdf.clearSelection()
        }
    }

    // MARK: 右键菜单

    private func contextItems(_ selection: String?) -> [PopMenuItem] {
        if let text = selection {
            return [
                PopMenuItem(tr("解释", "Explain"), icon: "sparkles") { run(.explain, text: text) },
                PopMenuItem(tr("翻译", "Translate"), icon: "character.bubble") { run(.translate, text: text) },
                PopMenuItem(tr("举例", "Examples"), icon: "lightbulb") { run(.example, text: text) },
                PopMenuItem(tr("提问…", "Ask…"), icon: "text.bubble") { run(.ask, text: text) },
                .separator,
                PopMenuItem(tr("拷贝", "Copy"), icon: "doc.on.doc", shortcut: "⌘C") { copy(text) },
            ]
        }
        let page = reader.currentPage
        return [
            PopMenuItem(tr("讲解第 \(page) 页", "Explain Page \(page)"), icon: "sparkles", shortcut: ShortcutStore.shared.label(for: .explainPage), enabled: !model.chat.isStreaming) {
                model.chat.perform(.explainPage(auto: false))
            },
            PopMenuItem(tr("拷贝本页文字", "Copy Page Text"), icon: "doc.on.doc") {
                copy(reader.text?.text(ofPage: page) ?? reader.document.page(at: page - 1)?.string ?? "")
            },
            .separator,
            PopMenuItem(tr("放大", "Zoom In"), icon: "plus.magnifyingglass", shortcut: ShortcutStore.shared.label(for: .zoomIn)) { reader.pdf.zoomIn() },
            PopMenuItem(tr("缩小", "Zoom Out"), icon: "minus.magnifyingglass", shortcut: ShortcutStore.shared.label(for: .zoomOut)) { reader.pdf.zoomOut() },
            PopMenuItem(tr("适合窗口", "Fit to Window"), icon: "arrow.up.left.and.down.right.magnifyingglass", shortcut: ShortcutStore.shared.label(for: .fitToWindow)) { reader.pdf.fitToWindow() },
            .separator,
            PopMenuItem(tr("连续滚动", "Continuous"), icon: "rectangle.split.1x2", checked: reader.continuousScroll) { setContinuous(true) },
            PopMenuItem(tr("单页", "Single Page"), icon: "rectangle", checked: !reader.continuousScroll) { setContinuous(false) },
        ]
    }

    private func setContinuous(_ value: Bool) {
        guard reader.continuousScroll != value else { return }
        reader.continuousScroll = value
        reader.pdf.setContinuous(value)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 把浮动工具条摆在目标上方（放不下时放在下方），并且不超出阅读区。
private struct FloatingBar<Content: View>: View {
    let rect: CGRect
    let container: CGSize
    /// 工具条按内容自适应宽度，这里的宽度只用于贴边时的位置估算。
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let height: CGFloat = 36
        let above = rect.minY - height / 2 - 10
        let y = above > height / 2 + 6 ? above : min(rect.maxY + height / 2 + 10, container.height - height / 2 - 6)
        let x = min(max(rect.midX, width / 2 + 8), container.width - width / 2 - 8)
        content
            .frame(height: height)
            .fixedSize()
            .position(x: x, y: y)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: above > 0 ? .bottom : .top)))
    }
}

/// 选中文字（或框选区域）上方的浮动工具条。
private struct SelectionBar: View {
    /// 框选时显示“取消”。
    var onCancel: (() -> Void)?
    let action: (SelectionAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(.explain, tr("解释", "Explain"), "sparkles")
            item(.translate, tr("翻译", "Translate"), "character.bubble")
            item(.example, tr("举例", "Examples"), "lightbulb")
            Rectangle().fill(Theme.border).frame(width: 1, height: 16).padding(.horizontal, 2)
            item(.ask, tr("提问", "Ask"), "text.bubble")
            if let onCancel {
                Button(action: onCancel) {
                    Label(tr("取消", "Cancel"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(TextButtonStyle(font: .system(size: 12.5)))
                .help(tr("取消框选", "Clear selection box") + " (Esc)")
            }
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
    }

    private func item(_ value: SelectionAction, _ title: String, _ icon: String) -> some View {
        Button { action(value) } label: {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12.5))
        }
        .buttonStyle(TextButtonStyle(font: .system(size: 12.5)))
    }
}

/// 阅读区顶栏：路径、翻页、缩放。
struct ReaderHeader: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PanelKeys.showsSidebar) private var showsSidebar = true
    @AppStorage(PanelKeys.showsChat) private var showsChat = true
    @ViewState private var editingPage = false
    @ViewState private var jumpText = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !showsSidebar {
                Color.clear.frame(width: Theme.trafficLightsWidth - 8)
                    .transition(.identity)
                Button {
                    withAnimation(Motion.panel) { showsSidebar = true }
                } label: {
                    Label(tr("显示侧边栏", "Show Sidebar"), systemImage: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle())
                .help(tr("显示侧边栏", "Show sidebar") + ShortcutStore.shared.hint(.toggleSidebar))
                .padding(.trailing, 6)
            }

            breadcrumb
                .padding(.leading, showsSidebar ? 10 : 0)

            Spacer(minLength: 12)

            if let reader = model.reader {
                pageControls(reader)
                divider
                zoomControls(reader)
                divider
                Button {
                    reader.continuousScroll.toggle()
                    reader.pdf.setContinuous(reader.continuousScroll)
                } label: {
                    Label(tr("显示方式", "Layout"), systemImage: reader.continuousScroll ? "rectangle.split.1x2" : "rectangle")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle())
                .help((reader.continuousScroll ? tr("连续滚动", "Continuous") : tr("单页", "Single page")) + ShortcutStore.shared.hint(.toggleLayout))

                if LectureController.isSupported {
                    RecordButton()
                }

                if !showsChat {
                    Button {
                        withAnimation(Motion.panel) { showsChat = true }
                    } label: {
                        Label(tr("AI 讲解", "AI"), systemImage: "sparkles")
                    }
                    .buttonStyle(IconButtonStyle(isOn: true))
                    .help(tr("显示 AI 面板", "Show AI panel") + ShortcutStore.shared.hint(.toggleChat))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.barHeight)
        .background(WindowDragArea())
        // 与面板开合同步：给红绿灯让位的空白随动画展开/收起
        .animation(Motion.panel, value: showsSidebar)
        .animation(Motion.panel, value: showsChat)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if let folder = folderPath {
                Text(folder)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(0)
                Text("/")
                    .foregroundStyle(Theme.text3.opacity(0.7))
            }
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .font(.system(size: 13))
        .help(model.selectedFile?.path ?? "")
    }

    private var title: String {
        switch model.phase {
        case .ready(let reader): reader.title
        case .loading(let name), .converting(let name, _), .failed(let name, _): name
        case .empty: "PPTReader"
        }
    }

    /// 课件相对课程文件夹的目录，例如「ADS205 / Lecture」。
    private var folderPath: String? {
        guard let root = model.library.rootURL, let file = model.selectedFile else { return nil }
        let folder = file.deletingLastPathComponent().path
        guard folder.hasPrefix(root.path) else { return nil }
        let relative = folder.dropFirst(root.path.count).split(separator: "/").map(String.init)
        return ([root.lastPathComponent] + relative).joined(separator: " / ")
    }

    private func pageControls(_ reader: ReaderModel) -> some View {
        HStack(spacing: 0) {
            Button { reader.pdf.previous() } label: { Label(tr("上一页", "Previous"), systemImage: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 26))
                .disabled(reader.currentPage <= 1)
                .help(tr("上一页", "Previous page") + ShortcutStore.shared.hint(.previousPage))

            // 点按页码直接原地输入跳转
            Group {
                if editingPage {
                    HStack(spacing: 4) {
                        TextField("", text: $jumpText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .focused($pageFieldFocused)
                            .frame(width: 32, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.7)))
                            .onSubmit { jump(reader) }
                            .onExitCommand { editingPage = false }
                        Text("/ \(reader.pageCount)")
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .transition(.opacity)
                } else {
                    Button {
                        jumpText = "\(reader.currentPage)"
                        editingPage = true
                        DispatchQueue.main.async { pageFieldFocused = true }
                    } label: {
                        Text("\(reader.currentPage) / \(reader.pageCount)")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(reader.currentPage)))
                            .animation(Motion.snappy, value: reader.currentPage)
                    }
                    .buttonStyle(TextButtonStyle())
                    .help(tr("跳转到页", "Go to page"))
                    .transition(.opacity)
                }
            }
            .animation(Motion.hover, value: editingPage)
            .onChange(of: pageFieldFocused) { _, focused in
                if !focused { editingPage = false }
            }

            Button { reader.pdf.next() } label: { Label(tr("下一页", "Next"), systemImage: "chevron.right") }
                .buttonStyle(IconButtonStyle(size: 26))
                .disabled(reader.currentPage >= reader.pageCount)
                .help(tr("下一页", "Next page") + ShortcutStore.shared.hint(.nextPage))
        }
    }

    private func zoomControls(_ reader: ReaderModel) -> some View {
        HStack(spacing: 0) {
            Button { reader.pdf.zoomOut() } label: { Label(tr("缩小", "Zoom Out"), systemImage: "minus") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(tr("缩小", "Zoom out") + ShortcutStore.shared.hint(.zoomOut))
            Button { reader.pdf.fitToWindow() } label: {
                Text("\(Int((reader.scale * 100).rounded()))%")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reader.scale))
                    .animation(Motion.snappy, value: Int((reader.scale * 100).rounded()))
                    .frame(minWidth: 38)
            }
            .buttonStyle(TextButtonStyle())
            .help(tr("适合窗口", "Fit to window") + ShortcutStore.shared.hint(.fitToWindow))
            Button { reader.pdf.zoomIn() } label: { Label(tr("放大", "Zoom In"), systemImage: "plus") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(tr("放大", "Zoom in") + ShortcutStore.shared.hint(.zoomIn))
        }
    }

    private func jump(_ reader: ReaderModel) {
        if let page = Int(jumpText.trimmingCharacters(in: .whitespaces)), (1...reader.pageCount).contains(page) {
            reader.pdf.go(to: page)
        }
        editingPage = false
        reader.pdf.focus()
    }
}

// MARK: - PDFView 封装

struct PDFReaderView: NSViewRepresentable {
    let reader: ReaderModel
    let dragSelectsRegion: Bool
    let contextItems: (String?) -> [PopMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.document = reader.document
        view.displayMode = reader.continuousScroll ? .singlePageContinuous : .singlePage
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.autoScales = true
        view.backgroundColor = Theme.canvasNSColor
        view.wantsLayer = true
        view.contextItems = contextItems
        view.dragSelectsRegion = dragSelectsRegion
        reader.pdf.view = view

        if reader.currentPage > 1 {
            view.pendingPage = reader.document.page(at: reader.currentPage - 1)
        }
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.contextItems = contextItems
        view.dragSelectsRegion = dragSelectsRegion
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private let reader: ReaderModel
        private var observers: [NSObjectProtocol] = []
        private weak var view: ReaderPDFView?

        init(reader: ReaderModel) { self.reader = reader }

        func observe(_ view: ReaderPDFView) {
            self.view = view
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let document = view.document else { return }
                    self?.reader.pageDidChange(to: document.index(for: page) + 1)
                }
            })
            // 点课件上的录音批注：打开「课堂录音」，跳到那一条录音的那个时间
            observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                          let target = LectureAnnotations.target(of: annotation) else { return }
                    RecordingsWindow.shared.show(select: target.recording, at: target.time)
                }
            })
            observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let text = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if self.reader.selection != text { self.reader.selection = text }
                    if text.isEmpty { self.reader.selectionBarVisible = false }
                }
            })
            observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let reader = self?.reader else { return }
                    let scale = Double(view.scaleFactor)
                    if abs(reader.scale - scale) > 0.001 { reader.scale = scale }
                    self?.updateSelectionRect()
                    self?.updateRegionRect()
                }
            })
            // 滚动时让工具条跟随选中文字
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateSelectionRect()
                        self?.updateRegionRect()
                    }
                })
            }
            view.onMouseDown = { [weak self] in
                self?.reader.selectionBarVisible = false
                // 点到别处就取消框选，和选中文字一样
                if self?.reader.region != nil || self?.reader.regionRect != nil { self?.reader.clearRegion() }
            }
            view.onMouseUp = { [weak self] in
                guard let self else { return }
                self.updateSelectionRect()
                self.reader.selectionBarVisible = !self.reader.selection.isEmpty && self.reader.selectionRect != nil
            }
            view.onRegionChanged = { [weak self, weak view] rect in
                guard let self, let view else { return }
                self.reader.regionRect = Self.flipped(rect, in: view)
            }
            view.onRegionFinished = { [weak self, weak view] page, rect in
                guard let self, let view else { return }
                self.finishRegion(page: page, rect: rect, in: view)
            }
            view.onCancel = { [weak self] in
                guard let self else { return }
                if self.reader.region != nil || self.reader.regionRect != nil { self.reader.clearRegion() }
                self.reader.selectionBarVisible = false
                self.view?.clearSelection()
            }
        }

        private func finishRegion(page: PDFPage, rect: CGRect?, in view: ReaderPDFView) {
            guard let rect, let document = view.document else {
                reader.clearRegion()
                return
            }
            let pageRect = view.convert(page.bounds(for: view.displayBox), from: page)
            guard let region = PageRegion.normalized(page: document.index(for: page) + 1, rect: rect, in: pageRect) else {
                reader.clearRegion()
                return
            }
            let text = page.selection(for: view.convert(rect, to: page))?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            reader.setRegion(region, text: text)
            updateRegionRect()
        }

        /// 滚动、缩放后让框跟着页面走。
        private func updateRegionRect() {
            guard let view, let region = reader.region, let page = view.document?.page(at: region.page - 1) else { return }
            let pageRect = view.convert(page.bounds(for: view.displayBox), from: page)
            let flipped = Self.flipped(region.rect(in: pageRect), in: view)
            reader.regionRect = flipped.intersects(view.bounds) ? flipped : nil
        }

        /// PDFView 的坐标 y 轴向上；SwiftUI 叠加层的原点在左上角。
        private static func flipped(_ rect: CGRect, in view: NSView) -> CGRect {
            CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }

        private func updateSelectionRect() {
            guard let view, let selection = view.currentSelection, let page = selection.pages.first,
                  !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reader.selectionRect = nil
                return
            }
            let rect = view.convert(selection.bounds(for: page), from: page)
            let flipped = CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            // 选中内容滚出可视区域时隐藏工具条
            reader.selectionRect = flipped.intersects(view.bounds) ? flipped : nil
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

/// 用自绘菜单替换系统右键菜单，把鼠标按下/松开告知选中工具条，并处理框选。
final class ReaderPDFView: PDFView {
    var contextItems: ((String?) -> [PopMenuItem])?
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    /// 拖动默认是框选（设置里切换）；按住 Shift 临时换成另一种。
    var dragSelectsRegion = false
    /// 框选拖动中：框在视图中的位置（y 轴向上）。
    var onRegionChanged: ((CGRect) -> Void)?
    /// 框选结束：所在页和框（视图坐标，已裁到页面内）；框太小时为 nil。
    var onRegionFinished: ((PDFPage, CGRect?) -> Void)?
    /// Esc。
    var onCancel: (() -> Void)?
    /// 恢复上次阅读位置：等视图有了实际尺寸再跳转，否则自动缩放会把位置重置回第一页。
    var pendingPage: PDFPage?

    /// 打开课件时由阅读区获得焦点：方向键可直接翻页，搜索框也不会在启动时被聚焦。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        guard let page = pendingPage, bounds.width > 0, bounds.height > 0, window != nil else { return }
        pendingPage = nil
        DispatchQueue.main.async { [weak self] in self?.go(to: page) }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if wantsRegion(event.modifierFlags), let window, trackRegion(from: event, in: window) { return }
        super.mouseDown(with: event)
        // PDFView 可能在 mouseDown 内部跟踪拖选：返回时鼠标若已松开，就在这里收尾
        if NSApp.currentEvent?.type == .leftMouseUp { onMouseUp?() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // MARK: 框选

    private func wantsRegion(_ flags: NSEvent.ModifierFlags) -> Bool {
        dragSelectsRegion != flags.contains(.shift)
    }

    /// 跟踪一次框选拖动。没有拖动（只是点按）时返回 false：把松开事件放回队列，交给 PDFView 照常处理
    /// （点链接、取消选中、Shift + 点按扩展选区）。
    private func trackRegion(from down: NSEvent, in window: NSWindow) -> Bool {
        let start = convert(down.locationInWindow, from: nil)
        guard let page = page(for: start, nearest: false) else { return false }
        // 起点记在页面坐标里：拖到边缘自动滚动时，视图坐标会变
        let anchor = convert(start, to: page)
        var dragging = false
        var current = start
        func box() -> (CGRect, CGRect) {
            let origin = convert(anchor, from: page)
            let pageRect = convert(page.bounds(for: displayBox), from: page)
            let rect = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                              width: abs(current.x - origin.x), height: abs(current.y - origin.y))
            return (rect.intersection(pageRect), pageRect)
        }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            current = convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp {
                guard dragging else {
                    window.postEvent(event, atStart: true)
                    return false
                }
                let (rect, _) = box()
                let valid = !rect.isNull && rect.width >= PageRegion.minimumSide && rect.height >= PageRegion.minimumSide
                onRegionFinished?(page, valid ? rect : nil)
                return true
            }
            if !dragging {
                guard hypot(current.x - start.x, current.y - start.y) >= 4 else { continue }
                dragging = true
                clearSelection()
            }
            documentView?.autoscroll(with: event)
            let (rect, _) = box()
            if !rect.isNull { onRegionChanged?(rect) }
        }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        if updateRegionCursor(event.modifierFlags, at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseMoved(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        // 只在刚才显示的是十字光标时换回来，按 ⌘ 等其他修饰键不影响 PDFView 自己的光标
        let wasCrosshair = showsCrosshair
        if !updateRegionCursor(event.modifierFlags, at: point), wasCrosshair { NSCursor.arrow.set() }
    }

    private var showsCrosshair = false

    /// 框选模式下，鼠标在页面上时显示十字光标。
    private func updateRegionCursor(_ flags: NSEvent.ModifierFlags, at point: CGPoint) -> Bool {
        guard wantsRegion(flags), page(for: point, nearest: false) != nil else {
            showsCrosshair = false
            return false
        }
        NSCursor.crosshair.set()
        showsCrosshair = true
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window, let contextItems else { return }
        onMouseDown?()
        let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = contextItems(text?.isEmpty == false ? text : nil)
        PopMenu.shared.show(items, placement: .at(window.convertPoint(toScreen: event.locationInWindow)), in: window)
    }
}
