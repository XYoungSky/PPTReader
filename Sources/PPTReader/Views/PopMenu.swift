import AppKit
import Observation
import SwiftUI

/// 自绘菜单项：与界面统一的圆角卡片菜单（替代系统灰色菜单）。
struct PopMenuItem: Identifiable {
    enum Kind { case action, separator, header }

    let id = UUID()
    var kind: Kind = .action
    var title = ""
    var icon: String?
    var shortcut: String?
    var checked = false
    var destructive = false
    var enabled = true
    var action: () -> Void = {}

    init(_ title: String, icon: String? = nil, shortcut: String? = nil, checked: Bool = false,
         destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.checked = checked
        self.destructive = destructive
        self.enabled = enabled
        self.action = action
    }

    private init(kind: Kind, title: String = "") {
        self.kind = kind
        self.title = title
    }

    static var separator: PopMenuItem { PopMenuItem(kind: .separator) }
    static func header(_ title: String) -> PopMenuItem { PopMenuItem(kind: .header, title: title) }

    var isSelectable: Bool { kind == .action && enabled }
}

@MainActor
@Observable
final class PopMenuModel {
    var items: [PopMenuItem]
    var highlighted: UUID?
    /// 菜单从哪个方向展开，用于出现动画的锚点。
    var anchor: UnitPoint

    init(items: [PopMenuItem], anchor: UnitPoint) {
        self.items = items
        self.anchor = anchor
    }

    func move(_ delta: Int) {
        let selectable = items.filter(\.isSelectable)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : selectable.count)
        highlighted = selectable[(index + delta + selectable.count) % selectable.count].id
    }
}

/// 负责在主窗口上方弹出菜单面板，处理键盘与点击外部关闭。
@MainActor
final class PopMenu {
    static let shared = PopMenu()

    enum Placement {
        /// 在按钮下方弹出；trailing 表示菜单右边缘与按钮右边缘对齐。
        case below(NSRect, trailing: Bool)
        /// 右键菜单：左上角对齐鼠标位置。
        case at(NSPoint)
    }

    /// 菜单卡片四周为阴影预留的透明边距。
    private static let margin: CGFloat = 18

    private var panel: MenuPanel?
    private var model: PopMenuModel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var anchorRect: NSRect?

    var isShowing: Bool { panel != nil }

    func show(_ items: [PopMenuItem], placement: Placement, in window: NSWindow?, minWidth: CGFloat = 196) {
        dismiss(animated: false)
        guard let window, items.contains(where: { $0.kind == .action }) else { return }

        var anchor = UnitPoint.topLeading
        if case .below(_, let trailing) = placement { anchor = trailing ? .topTrailing : .topLeading }
        let model = PopMenuModel(items: items, anchor: anchor)
        let view = PopMenuView(model: model, minWidth: minWidth, margin: Self.margin) { [weak self] item in
            self?.select(item)
        }
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        let size = hosting.fittingSize

        // 计算位置（屏幕坐标，原点在左下）
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let cardWidth = size.width - Self.margin * 2
        let cardHeight = size.height - Self.margin * 2
        var origin: NSPoint
        switch placement {
        case .below(let rect, let trailing):
            anchorRect = rect
            let x = trailing ? rect.maxX - cardWidth : rect.minX
            var top = rect.minY - 4
            if top - cardHeight < screen.minY { top = rect.maxY + 4 + cardHeight }
            origin = NSPoint(x: x, y: top - cardHeight)
        case .at(let point):
            anchorRect = nil
            var x = point.x
            var top = point.y
            if x + cardWidth > screen.maxX { x = point.x - cardWidth }
            if top - cardHeight < screen.minY { top = point.y + cardHeight }
            origin = NSPoint(x: x, y: top - cardHeight)
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - cardWidth - 4)
        let frame = NSRect(x: origin.x - Self.margin, y: origin.y - Self.margin, width: size.width, height: size.height)

        let panel = MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = hosting
        panel.appearance = window.effectiveAppearance
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        self.panel = panel
        self.model = model
        installMonitors(owner: window)
    }

    func dismiss(animated: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let panel else { return }
        self.panel = nil
        model = nil
        anchorRect = nil
        let close = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard animated, !Motion.reduced else { close(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { close() }
        }
    }

    private func select(_ item: PopMenuItem) {
        guard item.isSelectable else { return }
        dismiss()
        // 等菜单关闭后再执行，避免动作里又弹出新菜单时互相干扰
        DispatchQueue.main.async { item.action() }
    }

    private func installMonitors(owner: NSWindow) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            switch event.keyCode {
            case 125: model.move(1)
            case 126: model.move(-1)
            case 36, 76:
                if let item = model.items.first(where: { $0.id == model.highlighted }) { self.select(item) }
            case 53: self.dismiss()
            default: return event
            }
            return nil
        } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel {
                let card = panel.contentView?.bounds.insetBy(dx: Self.margin, dy: Self.margin) ?? .zero
                if card.contains(event.locationInWindow) || event.type == .scrollWheel { return event }
            }
            let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            let onAnchor = self.anchorRect?.contains(screenPoint) ?? false
            self.dismiss()
            // 点在触发按钮上：只关闭菜单（不重新打开）；右键：让新的右键菜单正常弹出
            if onAnchor || event.type == .leftMouseDown || event.type == .otherMouseDown { return nil }
            return event
        } as Any)

        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(animated: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        })
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 非激活面板中的第一次点击也能直接触发按钮。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PopMenuView: View {
    let model: PopMenuModel
    let minWidth: CGFloat
    let margin: CGFloat
    let onSelect: (PopMenuItem) -> Void
    @ViewState private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.items) { item in
                switch item.kind {
                case .separator:
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                case .header:
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10)
                        .padding(.top, 5)
                        .padding(.bottom, 3)
                case .action:
                    PopMenuRow(item: item, highlighted: model.highlighted == item.id) { hovering in
                        if hovering { model.highlighted = item.id } else if model.highlighted == item.id { model.highlighted = nil }
                    } onSelect: {
                        onSelect(item)
                    }
                }
            }
        }
        .padding(5)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .scaleEffect(appeared ? 1 : 0.96, anchor: model.anchor)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -3)
        .padding(margin)
        .onAppear {
            withAnimation(Motion.reduced ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)) { appeared = true }
        }
    }
}

private struct PopMenuRow: View {
    let item: PopMenuItem
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12.5))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
            .foregroundStyle(item.destructive ? Color(nsColor: .systemRed) : Theme.text2)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(item.destructive ? Color(nsColor: .systemRed) : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)

            Spacer(minLength: 16)

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            if item.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted && item.enabled ? Theme.hover : .clear)
        )
        .opacity(item.enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture { if item.enabled { onSelect() } }
        .animation(.easeOut(duration: 0.08), value: highlighted)
    }
}

// MARK: - 触发菜单的按钮

/// 记录按钮对应的 NSView，用于计算菜单弹出位置。
final class MenuAnchor {
    weak var view: NSView?

    @MainActor
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct AnchorReader: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// 点按后在下方弹出自绘菜单的按钮。
struct PopMenuButton<Label: View, Style: ButtonStyle>: View {
    var trailing = false
    let style: Style
    let items: () -> [PopMenuItem]
    @ViewBuilder let label: Label
    @ViewState private var anchor = MenuAnchor()

    init(trailing: Bool = false, style: Style, items: @escaping () -> [PopMenuItem], @ViewBuilder label: () -> Label) {
        self.trailing = trailing
        self.style = style
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button {
            guard let rect = anchor.screenRect else { return }
            PopMenu.shared.show(items(), placement: .below(rect, trailing: trailing), in: anchor.view?.window)
        } label: {
            label
        }
        .buttonStyle(style)
        .background(AnchorReader(anchor: anchor))
    }
}

extension View {
    /// 右键弹出自绘菜单。
    func popContextMenu(_ items: @escaping () -> [PopMenuItem]) -> some View {
        overlay(RightClickCatcher(items: items))
    }
}

/// 只拦截右键的透明层：左键照常交给下面的视图。
private struct RightClickCatcher: NSViewRepresentable {
    let items: () -> [PopMenuItem]

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.items = items }

    final class CatcherView: NSView {
        var items: (() -> [PopMenuItem])?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let window, let items else { return }
            PopMenu.shared.show(items(), placement: .at(window.convertPoint(toScreen: event.locationInWindow)), in: window)
        }
    }
}
