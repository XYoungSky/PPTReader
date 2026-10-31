import SwiftUI
import WebKit

struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if !settings.hasAPIKey {
                KeyBanner()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ChatWebView(bridge: model.chat.web)
            Composer()
        }
        .background(Theme.panel)
        .animation(Motion.content, value: settings.hasAPIKey)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(tr("AI 讲解", "AI Tutor"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            ModelMenu()
            Button {
                settings.autoExplain.toggle()
            } label: {
                Label(tr("翻页自动讲解", "Auto-explain"), systemImage: "wand.and.stars")
                    .symbolEffect(.bounce, value: settings.autoExplain)
            }
            .buttonStyle(IconButtonStyle(isOn: settings.autoExplain))
            .help(tr("翻页自动讲解", "Auto-explain on page turn") + (settings.autoExplain ? " ✓" : ""))
            PopMenuButton(trailing: true, style: IconButtonStyle(), items: moreItems) {
                Label(tr("更多", "More"), systemImage: "ellipsis")
            }
            .help(tr("更多", "More"))
            Button(action: onClose) {
                Label(tr("隐藏", "Hide"), systemImage: "sidebar.right")
            }
            .buttonStyle(IconButtonStyle())
            .help(tr("隐藏 AI 面板", "Hide AI panel") + " ⌥⌘0")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.barHeight)
        .background(WindowDragArea())
    }

    private func moreItems() -> [PopMenuItem] {
        let sizes: [(String, Double)] = [(tr("较小", "Small"), 14), (tr("标准", "Default"), 15), (tr("较大", "Medium"), 16), (tr("大", "Large"), 17), (tr("特大", "Extra Large"), 18)]
        var items: [PopMenuItem] = [.header(tr("字号", "Text Size"))]
        items += sizes.map { name, size in
            PopMenuItem(name, checked: settings.chatFontSize == size) { settings.chatFontSize = size }
        }
        items += [
            .separator,
            .header(tr("字体", "Font")),
            PopMenuItem(tr("无衬线", "Sans Serif"), checked: !settings.chatSerif) { settings.chatSerif = false },
            PopMenuItem(tr("衬线", "Serif"), checked: settings.chatSerif) { settings.chatSerif = true },
            .separator,
            PopMenuItem(tr("清空对话…", "Clear Chat…"), icon: "trash", destructive: true, enabled: model.chat.hasMessages) { confirmClear() },
            PopMenuItem(tr("设置…", "Settings…"), icon: "gearshape", shortcut: "⌘,") { SettingsWindow.show() },
        ]
        return items
    }

    /// 二次确认：在鼠标位置弹出确认菜单，而不是系统对话框。
    private func confirmClear() {
        let chat = model.chat
        PopMenu.shared.show([
            .header(tr("清空后无法恢复", "This can't be undone")),
            PopMenuItem(tr("清空对话", "Clear Chat"), icon: "trash", destructive: true) { chat.clear() },
            PopMenuItem(tr("取消", "Cancel"), icon: "xmark") {},
        ], placement: .at(NSEvent.mouseLocation), in: NSApp.mainWindow, minWidth: 160)
    }
}

private struct ModelMenu: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        PopMenuButton(trailing: true, style: TextButtonStyle(font: .system(size: 12))) {
            var items = settings.modelChoices.map { name in
                PopMenuItem(name, checked: name == settings.effectiveModel) { settings.model = name }
            }
            items += [.separator, PopMenuItem(tr("模型设置…", "Model Settings…"), icon: "gearshape") { SettingsWindow.show() }]
            return items
        } label: {
            HStack(spacing: 4) {
                Text(settings.effectiveModel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text3)
            }
        }
        .fixedSize()
        .help(tr("切换模型", "Switch model"))
    }
}

private struct KeyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(Theme.accent)
            Text(tr("未设置 API Key", "No API key yet"))
                .foregroundStyle(Theme.text2)
            Spacer()
            Button(tr("设置", "Set up")) { SettingsWindow.show() }
                .buttonStyle(TextButtonStyle())
        }
        .font(.system(size: 12.5))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08)))
    }
}

struct ChatWebView: NSViewRepresentable {
    let bridge: ChatWebBridge

    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - 输入区

private struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = model.chat
        let reader = model.reader
        let selection = reader?.selection ?? ""
        let busy = reader == nil || chat.isStreaming

        VStack(alignment: .leading, spacing: 12) {
            if !selection.isEmpty {
                SelectionPreview(text: selection) { reader?.pdf.clearSelection() }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }

            TextField(tr("就这份课件提问…", "Ask about this deck…"), text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.text)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit { chat.sendDraft() }
                .padding(.horizontal, 4)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Button {
                    chat.perform(.explainPage(auto: false))
                } label: {
                    Label(tr("讲解本页", "Explain page"), systemImage: "sparkles")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(busy)
                .help("⌘E")

                PopMenuButton(style: OutlineButtonStyle()) {
                    [QuickAction.summary, .outline, .quiz].map { action in
                        PopMenuItem(action.title, icon: action.symbol) { chat.perform(.quick(action)) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(tr("更多", "More"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .fixedSize()
                .disabled(busy)

                Spacer(minLength: 0)

                // DeepSeek 的深度思考开关（关闭后回答更快）
                if OpenAIClient.isDeepSeek(model.settings.baseURL) {
                    Button {
                        model.settings.thinking.toggle()
                    } label: {
                        Label(tr("思考", "Think"), systemImage: "brain")
                            .symbolEffect(.bounce, value: model.settings.thinking)
                    }
                    .buttonStyle(OutlineButtonStyle(isOn: model.settings.thinking))
                    .help(tr("深度思考：更准确，但更慢", "Deep thinking: more accurate, slower"))
                }
                sendButton
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(focused ? 0.07 : 0.045), radius: focused ? 18 : 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(focused ? Theme.text3.opacity(0.55) : Theme.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(Motion.snappy, value: selection.isEmpty)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onChange(of: chat.focusRequest) { focused = true }
    }

    private var sendEnabled: Bool {
        model.reader != nil && !model.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        let streaming = model.chat.isStreaming
        let active = streaming || sendEnabled
        return Button {
            if streaming { model.chat.stop() } else { model.chat.sendDraft() }
        } label: {
            Image(systemName: streaming ? "stop.fill" : "arrow.up")
                .font(.system(size: streaming ? 11 : 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(active ? 1 : 0.35))
                )
        }
        .buttonStyle(PressStyle())
        .disabled(!active)
        .help(streaming ? tr("停止", "Stop") + " ⌘." : tr("发送 ↩︎ · 换行 ⌥↩︎", "Send ↩︎ · New line ⌥↩︎"))
        .animation(Motion.content, value: active)
        .animation(Motion.content, value: streaming)
    }
}

private struct SelectionPreview: View {
    let text: String
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            Text(text)
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.hover))
            }
            .buttonStyle(.plain)
            .help(tr("取消引用", "Remove quote"))
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

/// 只有按下缩放反馈的按钮样式。
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
