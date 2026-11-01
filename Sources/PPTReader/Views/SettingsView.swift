import AppKit
import SwiftUI

/// 设置窗口：自己管理 NSWindow，便于隐藏标题栏、统一外观。
@MainActor
enum SettingsWindow {
    static var model: AppModel?
    private static var window: NSWindow?

    static func show() {
        guard let model else { return }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView()
                .environment(model)
                .environment(model.settings))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.panelNSColor
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 540))
            window.center()
            self.window = window
        }
        window?.title = tr("设置", "Settings")
        window?.makeKeyAndOrderFront(nil)
        // 不自动聚焦第一个输入框
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        NSApp.activate()
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case model, explain, explanationStyle, appearance, shortcuts, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: tr("模型", "Model")
        case .explain: tr("讲解", "Tutor")
        case .explanationStyle: tr("讲解风格", "Explanation style")
        case .appearance: tr("外观", "Appearance")
        case .shortcuts: tr("快捷键", "Shortcuts")
        case .data: tr("数据", "Data")
        }
    }

    var icon: String {
        switch self {
        case .model: "cpu"
        case .explain: "sparkles"
        case .explanationStyle: "slider.horizontal.3"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .data: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @ViewState private var section: SettingsSection = .model

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(section.title)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text)
                    Group {
                        switch section {
                        case .model: ModelSettings()
                        case .explain: ExplainSettings()
                        case .explanationStyle: ExplanationStyleSettings()
                        case .appearance: AppearanceSettings()
                        case .shortcuts: ShortcutSettings()
                        case .data: DataSettings()
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(section)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            .scrollIndicators(.never)
            .background(Theme.panel)
        }
        .frame(width: 760, height: 540)
        .ignoresSafeArea()
        .onChange(of: section) { ShortcutStore.shared.endRecording() }
        .onDisappear { ShortcutStore.shared.endRecording() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 48)
            ForEach(SettingsSection.allCases) { item in
                SectionButton(section: item, selected: section == item) {
                    withAnimation(Motion.content) { section = item }
                }
            }
            Spacer()
            Text("PPTReader \(AppInfo.version)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 10)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 190)
        .background(Theme.sidebar)
    }
}

private struct SectionButton: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.accent : Theme.text2)
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: selected)
    }
}

// MARK: - 模型

private struct ModelSettings: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var keyDraft = ""
    @ViewState private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success(Int), failure(String)
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("API 地址", "Base URL")) {
                    ThemedField(text: $settings.baseURL, placeholder: AppSettings.defaultBaseURL, monospaced: true)
                        .frame(width: 300)
                }
                SettingsRow(title: "API Key") {
                    ThemedField(text: $keyDraft, placeholder: "sk-…", secure: true, monospaced: true)
                        .frame(width: 300)
                        .onChange(of: keyDraft) { _, value in settings.setAPIKey(value) }
                }
                SettingsRow(title: tr("模型", "Model"), divider: false) {
                    HStack(spacing: 6) {
                        ThemedField(text: $settings.model, placeholder: tr("输入或选择模型", "Enter or choose a model"), monospaced: true)
                        PopMenuButton(trailing: true, style: IconButtonStyle(size: 30)) {
                            settings.modelChoices.map { name in
                                PopMenuItem(name, checked: name == settings.effectiveModel) { settings.model = name }
                            }
                        } label: {
                            Label(tr("选择模型", "Choose model"), systemImage: "chevron.up.chevron.down")
                        }
                        .disabled(settings.modelChoices.isEmpty)
                    }
                    .frame(width: 300)
                }
            }

            SettingsCard {
                if OpenAIClient.isDeepSeek(settings.baseURL) {
                    SettingsRow(title: tr("深度思考", "Deep thinking"), detail: tr("更准确，但更慢", "More accurate, slower")) {
                        Toggle("", isOn: $settings.thinking)
                            .toggleStyle(AccentToggleStyle())
                            .labelsHidden()
                    }
                }
                SettingsRow(title: tr("测试连接", "Test connection"), detail: testDetail, detailColor: testFailed ? Theme.danger : Theme.text3, divider: false) {
                    Button(testState == .testing ? tr("测试中…", "Testing…") : tr("测试", "Test")) { Task { await test() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(testState == .testing)
                }
            }
        }
        .onAppear { keyDraft = settings.apiKey }
    }

    private var testDetail: String? {
        switch testState {
        case .idle: nil
        case .testing: nil
        case .success(let count): tr("✓ 可用，\(count) 个模型", "✓ Connected, \(count) models")
        case .failure(let message): "✕ \(message)"
        }
    }

    private var testFailed: Bool {
        if case .failure = testState { return true }
        return false
    }

    private func test() async {
        settings.setAPIKey(keyDraft)
        withAnimation(Motion.content) { testState = .testing }
        do {
            let models = try await OpenAIClient.listModels(config: settings.connection)
            settings.fetchedModels = models
            withAnimation(Motion.content) { testState = .success(models.count) }
        } catch {
            withAnimation(Motion.content) { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - 讲解

private struct ExplainSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("翻页自动讲解", "Auto-explain on page turn")) {
                    Toggle("", isOn: $settings.autoExplain)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("停留多久后讲解", "Delay"), divider: false) {
                    SegmentedPicker(selection: $settings.autoExplainDelay, options: [(1.0, "1s"), (1.5, "1.5s"), (3.0, "3s"), (5.0, "5s")])
                }
            }

            SettingsCard(title: tr("上下文", "Context")) {
                SettingsRow(title: tr("附带当前页截图", "Attach page screenshot"),
                            detail: tr("让模型看到图片与公式", "Lets the model see figures and formulas")) {
                    Toggle("", isOn: $settings.sendPageImage)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("课件文字上限", "Deck text limit")) {
                    SegmentedPicker(selection: $settings.contextCharLimit, options: [
                        (120_000, tr("12 万字", "120K")),
                        (400_000, tr("40 万字", "400K")),
                        (1_000_000, tr("100 万字", "1M")),
                    ])
                }
                SettingsRow(title: tr("携带历史消息", "Chat history"), divider: false) {
                    SegmentedPicker(selection: $settings.historyLimit, options: [(8, "8"), (16, "16"), (32, "32")])
                }
            }
        }
    }
}

// MARK: - 讲解风格

private struct ExplanationStyleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsCard {
            SettingsRow(title: tr("回答详略", "Answer detail")) {
                SegmentedPicker(selection: $settings.explanationStyle.detail,
                                options: ExplanationStyle.Detail.allCases.map { ($0, $0.title) })
                    .accessibilityLabel(tr("回答详略", "Answer detail"))
            }
            SettingsRow(title: tr("图表使用", "Diagrams")) {
                SegmentedPicker(selection: $settings.explanationStyle.diagrams,
                                options: ExplanationStyle.Diagrams.allCases.map { ($0, $0.title) })
                    .accessibilityLabel(tr("图表使用", "Diagrams"))
            }
            SettingsRow(title: tr("例题数量", "Examples"), divider: false) {
                SegmentedPicker(selection: $settings.explanationStyle.examples,
                                options: ExplanationStyle.Examples.allCases.map { ($0, $0.title) })
                    .accessibilityLabel(tr("例题数量", "Examples"))
            }
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var localizer = Localizer.shared
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("语言", "Language")) {
                    SegmentedPicker(selection: $localizer.language, options: [
                        (.system, tr("跟随系统", "System")),
                        (.zh, "中文"),
                        (.en, "English"),
                    ])
                }
                SettingsRow(title: tr("讲解字号", "Text size")) {
                    SegmentedPicker(selection: $settings.chatFontSize, options: [
                        (14.0, "14"), (15.0, "15"), (16.0, "16"), (17.0, "17"), (18.0, "18"),
                    ])
                }
                SettingsRow(title: tr("讲解字体", "Font"), divider: false) {
                    SegmentedPicker(selection: $settings.chatSerif, options: [(false, tr("无衬线", "Sans")), (true, tr("衬线", "Serif"))])
                }
            }
        }
    }
}

// MARK: - 快捷键

private struct ShortcutSettings: View {
    var body: some View {
        let store = ShortcutStore.shared
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ShortcutAction.Group.allCases) { group in
                let actions = ShortcutAction.allCases.filter { $0.group == group }
                SettingsCard(title: group.title) {
                    ForEach(actions) { action in
                        let feedback = store.feedback?.action == action ? store.feedback?.value : nil
                        SettingsRow(title: action.title, detail: feedback?.text,
                                    detailColor: feedback?.isError == true ? Theme.danger : Theme.text3,
                                    divider: action != actions.last) {
                            ShortcutRecorder(action: action)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr("全部恢复默认", "Restore Defaults")) {
                    withAnimation(Motion.content) { store.resetAll() }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(!store.hasModifications)
            }
        }
        .animation(Motion.content, value: store.feedback?.value)
    }
}

/// 点按后录制下一次按下的组合键；⌫ 清除，esc 取消。
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ViewState private var hovering = false

    var body: some View {
        let store = ShortcutStore.shared
        let recording = store.recording == action
        let combo = store.combo(for: action)
        HStack(spacing: 4) {
            if store.isModified(action) && !recording {
                Button {
                    withAnimation(Motion.content) { store.reset(action) }
                } label: {
                    Label(tr("恢复默认", "Restore default"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help(tr("恢复默认", "Restore default") + (action.defaultCombo.map { "：" + $0.display } ?? ""))
                .transition(.opacity)
            }
            Button {
                store.toggleRecording(action)
            } label: {
                pill(recording: recording, combo: combo, held: store.heldModifiers)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if hovering && !recording && combo != nil {
                    Button {
                        withAnimation(Motion.content) { _ = store.set(nil, for: action) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .frame(width: 22, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("清除", "Clear"))
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .help(recording ? tr("⌫ 清除 · esc 取消", "⌫ clear · esc cancel") : tr("点按以录制", "Click to record"))
        }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.content, value: recording)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
        .accessibilityValue(combo?.display ?? tr("未设置", "None"))
    }

    private func pill(recording: Bool, combo: KeyCombo?, held: KeyCombo.Modifiers) -> some View {
        Group {
            if recording {
                Text(held.isEmpty ? tr("按下快捷键", "Type shortcut") : held.symbols + "…")
                    .foregroundStyle(Theme.accent)
            } else if let combo {
                Text(combo.display)
                    .foregroundStyle(Theme.text)
            } else {
                Text(tr("未设置", "None"))
                    .foregroundStyle(Theme.text3)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 112, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(recording ? Theme.accent.opacity(0.08) : (hovering ? Theme.selected : Theme.hover))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(recording ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 数据

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var cacheSize = ""
    @ViewState private var cleared = false
    @ViewState private var statsCleared = false

    var body: some View {
        SettingsCard {
            SettingsRow(title: tr("对话记录", "Chat history")) {
                Button(tr("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.chats]) }
                    .buttonStyle(OutlineButtonStyle())
            }
            SettingsRow(title: tr("学习统计", "Statistics"), detail: statsCleared ? tr("已清除", "Cleared") : nil) {
                HStack(spacing: 8) {
                    Button(tr("查看", "View")) { StatsWindow.show() }
                        .buttonStyle(OutlineButtonStyle())
                    Button(tr("清除…", "Clear…")) { confirmClearStats() }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.stats.log.isEmpty)
                }
            }
            SettingsRow(title: tr("转换与文字缓存", "Cache"), detail: cleared ? tr("已清除", "Cleared") : cacheSize, divider: false) {
                Button(tr("清除", "Clear")) {
                    try? FileManager.default.removeItem(at: AppPaths.convertedPDFs)
                    try? FileManager.default.removeItem(at: AppPaths.extractedText)
                    refreshSize()
                    withAnimation(Motion.content) { cleared = true }
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .onAppear(perform: refreshSize)
    }

    /// 与清空对话一致：在鼠标位置弹出确认菜单。
    private func confirmClearStats() {
        let stats = model.stats
        PopMenu.shared.show([
            .header(tr("清除后无法恢复", "This can't be undone")),
            PopMenuItem(tr("清除学习统计", "Clear Statistics"), icon: "trash", destructive: true) {
                stats.clear()
                withAnimation(Motion.content) { statsCleared = true }
            },
            PopMenuItem(tr("取消", "Cancel"), icon: "xmark") {},
        ], placement: .at(NSEvent.mouseLocation), in: NSApp.keyWindow, minWidth: 180)
    }

    private func refreshSize() {
        let bytes = [AppPaths.convertedPDFs, AppPaths.extractedText].reduce(Int64(0)) { total, dir in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        cacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
