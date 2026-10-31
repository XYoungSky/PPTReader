import AppKit
import QuartzCore
import SwiftUI

enum PanelKeys {
    static let showsSidebar = "ui.showsSidebar"
    static let showsChat = "ui.showsChat"
    static let sidebarWidth = "ui.sidebarWidth"
    static let chatWidth = "ui.chatWidth"
}

/// 三栏布局。两侧面板开合时保持自身宽度、整体平移（像抽屉一样滑入滑出，内容不重排），
/// 中间阅读区每一帧随之伸缩；动画由显示器刷新驱动，PDFView 与 WKWebView 严格同步。
struct MainSplitView: NSViewRepresentable {
    let model: AppModel
    let showsSidebar: Bool
    let showsChat: Bool

    func makeNSView(context: Context) -> PanelContainerView {
        PanelContainerView(model: model, showsSidebar: showsSidebar, showsChat: showsChat)
    }

    func updateNSView(_ view: PanelContainerView, context: Context) {
        view.setSidebar(visible: showsSidebar)
        view.setChat(visible: showsChat)
    }
}

final class PanelContainerView: NSView {
    private enum Side { case sidebar, chat }

    private struct Transition {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
    }

    private static let duration: CFTimeInterval = 0.34
    private static let sidebarRange: ClosedRange<CGFloat> = 200...380
    private static let chatRange: ClosedRange<CGFloat> = 360...820
    private static let minCenter: CGFloat = 380

    private let sidebarHost: NSView
    private let centerHost: NSView
    private let chatHost: NSView
    private let sidebarDivider = DividerLine()
    private let chatDivider = DividerLine()
    private let sidebarGrip = ResizeGrip()
    private let chatGrip = ResizeGrip()

    private var sidebarWidth: CGFloat
    private var chatWidth: CGFloat
    /// 0 = 收起，1 = 展开。
    private var sidebarProgress: CGFloat
    private var chatProgress: CGFloat
    private var transitions: [Side: Transition] = [:]
    private var link: CADisplayLink?

    init(model: AppModel, showsSidebar: Bool, showsChat: Bool) {
        func host(_ view: some View) -> NSView {
            let hosting = NSHostingView(rootView: AnyView(
                view
                    .environment(model)
                    .environment(model.settings)
                    .ignoresSafeArea()
            ))
            hosting.sizingOptions = []
            return hosting
        }
        sidebarHost = host(SidebarView { UserDefaults.standard.set(false, forKey: PanelKeys.showsSidebar) })
        centerHost = host(ReaderColumn())
        chatHost = host(ChatPanel { UserDefaults.standard.set(false, forKey: PanelKeys.showsChat) })

        let defaults = UserDefaults.standard
        sidebarWidth = (defaults.object(forKey: PanelKeys.sidebarWidth) as? Double).map { CGFloat($0) } ?? 248
        chatWidth = (defaults.object(forKey: PanelKeys.chatWidth) as? Double).map { CGFloat($0) } ?? 460
        sidebarProgress = showsSidebar ? 1 : 0
        chatProgress = showsChat ? 1 : 0
        super.init(frame: .zero)

        clipsToBounds = true
        // 中间在最下层，两侧面板与分隔线在上层
        for view in [centerHost, sidebarHost, chatHost, sidebarDivider, chatDivider, sidebarGrip, chatGrip] {
            addSubview(view)
        }
        sidebarGrip.onDrag = { [weak self] delta, phase in self?.resize(.sidebar, delta: delta, phase: phase) }
        chatGrip.onDrag = { [weak self] delta, phase in self?.resize(.chat, delta: -delta, phase: phase) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        // 窗口变窄时优先保证中间阅读区的最小宽度
        let maxChat = max(Self.chatRange.lowerBound, width - Self.minCenter - (sidebarProgress > 0 ? sidebarWidth + 1 : 0))
        let chatW = min(chatWidth, maxChat)

        // 按屏幕像素对齐，避免 PDF 边缘在亚像素间抖动
        let scale = window?.backingScaleFactor ?? 2
        let sidebarVisible = ((sidebarWidth + 1) * sidebarProgress * scale).rounded() / scale
        let chatVisible = ((chatW + 1) * chatProgress * scale).rounded() / scale

        sidebarHost.frame = NSRect(x: sidebarVisible - sidebarWidth - 1, y: 0, width: sidebarWidth, height: height)
        sidebarDivider.frame = NSRect(x: sidebarHost.frame.maxX, y: 0, width: 1, height: height)
        centerHost.frame = NSRect(x: sidebarVisible, y: 0, width: max(width - sidebarVisible - chatVisible, 0), height: height)
        chatDivider.frame = NSRect(x: width - chatVisible, y: 0, width: 1, height: height)
        chatHost.frame = NSRect(x: width - chatVisible + 1, y: 0, width: chatW, height: height)

        sidebarGrip.frame = NSRect(x: sidebarDivider.frame.minX - 4, y: 0, width: 9, height: height)
        chatGrip.frame = NSRect(x: chatDivider.frame.minX - 4, y: 0, width: 9, height: height)

        let sidebarShown = sidebarProgress > 0
        let chatShown = chatProgress > 0
        sidebarHost.isHidden = !sidebarShown
        sidebarDivider.isHidden = !sidebarShown
        chatHost.isHidden = !chatShown
        chatDivider.isHidden = !chatShown
        // 动画中或收起时不响应拖动
        sidebarGrip.isHidden = sidebarProgress < 1
        chatGrip.isHidden = chatProgress < 1
    }

    // MARK: - 开合

    func setSidebar(visible: Bool) { animate(.sidebar, to: visible ? 1 : 0) }
    func setChat(visible: Bool) { animate(.chat, to: visible ? 1 : 0) }

    private func progress(of side: Side) -> CGFloat {
        side == .sidebar ? sidebarProgress : chatProgress
    }

    private func setProgress(_ value: CGFloat, of side: Side) {
        if side == .sidebar { sidebarProgress = value } else { chatProgress = value }
    }

    private func animate(_ side: Side, to target: CGFloat) {
        let current = transitions[side]?.to ?? progress(of: side)
        guard current != target else { return }
        guard window != nil, !Motion.reduced else {
            transitions[side] = nil
            setProgress(target, of: side)
            needsLayout = true
            return
        }
        transitions[side] = Transition(from: progress(of: side), to: target, start: CACurrentMediaTime())
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (side, transition) in transitions {
            let t = min(max((now - transition.start) / Self.duration, 0), 1)
            let eased = CGFloat(Self.curve(t))
            setProgress(transition.from + (transition.to - transition.from) * eased, of: side)
            if t >= 1 { transitions[side] = nil }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if transitions.isEmpty {
            link.invalidate()
            self.link = nil
        }
    }

    /// 抽屉曲线：起步从容、收尾柔和（cubic-bezier(0.32, 0.72, 0, 1)），顶栏动画使用同一条曲线。
    private static let easing = UnitBezier(0.32, 0.72, 0, 1)

    private static func curve(_ t: Double) -> Double {
        easing.solve(t)
    }

    // MARK: - 拖动调整宽度

    private func resize(_ side: Side, delta: CGFloat, phase: ResizeGrip.Phase) {
        switch phase {
        case .began, .changed:
            if side == .sidebar {
                sidebarWidth = min(max(dragStart(side) + delta, Self.sidebarRange.lowerBound), Self.sidebarRange.upperBound)
            } else {
                let limit = min(Self.chatRange.upperBound, bounds.width - Self.minCenter - (sidebarProgress > 0 ? sidebarWidth + 1 : 0))
                chatWidth = min(max(dragStart(side) + delta, Self.chatRange.lowerBound), max(limit, Self.chatRange.lowerBound))
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        case .ended:
            dragOrigin[side] = nil
            UserDefaults.standard.set(Double(sidebarWidth), forKey: PanelKeys.sidebarWidth)
            UserDefaults.standard.set(Double(chatWidth), forKey: PanelKeys.chatWidth)
        }
    }

    private var dragOrigin: [Side: CGFloat] = [:]

    private func dragStart(_ side: Side) -> CGFloat {
        if let origin = dragOrigin[side] { return origin }
        let origin = side == .sidebar ? sidebarWidth : chatWidth
        dragOrigin[side] = origin
        return origin
    }
}

/// 1px 分隔线。
private final class DividerLine: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = Theme.borderNSColor.cgColor
    }
}

/// 分隔线两侧的拖动区域：悬停显示左右箭头光标，拖动时高亮。
private final class ResizeGrip: NSView {
    enum Phase { case began, changed, ended }

    var onDrag: ((CGFloat, Phase) -> Void)?
    private var startX: CGFloat = 0
    private let highlight = CALayer()
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.backgroundColor = NSColor(hex: 0xD97757, alpha: 0.55).cgColor
        highlight.opacity = 0
        layer?.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true, delay: 0.15) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false, delay: 0) }

    private func setHighlighted(_ on: Bool, delay: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = highlight.presentation()?.opacity ?? highlight.opacity
        animation.toValue = on ? 1 : 0
        animation.beginTime = CACurrentMediaTime() + delay
        animation.duration = 0.15
        animation.fillMode = .backwards
        highlight.opacity = on ? 1 : 0
        highlight.add(animation, forKey: "opacity")
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onDrag?(0, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX, .ended)
        setHighlighted(false, delay: 0)
    }
}

/// 三次贝塞尔缓动（与 CSS cubic-bezier 相同），用于让 AppKit 与 SwiftUI 的动画曲线一致。
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    func solve(_ x: Double) -> Double {
        sampleY(solveT(x))
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func derivativeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveT(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-5 { return t }
            let d = derivativeX(t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        // 牛顿法未收敛时退回二分
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let value = sampleX(t)
            if abs(value - x) < 1e-5 { return t }
            if x > value { lo = t } else { hi = t }
            t = (lo + hi) / 2
            if hi - lo < 1e-6 { break }
        }
        return t
    }
}
