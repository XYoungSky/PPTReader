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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProviderList()
            // 切换服务商时重建编辑区，Key 输入框与测试结果随之重置
            ProviderEditor()
                .id(settings.activeProviderID)
        }
    }
}

/// 保存的服务商列表：点按切换正在使用的服务商。
private struct ProviderList: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SettingsCard(title: tr("服务商", "Providers"),
                     footer: tr("最多保存 \(AppSettings.maxProviders) 个服务商，点按即可切换；下方编辑的是正在使用的服务商。",
                                "Save up to \(AppSettings.maxProviders) providers and click one to switch. The settings below apply to the provider in use.")) {
            ForEach(settings.providers) { provider in
                ProviderRow(provider: provider,
                            active: provider.id == settings.activeProviderID,
                            canDelete: settings.providers.count > 1) {
                    withAnimation(Motion.content) { settings.activeProviderID = provider.id }
                } onDelete: {
                    confirmDelete(provider)
                }
            }
            HStack(spacing: 8) {
                PopMenuButton(style: TextButtonStyle()) {
                    [.header(tr("从模板添加", "Add from template"))] + ProviderPreset.allCases.map { preset in
                        PopMenuItem(preset.menuTitle) {
                            withAnimation(Motion.content) { _ = settings.addProvider(preset) }
                        }
                    }
                } label: {
                    Label(tr("添加服务商", "Add Provider"), systemImage: "plus")
                }
                .fixedSize()
                .disabled(!settings.canAddProvider)
                Spacer()
                Text("\(settings.providers.count) / \(AppSettings.maxProviders)")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
        }
    }

    /// 与清空对话一致：在鼠标位置弹出确认菜单。
    private func confirmDelete(_ provider: APIProvider) {
        let settings = settings
        PopMenu.shared.show([
            .header(tr("同时删除保存的 API Key", "Its saved API key is removed too")),
            PopMenuItem(tr("删除“\(provider.name)”", "Delete “\(provider.name)”"), icon: "trash", destructive: true) {
                withAnimation(Motion.content) { settings.removeProvider(provider.id) }
            },
            PopMenuItem(tr("取消", "Cancel"), icon: "xmark") {},
        ], placement: .at(NSEvent.mouseLocation), in: NSApp.keyWindow, minWidth: 200)
    }
}

private struct ProviderRow: View {
    let provider: APIProvider
    let active: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text2 : Theme.text3))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name.isEmpty ? tr("未命名", "Untitled") : provider.name)
                        .font(.system(size: 13, weight: active ? .medium : .regular))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if canDelete && hovering {
                    Button(action: onDelete) {
                        Label(tr("删除", "Delete"), systemImage: "trash")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help(tr("删除服务商", "Delete provider"))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.leading, 14)
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onSelect() }
    }

    private var detail: String {
        var parts = [provider.summary.isEmpty ? tr("未填写地址", "No URL") : provider.summary]
        if !provider.hasKey { parts.append(tr("未设置 Key", "No key")) }
        return parts.joined(separator: " · ")
    }
}

/// 编辑正在使用的服务商。
private struct ProviderEditor: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var keyDraft = ""
    @ViewState private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success(Int), reachable, failure(String)
    }

    var body: some View {
        @Bindable var settings = settings
        let providerID = settings.activeProviderID
        let isKimiCode = OpenAIClient.isKimiCode(settings.baseURL)
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("名称", "Name")) {
                    ThemedField(text: $settings.activeProvider.name, placeholder: tr("服务商名称", "Provider name"))
                        .frame(width: 300)
                }
                SettingsRow(title: tr("API 地址", "Base URL")) {
                    ThemedField(text: $settings.baseURL, placeholder: AppSettings.defaultBaseURL, monospaced: true)
                        .frame(width: 300)
                }
                SettingsRow(title: "API Key") {
                    ThemedField(text: $keyDraft, placeholder: "sk-…", secure: true, monospaced: true)
                        .frame(width: 300)
                        .onChange(of: keyDraft) { _, value in settings.setAPIKey(value, for: providerID) }
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

            SettingsCard(footer: isKimiCode ? tr(
                "Kimi Code 会员订阅的 API Key 在 Kimi Code 控制台创建；海外账号请把地址改为 https://api.kimi.ai/coding/v1。会员权益面向编程场景，如果请求被拒绝，可以改用 Kimi 开放平台。",
                "Create the key in the Kimi Code console. For international accounts, use https://api.kimi.ai/coding/v1. Membership benefits are meant for coding; if requests are refused, use the Kimi Platform instead."
            ) : nil) {
                if OpenAIClient.isDeepSeek(settings.baseURL) {
                    SettingsRow(title: tr("深度思考", "Deep thinking"), detail: tr("更准确，但更慢", "More accurate, slower")) {
                        Toggle("", isOn: $settings.thinking)
                            .toggleStyle(AccentToggleStyle())
                            .labelsHidden()
                    }
                }
                if isKimiCode {
                    SettingsRow(title: tr("思考强度", "Thinking effort"), detail: tr("越高越准确，但更慢、更耗额度", "Higher is more accurate but slower and uses more quota")) {
                        SegmentedPicker(selection: $settings.activeProvider.reasoningEffort,
                                        options: ReasoningEffort.allCases.map { ($0, $0.title) })
                            .accessibilityLabel(tr("思考强度", "Thinking effort"))
                    }
                }
                SettingsRow(title: tr("测试连接", "Test connection"), detail: testDetail, detailColor: testFailed ? Theme.danger : Theme.text3, divider: false) {
                    Button(testState == .testing ? tr("测试中…", "Testing…") : tr("测试", "Test")) { Task { await test(providerID) } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(testState == .testing)
                }
            }
        }
        .onAppear { keyDraft = settings.storedKey(for: providerID) }
    }

    private var testDetail: String? {
        switch testState {
        case .idle: nil
        case .testing: nil
        case .success(let count): tr("✓ 可用，\(count) 个模型", "✓ Connected, \(count) models")
        case .reachable: tr("✓ 可用（接口未提供模型列表）", "✓ Connected (no model list provided)")
        case .failure(let message): "✕ \(message)"
        }
    }

    private var testFailed: Bool {
        if case .failure = testState { return true }
        return false
    }

    private func test(_ providerID: UUID) async {
        settings.setAPIKey(keyDraft, for: providerID)
        withAnimation(Motion.content) { testState = .testing }
        do {
            switch try await OpenAIClient.testConnection(config: settings.connection) {
            case .models(let models):
                settings.updateProvider(providerID) { $0.fetchedModels = models }
                withAnimation(Motion.content) { testState = .success(models.count) }
            case .reachable:
                withAnimation(Motion.content) { testState = .reachable }
            }
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
