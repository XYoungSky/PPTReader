import Foundation
import Observation

struct ConnectionConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    /// 深度思考（仅对 DeepSeek 发送 `thinking` 参数，其他服务不认识这个参数）。
    var thinking: Bool
}

@MainActor
@Observable
final class AppSettings {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-flash"
    static let suggestedModels = ["deepseek-flash", "deepseek-v4-pro"]
    /// DeepSeek 文档中已不再出现的旧模型名，自动迁移到 deepseek-flash。
    private static let retiredModels: Set<String> = ["deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"]

    private enum Key {
        static let baseURL = "api.baseURL"
        static let model = "api.model"
        static let thinking = "api.thinking"
        static let hasKey = "api.hasKey"
        static let autoExplain = "explain.auto"
        static let autoExplainDelay = "explain.autoDelay"
        static let contextLimit = "context.charLimit"
        static let historyLimit = "context.historyLimit"
        static let sendPageImage = "context.pageImage"
        static let noVisionModels = "context.noVisionModels"
        static let fetchedModels = "api.fetchedModels"
        static let chatFontSize = "ui.chatFontSize"
        static let chatSerif = "ui.chatSerif"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var baseURL: String { didSet { defaults.set(baseURL, forKey: Key.baseURL) } }
    var model: String { didSet { defaults.set(model, forKey: Key.model) } }
    var thinking: Bool { didSet { defaults.set(thinking, forKey: Key.thinking) } }
    var autoExplain: Bool { didSet { defaults.set(autoExplain, forKey: Key.autoExplain) } }
    var autoExplainDelay: Double { didSet { defaults.set(autoExplainDelay, forKey: Key.autoExplainDelay) } }
    /// 放进上下文的课件文字上限（字符数）。
    var contextCharLimit: Int { didSet { defaults.set(contextCharLimit, forKey: Key.contextLimit) } }
    /// 每次请求携带的历史消息条数。
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Key.historyLimit) } }
    /// 随提问附上当前页截图，让模型看到图片与公式。
    var sendPageImage: Bool { didSet { defaults.set(sendPageImage, forKey: Key.sendPageImage) } }
    /// 实际请求中拒绝了图片的模型，之后不再给它们发送截图。
    var noVisionModels: [String] { didSet { defaults.set(noVisionModels, forKey: Key.noVisionModels) } }
    var fetchedModels: [String] { didSet { defaults.set(fetchedModels, forKey: Key.fetchedModels) } }
    /// 讲解正文字号（pt）。
    var chatFontSize: Double { didSet { defaults.set(chatFontSize, forKey: Key.chatFontSize) } }
    /// 讲解正文使用衬线字体。
    var chatSerif: Bool { didSet { defaults.set(chatSerif, forKey: Key.chatSerif) } }

    /// 是否已保存 Key。单独记录这个标记，避免启动时就去读钥匙串。
    private(set) var hasAPIKey: Bool
    @ObservationIgnored private var cachedKey: String?

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL
        let storedModel = (defaults.string(forKey: Key.model) ?? "").trimmingCharacters(in: .whitespaces)
        // 空值或旧模型名迁移到 deepseek-flash，并写回设置
        let resolvedModel = storedModel.isEmpty || Self.retiredModels.contains(storedModel) ? Self.defaultModel : storedModel
        if resolvedModel != storedModel { defaults.set(resolvedModel, forKey: Key.model) }
        model = resolvedModel
        thinking = defaults.object(forKey: Key.thinking) as? Bool ?? true
        autoExplain = defaults.bool(forKey: Key.autoExplain)
        autoExplainDelay = defaults.object(forKey: Key.autoExplainDelay) as? Double ?? 1.5
        contextCharLimit = defaults.object(forKey: Key.contextLimit) as? Int ?? 400_000
        historyLimit = defaults.object(forKey: Key.historyLimit) as? Int ?? 16
        sendPageImage = defaults.object(forKey: Key.sendPageImage) as? Bool ?? true
        noVisionModels = (defaults.stringArray(forKey: Key.noVisionModels) ?? []).filter { !$0.isEmpty }
        fetchedModels = (defaults.stringArray(forKey: Key.fetchedModels) ?? []).filter { !Self.retiredModels.contains($0) }
        chatFontSize = defaults.object(forKey: Key.chatFontSize) as? Double ?? 15
        chatSerif = defaults.bool(forKey: Key.chatSerif)
        hasAPIKey = defaults.bool(forKey: Key.hasKey)
        // 也可以通过环境变量提供 Key（便于命令行启动和调试）
        if let key = ProcessInfo.processInfo.environment["PPTREADER_API_KEY"], !key.isEmpty {
            cachedKey = key
            hasAPIKey = true
        }
    }

    var apiKey: String {
        if let cachedKey { return cachedKey }
        let key = hasAPIKey ? (Keychain.read("api-key") ?? "") : ""
        cachedKey = key
        return key
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != cachedKey else { return }
        cachedKey = trimmed
        Keychain.write(trimmed, for: "api-key")
        hasAPIKey = !trimmed.isEmpty
        defaults.set(hasAPIKey, forKey: Key.hasKey)
    }

    var modelChoices: [String] {
        var seen = Set<String>()
        return (Self.suggestedModels + fetchedModels + [model]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 实际请求使用的模型名（输入框被清空时回退到默认模型）。
    var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultModel : trimmed
    }

    /// 当前模型是否会收到页面截图。
    var sendsImages: Bool { sendPageImage && !noVisionModels.contains(effectiveModel) }

    func markNoVision(_ model: String) {
        if !model.isEmpty, !noVisionModels.contains(model) { noVisionModels.append(model) }
    }

    var connection: ConnectionConfig {
        ConnectionConfig(baseURL: baseURL, apiKey: apiKey, model: effectiveModel, thinking: thinking)
    }
}
