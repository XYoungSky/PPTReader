import AppKit
import SwiftUI

struct ModelSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProviderList()
            // 切换服务商时重建编辑区，Key 输入框与测试结果随之重置
            ProviderEditor()
                .id(settings.activeProviderID)
            TaskModelSettings()
        }
    }
}

/// 按任务选择模型：默认都跟随“讲解与提问”，也可以给某类任务单独选服务商、模型和思考参数。
private struct TaskModelSettings: View {
    var body: some View {
        SettingsCard(title: tr("按任务选择模型", "Models by task"),
                     footer: tr("默认都跟随“讲解与提问”，也就是上方正在使用的服务商和 AI 面板里选的模型。换成别的模型后，这个任务单独使用缓存，命中率会低一些。",
                                "Every task follows Explain & ask by default: the provider in use above and the model chosen in the AI panel. A task on another model keeps its own cache, so it hits the cache less often.")) {
            let tasks = ModelTask.allCases.filter(\.isAvailable)
            ForEach(tasks) { task in
                TaskModelRow(task: task, last: task == tasks.last)
            }
        }
    }
}

private struct TaskModelRow: View {
    @Environment(AppSettings.self) private var settings
    let task: ModelTask
    /// 卡片里的最后一项：最后一行不画分隔线。
    let last: Bool

    var body: some View {
        let ref = settings.taskModels[task]
        let provider = ref.flatMap { ref in settings.providers.first { $0.id == ref.providerID } }
        let warning = warning(ref, provider)
        VStack(spacing: 0) {
            SettingsRow(title: task.title, detail: task.strength.title + " · " + (warning ?? task.summary),
                        detailColor: warning == nil ? Theme.text3 : Theme.danger, divider: !(last && provider == nil)) {
                if task.isConfigurable {
                    providerMenu(ref)
                } else {
                    Text(chatSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            if let ref, let provider {
                let hasThinking = provider.kind.hasThinkingToggle || provider.kind.hasReasoningEffort
                VStack(spacing: 0) {
                    modelRow(ref, provider, divider: !(last && !hasThinking))
                    if provider.kind.hasThinkingToggle {
                        thinkingRow(ref, provider)
                    } else if provider.kind.hasReasoningEffort {
                        effortRow(ref, provider)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            }
        }
        .animation(Motion.content, value: ref)
        .animation(Motion.content, value: warning)
    }

    private var chatSummary: String {
        let model = settings.effectiveModel.isEmpty ? tr("未选择模型", "No model") : settings.effectiveModel
        return settings.activeProvider.name + " · " + model
    }

    /// 设置里需要提醒的情况；没有时为空。
    private func warning(_ ref: ModelRef?, _ provider: APIProvider?) -> String? {
        if ref == nil, let removed = settings.taskFallbacks[task] {
            return tr("“\(removed)”已删除，已改回跟随讲解与提问", "“\(removed)” was deleted, so this follows Explain & ask again")
        }
        guard let ref, let provider else { return nil }
        if ref.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tr("没有填写模型，暂时跟随讲解与提问", "No model entered; following Explain & ask for now")
        }
        if !settings.hasKey(for: provider.id) {
            return tr("“\(provider.name)”还没有设置 API Key", "“\(provider.name)” has no API key yet")
        }
        return nil
    }

    private func providerMenu(_ ref: ModelRef?) -> some View {
        let current = ref.flatMap { ref in settings.providers.first { $0.id == ref.providerID } }
        return PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
            var items = [PopMenuItem(tr("跟随讲解与提问", "Follow Explain & ask"), checked: ref == nil) {
                settings.setTaskModel(nil, for: task)
            }]
            items.append(.separator)
            items.append(.header(tr("单独选择服务商", "Use a provider")))
            items += settings.providers.map { provider in
                PopMenuItem(provider.name.isEmpty ? tr("未命名", "Untitled") : provider.name, checked: ref?.providerID == provider.id) {
                    guard ref?.providerID != provider.id else { return }
                    // 先填上这个服务商正在用的模型，再按需要换成轻量的
                    let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.setTaskModel(ModelRef(providerID: provider.id, model: model), for: task)
                }
            }
            return items
        } label: {
            HStack(spacing: 5) {
                Text(current.map { $0.name.isEmpty ? tr("未命名", "Untitled") : $0.name } ?? tr("跟随讲解与提问", "Follow Explain & ask"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .fixedSize()
        .accessibilityLabel(task.title)
    }

    private func modelRow(_ ref: ModelRef, _ provider: APIProvider, divider: Bool) -> some View {
        let choices = settings.modelMenuChoices(for: provider.id, current: ref.model.trimmingCharacters(in: .whitespacesAndNewlines))
        let text = Binding(
            get: { settings.taskModels[task]?.model ?? "" },
            set: { value in
                guard var ref = settings.taskModels[task] else { return }
                ref.model = value
                settings.setTaskModel(ref, for: task)
            }
        )
        return SettingsRow(title: tr("模型", "Model"), divider: divider) {
            HStack(spacing: 6) {
                ThemedField(text: text, placeholder: tr("输入或选择模型", "Enter or choose a model"), monospaced: true)
                PopMenuButton(trailing: true, style: IconButtonStyle(size: 30)) {
                    choices.map { name in
                        PopMenuItem(name, shortcut: settings.priceLabel(provider.id, name), checked: name == ref.model,
                                    filterable: true) { settings.chooseTaskModel(name, for: task) }
                    }
                } label: {
                    Label(tr("选择模型", "Choose model"), systemImage: "chevron.up.chevron.down")
                }
                .disabled(choices.isEmpty)
            }
            .frame(width: 300)
        }
    }

    /// 深度思考（DeepSeek 类型）：跟随服务商，或者为这个任务单独开关。
    private func thinkingRow(_ ref: ModelRef, _ provider: APIProvider) -> some View {
        let follow = tr("跟随服务商", "Provider setting") + (provider.thinking ? tr("（开启）", " (on)") : tr("（关闭）", " (off)"))
        let title = ref.thinking.map { $0 ? tr("开启", "On") : tr("关闭", "Off") } ?? follow
        return SettingsRow(title: tr("深度思考", "Deep thinking"), divider: !last) {
            optionMenu(title, items: [
                PopMenuItem(follow, checked: ref.thinking == nil) { update { $0.thinking = nil } },
                .separator,
                PopMenuItem(tr("开启", "On"), checked: ref.thinking == true) { update { $0.thinking = true } },
                PopMenuItem(tr("关闭", "Off"), checked: ref.thinking == false) { update { $0.thinking = false } },
            ])
        }
    }

    /// 思考强度（Kimi Code、OpenRouter 类型）：跟随服务商，或者为这个任务单独选。
    private func effortRow(_ ref: ModelRef, _ provider: APIProvider) -> some View {
        let options = provider.kind.reasoningEfforts
        // 改过接口类型后，保存的值可能不在选项里，显示为“默认”（请求里也不会发送）
        func shown(_ effort: ReasoningEffort) -> ReasoningEffort { options.contains(effort) ? effort : .auto }
        let follow = tr("跟随服务商", "Provider setting") + tr("（\(shown(provider.reasoningEffort).title)）", " (\(shown(provider.reasoningEffort).title))")
        let title = ref.reasoningEffort.map { shown($0).title } ?? follow
        return SettingsRow(title: tr("思考强度", "Thinking effort"), divider: !last) {
            optionMenu(title, items: [PopMenuItem(follow, checked: ref.reasoningEffort == nil) { update { $0.reasoningEffort = nil } }, .separator]
                + options.map { effort in
                    PopMenuItem(effort.title, checked: ref.reasoningEffort.map(shown) == effort) { update { $0.reasoningEffort = effort } }
                })
        }
    }

    private func optionMenu(_ title: String, items: [PopMenuItem]) -> some View {
        PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
            items
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .fixedSize()
    }

    private func update(_ change: (inout ModelRef) -> Void) {
        guard var ref = settings.taskModels[task] else { return }
        change(&ref)
        settings.setTaskModel(ref, for: task)
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
                                PopMenuItem(name, shortcut: settings.priceLabel(providerID, name), checked: name == settings.effectiveModel,
                                            filterable: true) { settings.chooseModel(name) }
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
                if settings.activeProvider.kind.hasPrivacyRouting {
                    SettingsRow(title: tr("隐私", "Privacy"),
                                detail: tr("只用不收集数据、或零数据保留的上游；限制越多可用的上游越少，有的模型可能会没有上游可用",
                                           "Use only providers that don't collect data, or zero-retention endpoints. The stricter it is, the fewer providers qualify, and some models may have none")) {
                        SegmentedPicker(selection: $settings.activeProvider.privacy,
                                        options: ProviderPrivacy.allCases.map { ($0, $0.title) })
                            .accessibilityLabel(tr("隐私", "Privacy"))
                    }
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
            tr("API Key 在 openrouter.ai/settings/keys 创建。模型名带服务商前缀，例如 anthropic/…、openai/…、deepseek/…；测试连接后，在模型菜单里直接输入名称即可搜索，右侧是每百万 token 的输入 / 输出价格（美元）。",
               "Create a key at openrouter.ai/settings/keys. Model names carry a provider prefix such as anthropic/…, openai/… or deepseek/…. After testing the connection, type in the model menu to search; the right side shows input / output prices in USD per million tokens.")
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
            case .models(let list):
                settings.updateProvider(providerID) {
                    $0.fetchedModels = list.names
                    $0.detectedContextWindows = list.windows
                    $0.modelInfo = list.infos
                }
                withAnimation(Motion.content) { testState = .success(list.names.count) }
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
