import AppKit
import SwiftUI

/// 设置窗口：自己管理 NSWindow，便于隐藏标题栏、统一外观。
@MainActor
enum SettingsWindow {
    static var model: AppModel?
    private static var window: NSWindow?

    /// - Parameter section: 打开后切换到的分区；为空时停留在上次的分区。
    static func show(_ section: SettingsSection? = nil) {
        if let section { SettingsRouter.shared.section = section }
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

/// 设置窗口当前显示的分区，放在窗口之外，便于从 AI 面板等处直接跳到某个分区。
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var section: SettingsSection = .model
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case model, explain, explanationStyle, notes, appearance, shortcuts, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: tr("模型", "Model")
        case .explain: tr("讲解", "Tutor")
        case .explanationStyle: tr("讲解风格", "Explanation style")
        case .notes: tr("学习档案", "Study notes")
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
        case .notes: "person.text.rectangle"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .data: "externaldrive"
        }
    }
}

struct SettingsView: View {
    private var router: SettingsRouter { SettingsRouter.shared }
    private var section: SettingsSection { router.section }

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
                        case .notes: NotesSettings()
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
                    withAnimation(Motion.content) { router.section = item }
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
        if !provider.hasKey && !OpenAIClient.isLocal(provider.baseURL) { parts.append(tr("未设置 Key", "No key")) }
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
        let kimiKeyMismatch = OpenAIClient.isKimiCodeKey(keyDraft) && !OpenAIClient.isKimiCode(settings.baseURL)
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
                ProviderKindRow()
                SettingsRow(title: "API Key") {
                    ThemedField(text: $keyDraft, placeholder: OpenAIClient.isLocal(settings.baseURL) ? tr("本机服务可不填", "Optional for local servers") : "sk-…",
                                secure: true, monospaced: true)
                        .frame(width: 300)
                        .onChange(of: keyDraft) { _, value in settings.setAPIKey(value, for: providerID) }
                }
                // Kimi Code 会员的 Key 填在了别的地址（常见于开放平台 api.moonshot.cn），请求会返回 401
                if kimiKeyMismatch {
                    SettingsRow(title: tr("这是 Kimi Code 会员的 Key", "This is a Kimi Code membership key"),
                                detail: tr("只能用于 Kimi Code 地址；开放平台需要在 platform.moonshot.cn 另外创建 Key",
                                           "It only works with the Kimi Code URL. The Kimi Platform needs its own key from platform.moonshot.cn"),
                                detailColor: Theme.danger) {
                        Button(tr("改用 Kimi Code 地址", "Use Kimi Code URL")) { useKimiCode() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    .transition(.opacity)
                }
                SettingsRow(title: tr("模型", "Model")) {
                    HStack(spacing: 6) {
                        ThemedField(text: $settings.model, placeholder: tr("输入或选择模型", "Enter or choose a model"), monospaced: true)
                        PopMenuButton(trailing: true, style: IconButtonStyle(size: 30)) {
                            settings.modelMenuChoices.map { name in
                                PopMenuItem(name, checked: name == settings.effectiveModel, filterable: true) { settings.chooseModel(name) }
                            }
                        } label: {
                            Label(tr("选择模型", "Choose model"), systemImage: "chevron.up.chevron.down")
                        }
                        .disabled(settings.modelChoices.isEmpty)
                    }
                    .frame(width: 300)
                }
                ContextWindowRow()
            }

            SettingsCard(footer: providerFooter) {
                if settings.activeProvider.kind.hasThinkingToggle {
                    SettingsRow(title: tr("深度思考", "Deep thinking"), detail: tr("更准确，但更慢", "More accurate, slower")) {
                        Toggle("", isOn: $settings.thinking)
                            .toggleStyle(AccentToggleStyle())
                            .labelsHidden()
                    }
                }
                if settings.activeProvider.kind.hasCacheTTL {
                    SettingsRow(title: tr("缓存保留 1 小时", "Keep cache for 1 hour"),
                                detail: tr("默认只保留 5 分钟；改为 1 小时后首次写入按 2 倍计费，之后一小时内的提问都按缓存价计算",
                                           "The default is 5 minutes. With 1 hour the first write costs twice as much, but questions within the hour are billed at the cache rate")) {
                        Toggle("", isOn: $settings.activeProvider.longCache)
                            .toggleStyle(AccentToggleStyle())
                            .labelsHidden()
                    }
                }
                if settings.activeProvider.kind.hasReasoningEffort {
                    ReasoningEffortRow()
                }
                let notes = settings.detectionNotes
                if !notes.isEmpty {
                    SettingsRow(title: tr("自动检测到的限制", "Detected limits"),
                                detail: notes.joined(separator: " · ") + tr("。换了模型版本或服务商修复后可以重置", ". Reset after the model or provider changes")) {
                        Button(tr("重置", "Reset")) { withAnimation(Motion.content) { settings.resetDetection() } }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
                SettingsRow(title: tr("测试连接", "Test connection"), detail: testDetail, detailColor: testFailed ? Theme.danger : Theme.text3, divider: false) {
                    Button(testState == .testing ? tr("测试中…", "Testing…") : tr("测试", "Test")) { Task { await test(providerID) } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(testState == .testing)
                }
            }
        }
        .animation(Motion.content, value: kimiKeyMismatch)
        .onAppear { keyDraft = settings.storedKey(for: providerID) }
    }

    private var providerFooter: String? {
        switch settings.activeProvider.kind {
        case .kimiCode:
            tr("Kimi Code 会员订阅的 API Key 在 Kimi Code 控制台创建；海外账号请把地址改为 https://api.kimi.ai/coding/v1。会员权益面向编程场景，如果请求被拒绝，可以改用 Kimi 开放平台。",
               "Create the key in the Kimi Code console. For international accounts, use https://api.kimi.ai/coding/v1. Membership benefits are meant for coding; if requests are refused, use the Kimi Platform instead.")
        case .openRouter:
            tr("API Key 在 openrouter.ai/settings/keys 创建。模型名带服务商前缀，例如 anthropic/…、openai/…、deepseek/…；测试连接后，在模型菜单里直接输入名称即可搜索。",
               "Create a key at openrouter.ai/settings/keys. Model names carry a provider prefix such as anthropic/…, openai/… or deepseek/…. After testing the connection, type in the model menu to search.")
        default:
            nil
        }
    }

    /// 地址换成 Kimi Code；原来的模型和模型列表属于别的服务商，一并换成 kimi-for-coding。
    private func useKimiCode() {
        withAnimation(Motion.content) {
            settings.activeProvider.baseURL = ProviderPreset.kimiCode.baseURL
            settings.activeProvider.kind = .kimiCode
            settings.activeProvider.model = ProviderPreset.kimiCode.model
            settings.activeProvider.fetchedModels = []
            testState = .idle
        }
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
            case .models(let models, let windows):
                settings.updateProvider(providerID) {
                    $0.fetchedModels = models
                    $0.detectedContextWindows = windows
                }
                withAnimation(Motion.content) { testState = .success(models.count) }
            case .reachable:
                withAnimation(Motion.content) { testState = .reachable }
            }
        } catch {
            withAnimation(Motion.content) { testState = .failure(error.localizedDescription) }
        }
    }
}

/// 思考强度。选项少（Kimi Code）时用分段控件；OpenRouter 的选项多，放不下，改用下拉菜单。
private struct ReasoningEffortRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let kind = settings.activeProvider.kind
        let options = kind.reasoningEfforts
        // 改过接口类型后，保存的值可能不在新的选项里：显示为“默认”（请求里也不会发送）
        let current = options.contains(settings.activeProvider.reasoningEffort) ? settings.activeProvider.reasoningEffort : .auto
        let detail = kind == .openRouter
            ? tr("越高越准确，但更慢、更耗额度。各模型支持的强度不同，“关闭”对必须思考的模型无效", "Higher is more accurate but slower and uses more credits. Models support different levels; Off has no effect on models that always reason")
            : tr("越高越准确，但更慢、更耗额度", "Higher is more accurate but slower and uses more quota")
        SettingsRow(title: tr("思考强度", "Thinking effort"), detail: detail) {
            if options.count <= 4 {
                SegmentedPicker(selection: $settings.activeProvider.reasoningEffort,
                                options: options.map { ($0, $0.title) })
                    .accessibilityLabel(tr("思考强度", "Thinking effort"))
            } else {
                PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
                    options.map { effort in
                        PopMenuItem(effort.title, checked: effort == current) { settings.activeProvider.reasoningEffort = effort }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(current.title)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .fixedSize()
                .accessibilityLabel(tr("思考强度", "Thinking effort"))
            }
        }
    }
}

/// 接口类型：决定发送哪些专有参数。认得出的官方地址会自动设置，经代理或中转访问时在这里手动选。
private struct ProviderKindRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let kind = settings.activeProvider.kind
        SettingsRow(title: tr("接口类型", "API type"),
                    detail: tr("决定是否发送深度思考、思考强度等专有参数；经代理访问时按实际服务选择",
                               "Decides whether provider-specific options such as thinking are sent; pick the real service when using a proxy")) {
            PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
                ProviderPreset.allCases.map { preset in
                    PopMenuItem(preset.menuTitle, checked: preset == kind) { settings.activeProvider.kind = preset }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(kind.name)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .fixedSize()
        }
    }
}

/// 当前模型的上下文窗口：默认采用接口报告的值，接口没有报告时按 128K 计算，也可以手动选择。
private struct ContextWindowRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let manual = settings.activeProvider.contextWindow
        let detected = settings.detectedContextWindow
        let detail: String = if manual != nil {
            tr("手动设置", "Set manually") + (detected.map { tr("，接口报告 ", "; the API reports ") + TokenEstimate.label($0) } ?? "")
        } else if let detected {
            tr("接口报告 ", "Reported by the API: ") + TokenEstimate.label(detected)
        } else {
            tr("接口没有提供，按 \(TokenEstimate.label(AppSettings.defaultContextWindow)) 计算；可按服务商的模型说明修改",
               "Not reported by the API, so \(TokenEstimate.label(AppSettings.defaultContextWindow)) is assumed. Check the provider's model docs to change it.")
        }
        SettingsRow(title: tr("上下文窗口", "Context window"), detail: detail, divider: false) {
            PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
                var items = [PopMenuItem(tr("自动", "Automatic") + "（\(TokenEstimate.label(detected ?? AppSettings.defaultContextWindow))）",
                                         checked: manual == nil) { settings.activeProvider.contextWindow = nil }]
                items.append(.separator)
                items += AppSettings.contextWindowPresets.map { value in
                    PopMenuItem(TokenEstimate.label(value), checked: manual == value) { settings.activeProvider.contextWindow = value }
                }
                return items
            } label: {
                HStack(spacing: 5) {
                    Text(TokenEstimate.label(settings.contextWindow) + (manual == nil ? tr("（自动）", " (auto)") : ""))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .fixedSize()
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

            SettingsCard(footer: tr("框选后可以就框内的图、公式或文字提问：框内截图和文字会一起发给模型；模型不支持识图或关闭了截图时只发文字。",
                                    "After boxing an area you can ask about the figure, formula or text inside it: a screenshot of the box and its text are sent together, or just the text if the model can't see images or screenshots are off.")) {
                SettingsRow(title: tr("在课件上拖动", "Dragging on slides"),
                            detail: tr("按住 Shift 拖动时换成另一种", "Hold Shift while dragging for the other one"), divider: false) {
                    SegmentedPicker(selection: $settings.dragSelectsRegion,
                                    options: [(false, tr("选文字", "Select text")), (true, tr("框选", "Draw box"))])
                        .accessibilityLabel(tr("在课件上拖动", "Dragging on slides"))
                }
            }

            SettingsCard(title: tr("上下文", "Context"),
                         footer: tr("课件或对话超出上限时，保留当前页附近的课件和最近的对话。模型的上下文窗口在「模型」中设置。",
                                    "When the deck or chat exceeds a limit, the pages around the current one and the latest messages are kept. Set the model's context window under Model.")) {
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
                SettingsRow(title: tr("携带历史消息", "Chat history")) {
                    SegmentedPicker(selection: $settings.historyLimit, options: [(8, "8"), (16, "16"), (32, "32")])
                }
                SettingsRow(title: tr("整理较早的对话", "Condense earlier messages"),
                            detail: tr("超出上限时先整理成学习记录再丢弃，模型记得讲过什么；每次整理多一次请求",
                                       "Before old messages are dropped, they're condensed into a study record so the tutor remembers them; costs one extra request each time")) {
                    Toggle("", isOn: $settings.compactHistory)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("上下文上限", "Context limit"),
                            detail: tr("占模型上下文窗口的比例，其余留给回答 · 约 \(TokenEstimate.label(settings.contextTokenBudget)) / \(TokenEstimate.label(settings.contextWindow))",
                                       "Share of the model's context window; the rest is left for the answer · about \(TokenEstimate.label(settings.contextTokenBudget)) of \(TokenEstimate.label(settings.contextWindow))"),
                            divider: false) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.contextBudgetPercent, in: 0.2...0.9, step: 0.05)
                            .tint(Theme.accent)
                            .controlSize(.small)
                            .frame(width: 150)
                            .accessibilityLabel(tr("上下文上限", "Context limit"))
                        Text(StatsFormat.percent(settings.contextBudgetPercent))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 学习档案

/// 分层的学习档案（参考 Claude Code 的 CLAUDE.md 与 Codex 的 AGENTS.md）：
/// 关于我（所有课件通用）→ 课程说明（按课程文件夹）→ 学习记录（每份课件自动整理）。
private struct NotesSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let chat = model.chat
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: tr("关于我", "About me"),
                         footer: tr("所有课件通用，例如专业、年级、已经学过的课、学习目标。放在系统提示里，修改后的下一次提问生效。",
                                    "Applies to every deck: your major, year, courses you've taken, what you're aiming for. It goes into the system prompt and takes effect from your next question.")) {
                NoteEditor(text: $settings.learnerProfile, limit: AppSettings.profileLimit, height: 72,
                           placeholder: tr("例如：电子信息专业大二，线性代数学过但不熟，目标是期末 85 分以上。",
                                           "e.g. Second-year electrical engineering; I've taken linear algebra but I'm rusty; aiming for a high grade in the final."))
            }

            if let course = chat.course {
                SettingsCard(title: tr("课程说明 · ", "Course notes · ") + course.lastPathComponent,
                             footer: tr("这门课的所有课件共用，例如老师强调的重点、记号约定、考试范围。保存在 PPTReader 的数据中，课程文件夹本身不会被修改。",
                                        "Shared by every deck in this course, such as what the lecturer stresses, notation and exam scope. Stored in PPTReader's data; the course folder itself is never changed.")) {
                    NoteEditor(text: Binding(get: { settings.courseNotes(for: course) },
                                             set: { settings.setCourseNotes($0, for: course) }),
                               limit: AppSettings.courseNotesLimit, height: 120,
                               placeholder: tr("例如：老师说第 4 章只考计算不考证明；本课程向量一律用粗体表示；期中范围是第 1–5 章。",
                                               "e.g. Chapter 4 is tested on calculations only, not proofs; vectors are written in bold; the midterm covers chapters 1–5."))
                }
            } else {
                SettingsCard(title: tr("课程说明", "Course notes"),
                             footer: tr("打开一份课件后，可以为它所在的课程写说明。", "Open a deck to write notes for its course.")) {
                    EmptyView()
                }
            }

            if let record = chat.record {
                SettingsCard(title: tr("学习记录 · 当前课件", "Study record · this deck"),
                             footer: tr("对话超出上限时自动整理，代替被丢弃的较早对话。清除后，那些对话会在下次超出上限时重新整理。",
                                        "Written automatically when the chat exceeds the limit, in place of the earlier messages that are dropped. If cleared, they're condensed again the next time the limit is reached.")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            Text(record.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        HStack {
                            Text(tr("已整理 \(record.messageCount) 条消息", "\(record.messageCount) messages condensed"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                            Spacer()
                            Button(tr("清除记录", "Clear Record")) { chat.clearRecord() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

/// 多行文字输入框，带字数上限和占位文字。
private struct NoteEditor: View {
    @Binding var text: String
    let limit: Int
    let height: CGFloat
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
            )
            .animation(Motion.hover, value: focused)
            Text("\(text.count) / \(limit)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(text.count >= limit ? Theme.danger : Theme.text3)
        }
        .padding(14)
        .onChange(of: text) { _, value in
            if value.count > limit { text = String(value.prefix(limit)) }
        }
    }
}

// MARK: - 讲解风格

private struct ExplanationStyleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let style = settings.explanationStyle
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(footer: tr("对之后的回答生效，已有的回答不变。在消息里直接提的要求（如“详细点”“画个图”“举个例子”）优先于这里的设置。",
                                    "Applies to new answers; existing ones stay as they are. Anything you ask for in a message (more detail, a diagram, an example) takes precedence.")) {
                SettingsRow(title: tr("篇幅", "Length"), detail: style.detail.summary) {
                    SegmentedPicker(selection: $settings.explanationStyle.detail,
                                    options: ExplanationStyle.Detail.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("篇幅", "Length"))
                }
                SettingsRow(title: tr("图示", "Diagrams"), detail: style.diagrams.summary) {
                    SegmentedPicker(selection: $settings.explanationStyle.diagrams,
                                    options: ExplanationStyle.Diagrams.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("图示", "Diagrams"))
                }
                SettingsRow(title: tr("例题", "Worked examples"), detail: style.examples.summary, divider: false) {
                    SegmentedPicker(selection: $settings.explanationStyle.examples,
                                    options: ExplanationStyle.Examples.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("例题", "Worked examples"))
                }
            }
            .animation(Motion.content, value: style)

            CustomStyleCard(text: $settings.explanationStyle.custom)

            HStack {
                Spacer()
                Button(tr("恢复默认", "Restore Defaults")) {
                    withAnimation(Motion.content) { settings.explanationStyle = ExplanationStyle() }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(style == ExplanationStyle())
            }
        }
    }
}

/// 自定义要求：自由填写，或点按下方的短语加入 / 移除。
private struct CustomStyleCard: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let limit = ExplanationStyle.customLimit
        SettingsCard(title: tr("自定义要求", "Custom instructions"),
                     footer: tr("随每次提问发给模型；和上面的选项冲突时，以这里写的为准。",
                                "Sent with every question. Where it conflicts with the options above, this wins.")) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focused)
                    if text.isEmpty {
                        Text(tr("写下你希望模型怎么讲，例如：多结合工程里的实际应用；推导写完整；每讲完一部分提一个思考题。",
                                "Describe how you'd like things explained, e.g. relate ideas to real engineering uses; write out full derivations; end each part with a question to think about."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 92)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
                )
                .animation(Motion.hover, value: focused)

                HStack(alignment: .top, spacing: 12) {
                    FlowLayout(spacing: 6) {
                        ForEach(ExplanationStyle.customSuggestions, id: \.title) { suggestion in
                            SuggestionChip(title: suggestion.title, selected: text.contains(suggestion.text)) {
                                withAnimation(Motion.snappy) { toggle(suggestion.text) }
                            }
                            .help(suggestion.text)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(text.count) / \(limit)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(text.count >= limit ? Theme.danger : Theme.text3)
                        .padding(.top, 5)
                }
            }
            .padding(14)
        }
        .onChange(of: text) { _, value in
            if value.count > limit { text = String(value.prefix(limit)) }
        }
    }

    /// 已有这句话就移除，否则另起一行加在末尾。
    private func toggle(_ sentence: String) {
        if text.contains(sentence) {
            text = text.replacingOccurrences(of: sentence, with: "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = current.isEmpty ? sentence : current + "\n" + sentence
        }
    }
}

private struct SuggestionChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule().fill(selected ? Theme.accent.opacity(0.1) : (hovering ? Theme.selected : Theme.hover))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 按行排列、放不下就换行的布局。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
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
