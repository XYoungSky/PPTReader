import PDFKit
import SwiftUI

struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    let reader: ReaderModel

    var body: some View {
        PDFReaderView(reader: reader, contextItems: contextItems)
            .overlay { selectionBar }
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
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .help(tr("正在识别没有文字层的页面", "Recognizing pages without a text layer"))
                }
            }
            .animation(Motion.panel, value: reader.ocrProgress == nil)
    }

    // MARK: 选中工具条

    private var selectionBar: some View {
        GeometryReader { geometry in
            if reader.selectionBarVisible, let rect = reader.selectionRect, !reader.selection.isEmpty {
                // 工具条按内容自适应宽度，这里的尺寸只用于贴边时的位置估算
                let size = CGSize(width: 320, height: 36)
                let above = rect.minY - size.height / 2 - 10
                let y = above > size.height / 2 + 6 ? above : min(rect.maxY + size.height / 2 + 10, geometry.size.height - size.height / 2 - 6)
                let x = min(max(rect.midX, size.width / 2 + 8), geometry.size.width - size.width / 2 - 8)
                SelectionBar { action in run(action, text: reader.selection) }
                    .frame(height: size.height)
                    .fixedSize()
                    .position(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: above > 0 ? .bottom : .top)))
            }
        }
        .animation(Motion.content, value: reader.selectionBarVisible)
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
            PopMenuItem(tr("讲解第 \(page) 页", "Explain Page \(page)"), icon: "sparkles", shortcut: "⌘E", enabled: !model.chat.isStreaming) {
                model.chat.perform(.explainPage(auto: false))
            },
            PopMenuItem(tr("拷贝本页文字", "Copy Page Text"), icon: "doc.on.doc") {
                copy(reader.text?.text(ofPage: page) ?? reader.document.page(at: page - 1)?.string ?? "")
            },
            .separator,
            PopMenuItem(tr("放大", "Zoom In"), icon: "plus.magnifyingglass", shortcut: "⌘=") { reader.pdf.zoomIn() },
            PopMenuItem(tr("缩小", "Zoom Out"), icon: "minus.magnifyingglass", shortcut: "⌘-") { reader.pdf.zoomOut() },
            PopMenuItem(tr("适合窗口", "Fit to Window"), icon: "arrow.up.left.and.down.right.magnifyingglass", shortcut: "⌘0") { reader.pdf.fitToWindow() },
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

/// 选中文字上方的浮动工具条。
private struct SelectionBar: View {
    let action: (SelectionAction) -> Void
    @ViewState private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            item(.explain, tr("解释", "Explain"), "sparkles")
            item(.translate, tr("翻译", "Translate"), "character.bubble")
            item(.example, tr("举例", "Examples"), "lightbulb")
            Rectangle().fill(Theme.border).frame(width: 1, height: 16).padding(.horizontal, 2)
            item(.ask, tr("提问", "Ask"), "text.bubble")
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
                .help(tr("显示侧边栏", "Show sidebar") + " ⌃⌘S")
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
                .help(reader.continuousScroll ? tr("连续滚动", "Continuous") : tr("单页", "Single page"))

                if !showsChat {
                    Button {
                        withAnimation(Motion.panel) { showsChat = true }
                    } label: {
                        Label(tr("AI 讲解", "AI"), systemImage: "sparkles")
                    }
                    .buttonStyle(IconButtonStyle(isOn: true))
                    .help(tr("显示 AI 面板", "Show AI panel") + " ⌥⌘0")
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
                .help(tr("上一页", "Previous page"))

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
                .help(tr("下一页", "Next page"))
        }
    }

    private func zoomControls(_ reader: ReaderModel) -> some View {
        HStack(spacing: 0) {
            Button { reader.pdf.zoomOut() } label: { Label(tr("缩小", "Zoom Out"), systemImage: "minus") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(tr("缩小", "Zoom out") + " ⌘-")
            Button { reader.pdf.fitToWindow() } label: {
                Text("\(Int((reader.scale * 100).rounded()))%")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reader.scale))
                    .animation(Motion.snappy, value: Int((reader.scale * 100).rounded()))
                    .frame(minWidth: 38)
            }
            .buttonStyle(TextButtonStyle())
            .help(tr("适合窗口", "Fit to window") + " ⌘0")
            Button { reader.pdf.zoomIn() } label: { Label(tr("放大", "Zoom In"), systemImage: "plus") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(tr("放大", "Zoom in") + " ⌘=")
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
        reader.pdf.view = view

        if reader.currentPage > 1 {
            view.pendingPage = reader.document.page(at: reader.currentPage - 1)
        }
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.contextItems = contextItems
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
                }
            })
            // 滚动时让工具条跟随选中文字
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateSelectionRect() }
                })
            }
            view.onMouseDown = { [weak self] in
                self?.reader.selectionBarVisible = false
            }
            view.onMouseUp = { [weak self] in
                guard let self else { return }
                self.updateSelectionRect()
                self.reader.selectionBarVisible = !self.reader.selection.isEmpty && self.reader.selectionRect != nil
            }
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

/// 用自绘菜单替换系统右键菜单，并把鼠标按下/松开告知选中工具条。
final class ReaderPDFView: PDFView {
    var contextItems: ((String?) -> [PopMenuItem])?
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
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
        super.mouseDown(with: event)
        // PDFView 可能在 mouseDown 内部跟踪拖选：返回时鼠标若已松开，就在这里收尾
        if NSApp.currentEvent?.type == .leftMouseUp { onMouseUp?() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard let window, let contextItems else { return }
        onMouseDown?()
        let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = contextItems(text?.isEmpty == false ? text : nil)
        PopMenu.shared.show(items, placement: .at(window.convertPoint(toScreen: event.locationInWindow)), in: window)
    }
}
