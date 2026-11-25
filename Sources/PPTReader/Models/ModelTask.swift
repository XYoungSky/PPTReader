import Foundation

/// 要调用模型的各类任务。除“讲解与提问”外，每类都可以单独选服务商、模型和思考参数，默认跟随“讲解与提问”。
/// 原始值用于保存设置和统计，不要修改。
enum ModelTask: String, Codable, CaseIterable, Identifiable, Sendable {
    /// ⌘E、自由提问、选中和框选的操作。用的就是正在使用的服务商和 AI 面板里选的模型。
    case chat
    /// 翻页后自动讲解这一页。
    case autoExplain
    /// 上下文超出上限时，把较早的对话整理成学习记录。
    case record
    /// 读整份课件，生成学习路线图的大纲。
    case roadmap

    var id: Self { self }

    /// 可以在设置里单独选模型（“讲解与提问”本身就是其他任务跟随的对象）。
    var isConfigurable: Bool { self != .chat }

    /// 建议用多强的模型。
    enum Strength {
        case strong, medium, light

        var title: String {
            switch self {
            case .strong: tr("建议用强模型", "Strong model suggested")
            case .medium: tr("中等模型即可", "A mid-range model is enough")
            case .light: tr("轻量模型即可", "A light model is enough")
            }
        }
    }

    var strength: Strength {
        switch self {
        case .chat, .autoExplain: .strong
        case .record: .light
        case .roadmap: .medium
        }
    }

    var title: String {
        switch self {
        case .chat: tr("讲解与提问", "Explain & ask")
        case .autoExplain: tr("翻页自动讲解", "Auto-explain on page turn")
        case .record: tr("整理学习记录", "Condense study record")
        case .roadmap: tr("生成路线图大纲", "Roadmap outline")
        }
    }

    var summary: String {
        switch self {
        case .chat: tr("讲解本页、自由提问、选中和框选的操作", "Explaining pages, questions, and actions on selections and boxes")
        case .autoExplain: tr("跟随时和讲解共用缓存", "Shares the cache with Explain & ask when following it")
        case .record: tr("只做摘要；和讲解用的模型不同时，请求里不带课件全文", "Only summarizes; with a different model than Explain & ask, the deck text is left out")
        case .roadmap: tr("读整份课件整理出结构；每份课件只生成一次，之后读缓存", "Reads the whole deck to map its structure; generated once per deck, then cached")
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .autoExplain: "sparkles"
        case .record: "doc.text"
        case .roadmap: "map"
        }
    }
}

/// 某个任务选定的服务商和模型。思考参数为空时跟随那个服务商的设置。
struct ModelRef: Codable, Equatable, Sendable {
    var providerID: UUID
    var model: String
    /// 深度思考（DeepSeek 类型）。
    var thinking: Bool?
    /// 思考强度（Kimi Code、OpenRouter 类型）。
    var reasoningEffort: ReasoningEffort?

    init(providerID: UUID, model: String, thinking: Bool? = nil, reasoningEffort: ReasoningEffort? = nil) {
        self.providerID = providerID
        self.model = model
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try c.decode(UUID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        thinking = try? c.decodeIfPresent(Bool.self, forKey: .thinking)
        reasoningEffort = try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
    }
}
