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
    /// 课堂录音整理第 1 步：判断这节课讲了课程文件夹里的哪几份课件。
    case lectureDecks
    /// 第 2 步：参照课件纠正转写里识别错的词。
    case lectureTranscript
    /// 第 3 步：对照课件，找出老师讲了、课件上没有的内容和课程安排。
    case lectureSupplements

    var id: Self { self }

    /// 可以在设置里单独选模型（“讲解与提问”本身就是其他任务跟随的对象）。
    var isConfigurable: Bool { self != .chat }

    /// 这台 Mac 上用得到（课堂录音的任务要 macOS 26+）。
    var isAvailable: Bool {
        switch self {
        case .lectureDecks, .lectureTranscript, .lectureSupplements: LectureController.isSupported
        default: true
        }
    }

    /// 建议用多强的模型。
    enum Strength {
        case strong, medium, light

        var title: String {
            switch self {
            case .strong: tr("建议使用强模型", "Strong model recommended")
            case .medium: tr("中等模型即可", "Mid-range model is sufficient")
            case .light: tr("轻量模型即可", "Light model is sufficient")
            }
        }
    }

    var strength: Strength {
        switch self {
        case .chat, .autoExplain, .lectureSupplements: .strong
        case .record, .lectureDecks: .light
        case .roadmap, .lectureTranscript: .medium
        }
    }

    var title: String {
        switch self {
        case .chat: tr("讲解与提问", "Explain & ask")
        case .autoExplain: tr("翻页自动讲解", "Auto-explain on page turn")
        case .record: tr("整理学习记录", "Condense study record")
        case .roadmap: tr("生成路线图大纲", "Roadmap outline")
        case .lectureDecks: tr("判断相关课件", "Find related decks")
        case .lectureTranscript: tr("纠正转写", "Correct transcript")
        case .lectureSupplements: tr("补充要点与课程安排", "Lecture supplements")
        }
    }

    var summary: String {
        switch self {
        case .chat: tr("讲解当前页、提问，以及对选中文字和框选区域的操作。", "Page explanations, questions, and actions on selected text or boxed areas.")
        case .autoExplain: tr("跟随「讲解与提问」时共用同一缓存。", "Shares the cache with Explain & ask when following it.")
        case .record: tr("将较早的对话压缩为摘要。与讲解模型不同时，请求中不附带课件全文。", "Condenses earlier messages. With a model other than Explain & ask, the deck text is omitted.")
        case .roadmap: tr("读取整份课件，整理知识结构。每份课件仅生成一次。", "Reads the whole deck to map its structure. Generated once per deck.")
        case .lectureDecks: tr("课堂录音整理第 1 步：判断本节课涉及的课件。", "Lecture organizing, step 1: identifies the decks the lecture covered.")
        case .lectureTranscript: tr("第 2 步：参照课件修正转写中识别错误的术语、人名和数字。", "Step 2: corrects misrecognized terms, names and numbers using the slides.")
        case .lectureSupplements: tr("第 3 步：对照课件，找出课件以外的内容和课程安排。", "Step 3: finds content not on the slides and course arrangements.")
        }
    }

    /// 跟随「讲解与提问」时的思考强度上限：整理、判断这类后台任务不需要和讲解一样深的思考，封顶后快得多也省钱。
    /// 为空时完全跟随。单独选了模型的任务按用户的设置，不封顶。
    var effortCap: ReasoningEffort? {
        switch self {
        case .chat, .autoExplain, .roadmap: nil
        case .record, .lectureDecks, .lectureTranscript: .low
        case .lectureSupplements: .high
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .autoExplain: "sparkles"
        case .record: "doc.text"
        case .roadmap: "map"
        case .lectureDecks: "doc.text.magnifyingglass"
        case .lectureTranscript: "text.badge.checkmark"
        case .lectureSupplements: "text.badge.plus"
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
