import AppKit
import SwiftUI

/// 全局配色与尺寸：暖灰中性色 + 陶土橙点缀，浅色/深色各一套。
enum Theme {
    static let sidebar = Color(light: 0xF3F2EC, dark: 0x1D1C1B)
    static let canvas = Color(nsColor: canvasNSColor)
    static let panel = Color(nsColor: panelNSColor)
    static let surface = Color(light: 0xFFFFFF, dark: 0x30302E)
    static let border = Color(nsColor: borderNSColor)
    static let hover = Color(light: 0x1F1E1D, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
    static let selected = Color(light: 0xE6E3D9, dark: 0x35342F)
    static let text = Color(light: 0x1F1E1D, dark: 0xF0EEE7)
    static let text2 = Color(light: 0x5E5C56, dark: 0xB4B1A7)
    static let text3 = Color(light: 0x9A978E, dark: 0x7C7971)
    static let accent = Color(light: 0xD97757, dark: 0xD97757)

    static let canvasNSColor = NSColor(light: 0xECEAE3, dark: 0x171716)
    static let borderNSColor = NSColor(light: 0xE3E0D7, dark: 0x3A3936)
    static let panelNSColor = NSColor(light: 0xFAF9F5, dark: 0x262624)

    static let barHeight: CGFloat = 44
    /// 红绿灯按钮占用的宽度。
    static let trafficLightsWidth: CGFloat = 78
}

/// 统一的动效参数。系统开启「减弱动态效果」时全部退化为无动画。
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 与侧栏、讲解面板开合同步的界面动画（面板本身由 AppKit 以相同时长驱动）。
    static var panel: Animation? { reduced ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34) }
    /// 列表展开、选中高亮移动。
    static var snappy: Animation? { reduced ? nil : .snappy(duration: 0.22) }
    /// 内容切换（加载状态、选中引用等）。
    static var content: Animation? { reduced ? nil : .easeOut(duration: 0.2) }
    /// 悬停反馈。
    static let hover: Animation = .easeOut(duration: 0.12)
    /// 按下反馈。
    static let press: Animation = .easeOut(duration: 0.08)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    convenience init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }
}

// MARK: - 按钮样式

/// 扁平图标按钮：悬停时出现浅色底。
struct IconButtonStyle: ButtonStyle {
    var isOn = false
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isOn: isOn, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.text : Theme.text2))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.selected : (hovering || isOn ? Theme.hover : .clear))
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: isOn)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 文字按钮：用于顶栏中的菜单、页码等。
struct TextButtonStyle: ButtonStyle {
    var font: Font = .system(size: 12.5, weight: .medium)

    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration, font: font)
    }

    private struct TextButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let font: Font
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(hovering ? Theme.text : Theme.text2)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.selected : (hovering ? Theme.hover : .clear))
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 带细边框的胶囊按钮（输入框中的「讲解本页」等）。
struct OutlineButtonStyle: ButtonStyle {
    /// 作为开关使用时的开启状态（陶土橙描边）。
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        OutlineBody(configuration: configuration, isOn: isOn)
    }

    private struct OutlineBody: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.text : Theme.text2))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(hovering ? 0.14 : 0.09)
                              : (configuration.isPressed ? Theme.selected : (hovering ? Theme.hover : .clear)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
                )
                .animation(Motion.hover, value: isOn)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.content, value: isEnabled)
        }
    }
}

/// 陶土橙实心按钮。
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - 窗口外观

/// 自绘顶栏的背景：可拖动窗口，双击缩放。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// 隐藏系统标题栏后，把红绿灯按钮垂直居中到自绘顶栏里。
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.align()
    }

    private final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(light: 0xF3F2EC, dark: 0x1D1C1B)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        override func layout() {
            super.layout()
            align()
        }

        func align() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = Theme.barHeight
            var frame = container.frame
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            if container.frame != frame { container.frame = frame }
            titlebar.frame = NSRect(x: 0, y: 0, width: frame.width, height: height)
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = NSPoint(x: 18 + CGFloat(index) * 20, y: (height - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
