import Foundation

/// 思考强度，对应 Kimi Code 的 `reasoning_effort`、OpenRouter 的 `reasoning.effort`。`auto` 表示不发送，由模型使用默认值。
/// 各服务商支持的取值不同，见 `ProviderPreset.reasoningEfforts`。
enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case auto, none, minimal, low, medium, high, xhigh, max

    var title: String {
        switch self {
        case .auto: tr("默认", "Default")
        case .none: tr("关闭", "Off")
        case .minimal: tr("最少", "Minimal")
        case .low: tr("低", "Low")
        case .medium: tr("中", "Medium")
        case .high: tr("高", "High")
        case .xhigh: tr("很高", "Extra high")
        case .max: tr("最高", "Max")
        }
    }

    /// 由低到高的次序；“默认”交给模型决定，没有次序。
    var rank: Int? {
        switch self {
        case .auto: nil
        case .none: 0
        case .minimal: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .xhigh: 5
        case .max: 6
        }
    }

    /// 不超过 `cap` 的强度：原来更高或是“默认”（推理模型默认往往很高）时取 `cap`，
    /// 再落到服务商支持的、不高于它的最高一档（都更高时取支持的最低一档）。服务商不支持调节时原样返回。
    static func capped(_ effort: ReasoningEffort, at cap: ReasoningEffort, supported: [ReasoningEffort]) -> ReasoningEffort {
        let options = supported.filter { $0.rank != nil }
        guard !options.isEmpty, let capRank = cap.rank else { return effort }
        let target = effort.rank.map { min($0, capRank) } ?? capRank
        if let best = options.filter({ $0.rank! <= target }).max(by: { $0.rank! < $1.rank! }) { return best }
        return options.min(by: { $0.rank! < $1.rank! }) ?? effort
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
    /// 思考强度（只对 Kimi Code、OpenRouter 生效）。
    var reasoningEffort: ReasoningEffort
    /// 是否已保存 Key。单独记录，避免启动时就去读钥匙串。
    var hasKey: Bool
    /// 钥匙串中的条目名。从旧版本迁移来的配置沿用原来的 "api-key"。
    var keyAccount: String
    /// 手动设置的上下文窗口（token）；为空时使用接口报告的值，接口没有报告时按默认值计算。
    var contextWindow: Int?
    /// 测试连接时接口报告的各模型上下文窗口（token）。
    var detectedContextWindows: [String: Int]
    /// 接口类型，决定发送哪些专有参数（深度思考、思考强度）。按模板创建时确定，
    /// 不再根据地址猜测，经代理或中转访问时也能用上对应的参数。
    var kind: ProviderPreset
    /// 请求中自动检测到的各模型限制（最大输出、不接受的参数、token 估算校准）。
    var modelQuirks: [String: ModelQuirks]
    /// 缓存保留 1 小时（只对 Kimi 开放平台生效，默认 5 分钟）。
    var longCache: Bool
    /// 最近从模型菜单里选过的模型（新的在前）。模型很多时（如 OpenRouter）排在菜单前面。
    var recentModels: [String]
    /// 测试连接时模型列表里报告的元数据（能否识图、最大输出、价格），目前只有 OpenRouter 提供。
    var modelInfo: [String: ModelInfo]
    /// 只用满足隐私要求的上游（只对 OpenRouter 生效）。
    var privacy: ProviderPrivacy

    init(id: UUID = UUID(), name: String, baseURL: String, model: String = "", kind: ProviderPreset? = nil, keyAccount: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind ?? ProviderPreset.detect(baseURL)
        modelQuirks = [:]
        longCache = true
        recentModels = []
        modelInfo = [:]
        privacy = .any
        self.model = model
        fetchedModels = []
        thinking = true
        reasoningEffort = .auto
        hasKey = false
        self.keyAccount = keyAccount ?? "api-key.\(id.uuidString)"
        contextWindow = nil
        detectedContextWindows = [:]
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
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        detectedContextWindows = (try? c.decodeIfPresent([String: Int].self, forKey: .detectedContextWindows)) ?? [:]
        // 1.6 之前没有保存类型，按地址推断一次
        kind = (try? c.decodeIfPresent(ProviderPreset.self, forKey: .kind)) ?? ProviderPreset.detect(baseURL)
        modelQuirks = (try? c.decodeIfPresent([String: ModelQuirks].self, forKey: .modelQuirks)) ?? [:]
        longCache = (try? c.decodeIfPresent(Bool.self, forKey: .longCache)) ?? true
        recentModels = (try? c.decodeIfPresent([String].self, forKey: .recentModels)) ?? []
        modelInfo = (try? c.decodeIfPresent([String: ModelInfo].self, forKey: .modelInfo)) ?? [:]
        privacy = (try? c.decodeIfPresent(ProviderPrivacy.self, forKey: .privacy)) ?? .any
    }

    /// 列表中显示的副标题：主机名 · 模型。
    var summary: String {
        let host = URL(string: baseURL.contains("://") ? baseURL : "https://" + baseURL)?.host ?? baseURL
        return [host, model.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 模型列表里报告的模型元数据（OpenRouter 的 GET /models）。没报告的项为空。
struct ModelInfo: Codable, Equatable, Sendable {
    /// `architecture.input_modalities` 里有没有 image。
    var acceptsImages: Bool?
    /// `top_provider.max_completion_tokens`：max_tokens 的上限。
    var maxOutput: Int?
    var price: ModelPrice?
}

/// 模型单价（美元 / token）。
struct ModelPrice: Codable, Equatable, Sendable {
    var prompt: Double
    var completion: Double
    /// 缓存命中部分的输入单价。
    var cacheRead: Double?

    /// 模型菜单里显示的价格：每百万 token 的输入 / 输出价格，例如“$3 / $15”。
    var label: String {
        if prompt == 0 && completion == 0 { return tr("免费", "Free") }
        return "$" + Self.perMillion(prompt) + " / $" + Self.perMillion(completion)
    }

    static func perMillion(_ perToken: Double) -> String {
        let value = perToken * 1_000_000
        if value > 0 && value < 0.01 { return "<0.01" }
        var text = String(format: "%.2f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// OpenRouter 的隐私路由：限制越多，可用的上游越少。
enum ProviderPrivacy: String, Codable, CaseIterable, Sendable {
    /// 不限制。
    case any
    /// 只用不收集数据的上游（`provider.data_collection: "deny"`）。
    case noCollection
    /// 只用零数据保留的端点（`provider.zdr: true`）。
    case zeroRetention

    var title: String {
        switch self {
        case .any: tr("不限", "Any")
        case .noCollection: tr("不收集数据", "No data collection")
        case .zeroRetention: tr("零数据保留", "Zero retention")
        }
    }
}

/// 某个模型在实际请求中暴露出来的限制，出错后自动记下，避免每次都先失败一次。
struct ModelQuirks: Codable, Equatable, Sendable {
    /// 接口接受的最大输出 token 数；0 表示不发送 `max_tokens`。
    var maxOutput: Int?
    /// 接口不接受、之后不再发送的可选参数（如 stream_options、thinking）。
    var omit: [String] = []
    /// 实际 prompt token 数与本地估算之比，用于修正估算。
    var tokenScale: Double?

    var isEmpty: Bool { maxOutput == nil && omit.isEmpty && tokenScale == nil }
}

/// 服务商模板，同时也是保存下来的接口类型：创建时预填名称和地址，并决定发送哪些专有参数。
enum ProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepSeek, kimiCode, kimiPlatform, openRouter, custom

    var id: Self { self }

    /// 支持 DeepSeek 的 `thinking` 开关。
    var hasThinkingToggle: Bool { self == .deepSeek }

    /// 可以调整思考强度：Kimi Code 发 `reasoning_effort`，OpenRouter 发 `reasoning: {effort}`。
    var hasReasoningEffort: Bool { !reasoningEfforts.isEmpty }

    /// 设置里可选的思考强度（含“默认”）。只发送这里列出的值，换了接口类型也不会发出对方不认识的取值。
    var reasoningEfforts: [ReasoningEffort] {
        switch self {
        case .kimiCode: [.auto, .low, .high, .max]
        // OpenRouter 文档列出的取值还有 minimal，只有少数模型支持，这里不提供
        case .openRouter: [.auto, .none, .low, .medium, .high, .xhigh, .max]
        default: []
        }
    }

    /// 支持用 `prompt_cache_options` 设置缓存保留时长（Kimi 开放平台：5m / 1h）。
    var hasCacheTTL: Bool { self == .kimiPlatform }

    /// 支持按隐私要求路由（OpenRouter 的 `provider.data_collection` / `provider.zdr`）。
    var hasPrivacyRouting: Bool { self == .openRouter }

    var name: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .kimiCode: "Kimi Code"
        case .kimiPlatform: tr("Kimi 开放平台", "Kimi Platform")
        case .openRouter: "OpenRouter"
        case .custom: tr("自定义", "Custom")
        }
    }

    /// 菜单中的说明。
    var menuTitle: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .kimiCode: tr("Kimi Code（会员订阅）", "Kimi Code (membership)")
        case .kimiPlatform: tr("Kimi 开放平台（按量付费）", "Kimi Platform (pay-as-you-go)")
        case .openRouter: tr("OpenRouter（统一接入多家模型）", "OpenRouter (many providers, one key)")
        case .custom: tr("其他 OpenAI 兼容接口", "Other OpenAI-compatible API")
        }
    }

    var baseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .kimiCode: "https://api.kimi.com/coding/v1"
        case .kimiPlatform: "https://api.moonshot.cn/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
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
        if OpenAIClient.isOpenRouter(baseURL) { return .openRouter }
        return .custom
    }
}
