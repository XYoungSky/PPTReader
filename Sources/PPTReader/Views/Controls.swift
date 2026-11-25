import SwiftUI

/// 陶土橙开关。
struct AccentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.selected)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(Motion.reduced ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                        configuration.isOn.toggle()
                    }
                }
        }
    }
}

/// 分段选择：选中块在选项之间滑动。
struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
        .accessibilityElement(children: .contain)
    }
}

/// 统一风格的输入框。
struct ThemedField: View {
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
        .foregroundStyle(Theme.text)
        .focused($focused)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.accent.opacity(focused ? 0.15 : 0), radius: 4)
        .animation(Motion.hover, value: focused)
    }
}

/// 说明文字收进标题旁边的 ⓘ：鼠标移上去很快弹出小气泡，移开收起；点按后固定显示，点别处关闭。
/// 页面上只留简短的标题和状态。（系统的 `.help` 要停一秒多，在设置窗口里有时不出现，也点不开，所以不用它。）
struct InfoTip: View {
    let text: String
    @ViewState private var shown = false
    /// 点按打开的：鼠标移开也不收起。
    @ViewState private var pinned = false
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11.5))
            .foregroundStyle(hovering || shown ? Theme.text2 : Theme.text3)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if hovering { shown = true }
                    }
                } else if !pinned {
                    shown = false
                }
            }
            .onTapGesture {
                pinned.toggle()
                shown = pinned
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            .onChange(of: shown) { _, value in
                if !value { pinned = false }
            }
            .animation(Motion.hover, value: hovering)
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pinned.toggle(); shown = pinned }
    }
}

/// 设置页中的卡片分组。
/// - footer: 卡片下面的一句话（短的、看一眼就该知道的）；更长的说明放 `help`，悬停标题旁的 ⓘ 时显示。
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                    if let help { InfoTip(text: help) }
                }
                .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 卡片中的一行：左侧标题与一行短说明（或状态），右侧控件。需要解释的放 `help`，悬停标题旁的 ⓘ 时显示。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = Theme.text3
    var help: String?
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        if let help { InfoTip(text: help) }
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(detailColor)
                            .transition(.opacity)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if divider {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}
