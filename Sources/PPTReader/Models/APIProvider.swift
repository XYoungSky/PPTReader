import Foundation

/// 思考强度，对应 Kimi Code 的 `reasoning_effort`。`auto` 表示不发送，由模型使用默认值。
enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case auto, low, high, max

    var title: String {
        switch self {
        case .auto: tr("默认", "Default")
        case .low: tr("低", "Low")
        case .high: tr("高", "High")
        case .max: tr("最高", "Max")
        }
    }
}

/// 一个保存好的接口服务商。API Key 不在这里，单独存放在钥匙串中。
struct APIProvider: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var model: String
    var fetchedModels: [String]
    /// 深度思考（只对 DeepSeek 生效）。
    var thinking: Bool
    /// 思考强度（只对 Kimi Code 生效）。
    var reasoningEffort: ReasoningEffort
    /// 是否已保存 Key。单独记录，避免启动时就去读钥匙串。
    var hasKey: Bool
    /// 钥匙串中的条目名。从旧版本迁移来的配置沿用原来的 "api-key"。
    var keyAccount: String

    init(id: UUID = UUID(), name: String, baseURL: String, model: String = "", keyAccount: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        fetchedModels = []
        thinking = true
        reasoningEffort = .auto
        hasKey = false
        self.keyAccount = keyAccount ?? "api-key.\(id.uuidString)"
    }

    /// 逐个字段容错解码，以后增减字段时旧数据仍能读出。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        fetchedModels = try c.decodeIfPresent([String].self, forKey: .fetchedModels) ?? []
        thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? true
        reasoningEffort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)) ?? .auto
        hasKey = try c.decodeIfPresent(Bool.self, forKey: .hasKey) ?? false
        keyAccount = try c.decodeIfPresent(String.self, forKey: .keyAccount) ?? "api-key.\(id.uuidString)"
    }

    /// 列表中显示的副标题：主机名 · 模型。
    var summary: String {
        let host = URL(string: baseURL.contains("://") ? baseURL : "https://" + baseURL)?.host ?? baseURL
        return [host, model.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 添加服务商时可选的模板，只用来预填名称和地址，之后都可以修改。
enum ProviderPreset: CaseIterable, Identifiable {
    case deepSeek, kimiCode, kimiPlatform, custom

    var id: Self { self }

    var name: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .kimiCode: "Kimi Code"
        case .kimiPlatform: tr("Kimi 开放平台", "Kimi Platform")
        case .custom: tr("自定义", "Custom")
        }
    }

    /// 菜单中的说明。
    var menuTitle: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .kimiCode: tr("Kimi Code（会员订阅）", "Kimi Code (membership)")
        case .kimiPlatform: tr("Kimi 开放平台（按量付费）", "Kimi Platform (pay-as-you-go)")
        case .custom: tr("其他 OpenAI 兼容接口", "Other OpenAI-compatible API")
        }
    }

    var baseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .kimiCode: "https://api.kimi.com/coding/v1"
        case .kimiPlatform: "https://api.moonshot.cn/v1"
        case .custom: ""
        }
    }

    /// Kimi Code 的 `kimi-for-coding` 是官方长期保留的固定模型 ID，可以直接预填；其他服务商由接口返回或手动填写。
    var model: String {
        self == .kimiCode ? "kimi-for-coding" : ""
    }

    /// 根据地址推断模板，用于给旧版本迁移来的配置起名。
    static func detect(_ baseURL: String) -> ProviderPreset {
        if OpenAIClient.isDeepSeek(baseURL) { return .deepSeek }
        if OpenAIClient.isKimiCode(baseURL) { return .kimiCode }
        if baseURL.lowercased().contains("moonshot") { return .kimiPlatform }
        return .custom
    }
}
