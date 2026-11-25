import Foundation
import Observation

struct ConnectionConfig: Sendable {
    var providerID: UUID
    var kind: ProviderPreset
    var baseURL: String
    var apiKey: String
    var model: String
    /// 深度思考（仅对 DeepSeek 类型发送 `thinking` 参数，其他服务不认识这个参数）。
    var thinking: Bool
    /// 思考强度（仅对 Kimi Code、OpenRouter 类型发送）。
    var reasoningEffort: ReasoningEffort = .auto
    /// 缓存保留 1 小时（仅对支持的类型发送）。
    var longCache = false

    /// 服务商的缓存大约能保留多久；为空表示较长（DeepSeek 为数小时到数天）或不清楚，界面上不提示过期。
    var cacheLifetime: TimeInterval? {
        switch kind {
        case .kimiPlatform: longCache ? 3_600 : 300
        case .kimiCode: 300
        // 上游各家不同；Claude、OpenAI 的默认缓存都在 5 分钟左右
        case .openRouter: 300
        case .deepSeek: nil
        case .custom: OpenAIClient.isOpenAI(baseURL) ? 300 : nil
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let defaultBaseURL = "https://api.deepseek.com"
    /// 最多保存的服务商数量。
    static let maxProviders = 5

    private enum Key {
        static let providers = "api.providers"
        static let activeProvider = "api.activeProvider"
        // 以下 5 项是旧版本的单一配置，只在首次启动新版本时用来迁移
        static let baseURL = "api.baseURL"
        static let model = "api.model"
        static let thinking = "api.thinking"
        static let hasKey = "api.hasKey"
        static let fetchedModels = "api.fetchedModels"
        static let autoExplain = "explain.auto"
        static let autoExplainDelay = "explain.autoDelay"
        static let explanationDetail = "explain.style.detail"
        static let explanationDiagrams = "explain.style.diagrams"
        static let explanationExamples = "explain.style.examples"
        static let explanationCustom = "explain.style.custom"
        static let contextLimit = "context.charLimit"
        static let historyLimit = "context.historyLimit"
        static let budgetPercent = "context.budgetPercent"
        static let sendPageImage = "context.pageImage"
        static let noVisionModels = "context.noVisionModels"
        static let learnerProfile = "memory.profile"
        static let courseNotes = "memory.courseNotes"
        static let compactHistory = "context.compactHistory"
        static let chatFontSize = "ui.chatFontSize"
        static let chatSerif = "ui.chatSerif"
        static let figureOpacity = "ui.figureOpacity"
        static let dragSelectsRegion = "reader.dragSelectsRegion"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 保存的服务商（1…maxProviders 个），其中 `activeProviderID` 是正在使用的那个。
    private(set) var providers: [APIProvider] { didSet { saveProviders() } }
    var activeProviderID: UUID { didSet { defaults.set(activeProviderID.uuidString, forKey: Key.activeProvider) } }
    var autoExplain: Bool { didSet { defaults.set(autoExplain, forKey: Key.autoExplain) } }
    var autoExplainDelay: Double { didSet { defaults.set(autoExplainDelay, forKey: Key.autoExplainDelay) } }
    var explanationStyle: ExplanationStyle {
        didSet {
            defaults.set(explanationStyle.detail.rawValue, forKey: Key.explanationDetail)
            defaults.set(explanationStyle.diagrams.rawValue, forKey: Key.explanationDiagrams)
            defaults.set(explanationStyle.examples.rawValue, forKey: Key.explanationExamples)
            defaults.set(explanationStyle.custom, forKey: Key.explanationCustom)
        }
    }
    /// 放进上下文的课件文字上限（字符数）。
    var contextCharLimit: Int { didSet { defaults.set(contextCharLimit, forKey: Key.contextLimit) } }
    /// 每次请求携带的历史消息条数。
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Key.historyLimit) } }
    /// 一次请求最多占用模型上下文窗口的比例（0.2…0.9），其余留给回答。
    var contextBudgetPercent: Double { didSet { defaults.set(contextBudgetPercent, forKey: Key.budgetPercent) } }
    /// 随提问附上当前页截图，让模型看到图片与公式。
    var sendPageImage: Bool { didSet { defaults.set(sendPageImage, forKey: Key.sendPageImage) } }
    /// 实际请求中拒绝了图片的模型，之后不再给它们发送截图。
    var noVisionModels: [String] { didSet { defaults.set(noVisionModels, forKey: Key.noVisionModels) } }
    /// 学习者档案：学生写的背景和目标，所有课件通用（相当于 Claude Code 的用户级 CLAUDE.md）。
    var learnerProfile: String { didSet { defaults.set(learnerProfile, forKey: Key.learnerProfile) } }
    /// 课程说明：课程文件夹路径 → 说明（相当于项目级的 CLAUDE.md / AGENTS.md）。课程文件夹本身保持只读，说明存在这里。
    private(set) var courseNotes: [String: String] { didSet { defaults.set(courseNotes, forKey: Key.courseNotes) } }
    /// 对话超出上限时，把要丢掉的较早对话整理成学习记录，而不是直接丢掉。
    var compactHistory: Bool { didSet { defaults.set(compactHistory, forKey: Key.compactHistory) } }
    /// 讲解正文字号（pt）。
    var chatFontSize: Double { didSet { defaults.set(chatFontSize, forKey: Key.chatFontSize) } }
    /// 讲解正文使用衬线字体。
    var chatSerif: Bool { didSet { defaults.set(chatSerif, forKey: Key.chatSerif) } }
    /// 图表预览窗口的不透明度（0.3…1），半透明时可以透过它对照课件。
    var figureOpacity: Double { didSet { defaults.set(figureOpacity, forKey: Key.figureOpacity) } }
    static let figureOpacityRange = 0.3...1.0
    /// 在课件上拖动默认是框选（否则默认选文字）；按住 Shift 拖动临时换成另一种。
    var dragSelectsRegion: Bool { didSet { defaults.set(dragSelectsRegion, forKey: Key.dragSelectsRegion) } }

    @ObservationIgnored private var keyCache: [UUID: String] = [:]
    /// 也可以通过环境变量提供 Key（便于命令行启动和调试），在服务商没有保存 Key 时使用。
    @ObservationIgnored private let environmentKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var migrated = false
        let loaded: [APIProvider]
        if let data = defaults.data(forKey: Key.providers),
           let stored = try? JSONDecoder().decode([APIProvider].self, from: data), !stored.isEmpty {
            loaded = Array(stored.prefix(Self.maxProviders))
        } else {
            loaded = [Self.legacyProvider(defaults)]
            migrated = true
        }
        let storedActive = defaults.string(forKey: Key.activeProvider).flatMap(UUID.init(uuidString:))
        providers = loaded
        activeProviderID = loaded.first { $0.id == storedActive }?.id ?? loaded[0].id
        autoExplain = defaults.bool(forKey: Key.autoExplain)
        autoExplainDelay = defaults.object(forKey: Key.autoExplainDelay) as? Double ?? 1.5
        explanationStyle = ExplanationStyle(
            detail: ExplanationStyle.Detail(rawValue: defaults.string(forKey: Key.explanationDetail) ?? "") ?? .normal,
            diagrams: ExplanationStyle.Diagrams(rawValue: defaults.string(forKey: Key.explanationDiagrams) ?? "") ?? .normal,
            examples: ExplanationStyle.Examples(rawValue: defaults.string(forKey: Key.explanationExamples) ?? "") ?? .necessary,
            custom: defaults.string(forKey: Key.explanationCustom) ?? ""
        )
        contextCharLimit = defaults.object(forKey: Key.contextLimit) as? Int ?? 400_000
        historyLimit = defaults.object(forKey: Key.historyLimit) as? Int ?? 16
        contextBudgetPercent = min(max(defaults.object(forKey: Key.budgetPercent) as? Double ?? 0.8, 0.2), 0.9)
        sendPageImage = defaults.object(forKey: Key.sendPageImage) as? Bool ?? true
        noVisionModels = (defaults.stringArray(forKey: Key.noVisionModels) ?? []).filter { !$0.isEmpty }
        learnerProfile = defaults.string(forKey: Key.learnerProfile) ?? ""
        courseNotes = defaults.dictionary(forKey: Key.courseNotes) as? [String: String] ?? [:]
        compactHistory = defaults.object(forKey: Key.compactHistory) as? Bool ?? true
        chatFontSize = defaults.object(forKey: Key.chatFontSize) as? Double ?? 15
        chatSerif = defaults.bool(forKey: Key.chatSerif)
        dragSelectsRegion = defaults.bool(forKey: Key.dragSelectsRegion)
        figureOpacity = min(max(defaults.object(forKey: Key.figureOpacity) as? Double ?? 1, Self.figureOpacityRange.lowerBound),
                            Self.figureOpacityRange.upperBound)
        let envKey = ProcessInfo.processInfo.environment["PPTREADER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        environmentKey = envKey?.isEmpty == false ? envKey : nil
        if migrated {
            saveProviders()
            defaults.set(activeProviderID.uuidString, forKey: Key.activeProvider)
        }
    }

    /// 旧版本只有一组配置：转成第一个服务商，Key 继续使用原来的钥匙串条目。旧的设置项保留不删，方便回退版本。
    private static func legacyProvider(_ defaults: UserDefaults) -> APIProvider {
        let baseURL = defaults.string(forKey: Key.baseURL) ?? defaultBaseURL
        let preset = ProviderPreset.detect(baseURL)
        let host = URL(string: baseURL.contains("://") ? baseURL : "https://" + baseURL)?.host
        var provider = APIProvider(name: preset == .custom ? (host ?? preset.name) : preset.name,
                                   baseURL: baseURL, keyAccount: "api-key")
        provider.model = (defaults.string(forKey: Key.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provider.thinking = defaults.object(forKey: Key.thinking) as? Bool ?? true
        provider.fetchedModels = defaults.stringArray(forKey: Key.fetchedModels) ?? []
        provider.hasKey = defaults.bool(forKey: Key.hasKey)
        return provider
    }

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) { defaults.set(data, forKey: Key.providers) }
    }

    // MARK: - 服务商

    private var activeIndex: Int { providers.firstIndex { $0.id == activeProviderID } ?? 0 }

    /// 正在使用的服务商。设置页直接绑定它的字段进行编辑。
    var activeProvider: APIProvider {
        get { providers[activeIndex] }
        set { providers[activeIndex] = newValue }
    }

    var canAddProvider: Bool { providers.count < Self.maxProviders }

    /// 按模板新建一个服务商并切换过去。
    @discardableResult
    func addProvider(_ preset: ProviderPreset) -> APIProvider? {
        guard canAddProvider else { return nil }
        let names = Set(providers.map(\.name))
        var name = preset.name
        var suffix = 2
        while names.contains(name) {
            name = "\(preset.name) \(suffix)"
            suffix += 1
        }
        let provider = APIProvider(name: name, baseURL: preset.baseURL, model: preset.model, kind: preset)
        providers.append(provider)
        activeProviderID = provider.id
        return provider
    }

    /// 删除服务商及其钥匙串中的 Key；至少保留一个。
    func removeProvider(_ id: UUID) {
        guard providers.count > 1, let index = providers.firstIndex(where: { $0.id == id }) else { return }
        let removed = providers.remove(at: index)
        Keychain.write("", for: removed.keyAccount)
        keyCache[id] = nil
        if activeProviderID == id { activeProviderID = providers[min(index, providers.count - 1)].id }
    }

    /// 修改指定服务商（异步任务结束时用户可能已切换到别的服务商，因此按 ID 修改）。
    func updateProvider(_ id: UUID, _ change: (inout APIProvider) -> Void) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        change(&providers[index])
    }

    /// 改地址时，认得出的官方地址顺带更新接口类型；代理、中转等地址保留原来的类型。
    var baseURL: String {
        get { activeProvider.baseURL }
        set {
            activeProvider.baseURL = newValue
            let detected = ProviderPreset.detect(newValue)
            if detected != .custom { activeProvider.kind = detected }
        }
    }

    var model: String {
        get { activeProvider.model }
        set { activeProvider.model = newValue }
    }

    var thinking: Bool {
        get { activeProvider.thinking }
        set { activeProvider.thinking = newValue }
    }

    // MARK: - API Key

    /// 当前服务商是否可以发请求：有 Key，或者是不需要 Key 的本机 / 局域网服务（Ollama、LM Studio 等）。
    var hasAPIKey: Bool { activeProvider.hasKey || environmentKey != nil || OpenAIClient.isLocal(activeProvider.baseURL) }

    /// 钥匙串中保存的 Key（设置页显示的就是它）。
    func storedKey(for id: UUID) -> String {
        if let cached = keyCache[id] { return cached }
        guard let provider = providers.first(where: { $0.id == id }) else { return "" }
        let key = provider.hasKey ? (Keychain.read(provider.keyAccount) ?? "") : ""
        keyCache[id] = key
        return key
    }

    var apiKey: String {
        let key = storedKey(for: activeProviderID)
        return key.isEmpty ? (environmentKey ?? "") : key
    }

    func setAPIKey(_ key: String, for id: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider = providers.first(where: { $0.id == id }), trimmed != storedKey(for: id) else { return }
        keyCache[id] = trimmed
        Keychain.write(trimmed, for: provider.keyAccount)
        updateProvider(id) { $0.hasKey = !trimmed.isEmpty }
    }

    // MARK: - 模型

    var modelChoices: [String] {
        var seen = Set<String>()
        return (activeProvider.fetchedModels + [effectiveModel]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 模型菜单里的顺序。模型多到要搜索时（如 OpenRouter 的几百个），当前模型和最近用过的排在前面，
    /// 不输入也能直接选到；其余靠输入名称搜索。模型少时保持原来的顺序。
    var modelMenuChoices: [String] {
        let all = modelChoices
        guard all.count > PopMenu.filterLimit else { return all }
        let available = Set(all)
        var seen = Set<String>()
        let front = ([effectiveModel] + activeProvider.recentModels).filter { available.contains($0) && seen.insert($0).inserted }
        return front + all.filter { !seen.contains($0) }
    }

    /// 从模型菜单里选择模型，并记进最近使用。直接在输入框里改模型名不算（每输入一个字都会触发）。
    func chooseModel(_ name: String) {
        model = name
        var recent = activeProvider.recentModels.filter { $0 != name }
        recent.insert(name, at: 0)
        activeProvider.recentModels = Array(recent.prefix(6))
    }

    /// 实际请求使用的模型名，由用户填写或从接口返回的列表中选择。
    var effectiveModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前模型是否会收到页面截图。
    var sendsImages: Bool { sendPageImage && !noVisionModels.contains(effectiveModel) }

    func markNoVision(_ model: String) {
        if !model.isEmpty, !noVisionModels.contains(model) { noVisionModels.append(model) }
    }

    // MARK: - 上下文预算

    /// 接口没有报告、也没有手动设置时使用的上下文窗口。
    static let defaultContextWindow = 128_000
    static let contextWindowPresets = [32_000, 64_000, 128_000, 200_000, 256_000, 1_000_000]

    /// 接口为当前模型报告的上下文窗口。
    var detectedContextWindow: Int? { activeProvider.detectedContextWindows[effectiveModel] }

    /// 当前服务商与模型的上下文窗口（token）：手动设置 > 接口报告 > 默认值。
    var contextWindow: Int { activeProvider.contextWindow ?? detectedContextWindow ?? Self.defaultContextWindow }

    /// 一次请求（课件 + 历史 + 当前提问）最多使用的 token 数。
    var contextTokenBudget: Int { Int(Double(contextWindow) * contextBudgetPercent) }

    var connection: ConnectionConfig {
        let provider = activeProvider
        return ConnectionConfig(providerID: provider.id, kind: provider.kind, baseURL: provider.baseURL, apiKey: apiKey,
                                model: effectiveModel, thinking: provider.thinking, reasoningEffort: provider.reasoningEffort,
                                longCache: provider.longCache)
    }

    // MARK: - 学习档案

    static let profileLimit = 1_000
    static let courseNotesLimit = 4_000

    func courseNotes(for course: URL) -> String {
        courseNotes[course.standardizedFileURL.path] ?? ""
    }

    func setCourseNotes(_ text: String, for course: URL) {
        let key = course.standardizedFileURL.path
        let trimmed = String(text.prefix(Self.courseNotesLimit))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            courseNotes[key] = nil
        } else if courseNotes[key] != trimmed {
            courseNotes[key] = trimmed
        }
    }

    // MARK: - 自动检测到的模型限制
    //
    // 按服务商和模型分别记录（异步请求结束时用户可能已经切换了服务商，因此都按 ID 读写）。

    func quirks(_ providerID: UUID, _ model: String) -> ModelQuirks {
        providers.first { $0.id == providerID }?.modelQuirks[model] ?? ModelQuirks()
    }

    func updateQuirks(_ providerID: UUID, _ model: String, _ change: (inout ModelQuirks) -> Void) {
        guard !model.isEmpty else { return }
        updateProvider(providerID) { provider in
            var quirks = provider.modelQuirks[model] ?? ModelQuirks()
            change(&quirks)
            provider.modelQuirks[model] = quirks.isEmpty ? nil : quirks
        }
    }

    /// 某个服务商与模型的上下文窗口：手动设置 > 接口报告 > 默认值。
    func contextWindow(_ providerID: UUID, _ model: String) -> Int {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return Self.defaultContextWindow }
        return provider.contextWindow ?? provider.detectedContextWindows[model] ?? Self.defaultContextWindow
    }

    /// 接口报错说上下文超长并给出了真实上限：记下来。手动设置的值比它还大时说明设错了，改回自动。
    /// - Returns: 上下文窗口是否因此变小（变小了就不必再额外缩减预算）。
    @discardableResult
    func recordContextLimit(_ limit: Int, _ providerID: UUID, _ model: String) -> Bool {
        let before = contextWindow(providerID, model)
        guard limit >= 1024, limit < before else { return false }
        updateProvider(providerID) { provider in
            provider.detectedContextWindows[model] = limit
            if let manual = provider.contextWindow, manual > limit { provider.contextWindow = nil }
        }
        return true
    }

    /// 用接口返回的真实 prompt token 数校准本地估算。只在偏差超过 15% 时才调整，
    /// 校准值稳定下来后不再变化，避免课件摘取范围（也就是系统提示）跟着来回变动。
    func calibrate(_ providerID: UUID, _ model: String, actual: Int, estimate: Int) {
        guard actual > 0, estimate >= 2_000 else { return }
        let ratio = min(max(Double(actual) / Double(estimate), 0.5), 2.5)
        let current = quirks(providerID, model).tokenScale ?? 1
        guard abs(ratio - current) / current > 0.15 else { return }
        let updated = ((current + ratio) / 2 * 100).rounded() / 100
        updateQuirks(providerID, model) { $0.tokenScale = abs(updated - 1) < 0.05 ? nil : updated }
    }

    /// 设置页显示的当前模型自动检测结果。
    var detectionNotes: [String] {
        var notes: [String] = []
        if noVisionModels.contains(effectiveModel) { notes.append(tr("不支持图片", "No image input")) }
        let quirks = quirks(activeProviderID, effectiveModel)
        if let max = quirks.maxOutput {
            notes.append(max == 0 ? tr("不发送最大输出", "No max_tokens") : tr("最大输出 ", "Max output ") + TokenEstimate.label(max))
        }
        if !quirks.omit.isEmpty { notes.append(tr("不接受 ", "Rejects ") + quirks.omit.joined(separator: ", ")) }
        if let scale = quirks.tokenScale { notes.append(tr("token 估算 ×", "Token estimate ×") + String(format: "%.2f", scale)) }
        return notes
    }

    /// 清除当前模型的自动检测结果，下次请求重新检测。
    func resetDetection() {
        noVisionModels.removeAll { $0 == effectiveModel }
        updateProvider(activeProviderID) { $0.modelQuirks[effectiveModel] = nil }
    }
}
