import Foundation
import Observation

struct ConnectionConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    /// 深度思考（仅对 DeepSeek 发送 `thinking` 参数，其他服务不认识这个参数）。
    var thinking: Bool
    /// 思考强度（仅对 Kimi Code 发送 `reasoning_effort` 参数）。
    var reasoningEffort: ReasoningEffort = .auto
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
        static let contextLimit = "context.charLimit"
        static let historyLimit = "context.historyLimit"
        static let sendPageImage = "context.pageImage"
        static let noVisionModels = "context.noVisionModels"
        static let chatFontSize = "ui.chatFontSize"
        static let chatSerif = "ui.chatSerif"
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
        }
    }
    /// 放进上下文的课件文字上限（字符数）。
    var contextCharLimit: Int { didSet { defaults.set(contextCharLimit, forKey: Key.contextLimit) } }
    /// 每次请求携带的历史消息条数。
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Key.historyLimit) } }
    /// 随提问附上当前页截图，让模型看到图片与公式。
    var sendPageImage: Bool { didSet { defaults.set(sendPageImage, forKey: Key.sendPageImage) } }
    /// 实际请求中拒绝了图片的模型，之后不再给它们发送截图。
    var noVisionModels: [String] { didSet { defaults.set(noVisionModels, forKey: Key.noVisionModels) } }
    /// 讲解正文字号（pt）。
    var chatFontSize: Double { didSet { defaults.set(chatFontSize, forKey: Key.chatFontSize) } }
    /// 讲解正文使用衬线字体。
    var chatSerif: Bool { didSet { defaults.set(chatSerif, forKey: Key.chatSerif) } }

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
            examples: ExplanationStyle.Examples(rawValue: defaults.string(forKey: Key.explanationExamples) ?? "") ?? .necessary
        )
        contextCharLimit = defaults.object(forKey: Key.contextLimit) as? Int ?? 400_000
        historyLimit = defaults.object(forKey: Key.historyLimit) as? Int ?? 16
        sendPageImage = defaults.object(forKey: Key.sendPageImage) as? Bool ?? true
        noVisionModels = (defaults.stringArray(forKey: Key.noVisionModels) ?? []).filter { !$0.isEmpty }
        chatFontSize = defaults.object(forKey: Key.chatFontSize) as? Double ?? 15
        chatSerif = defaults.bool(forKey: Key.chatSerif)
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
        let provider = APIProvider(name: name, baseURL: preset.baseURL, model: preset.model)
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

    var baseURL: String {
        get { activeProvider.baseURL }
        set { activeProvider.baseURL = newValue }
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

    /// 当前服务商是否有可用的 Key。
    var hasAPIKey: Bool { activeProvider.hasKey || environmentKey != nil }

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

    /// 实际请求使用的模型名，由用户填写或从接口返回的列表中选择。
    var effectiveModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前模型是否会收到页面截图。
    var sendsImages: Bool { sendPageImage && !noVisionModels.contains(effectiveModel) }

    func markNoVision(_ model: String) {
        if !model.isEmpty, !noVisionModels.contains(model) { noVisionModels.append(model) }
    }

    var connection: ConnectionConfig {
        let provider = activeProvider
        return ConnectionConfig(baseURL: provider.baseURL, apiKey: apiKey, model: effectiveModel,
                                thinking: provider.thinking, reasoningEffort: provider.reasoningEffort)
    }
}
