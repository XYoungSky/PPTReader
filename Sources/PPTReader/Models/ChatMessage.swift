import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct TokenUsage: Codable, Equatable {
    var prompt: Int
    var completion: Int
    var cacheHit: Int?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: MessageRole
    /// 用户消息：界面上显示的文字；助手消息：Markdown 回答。
    var content: String
    /// 用户消息实际发送给模型的指令（为空时使用 content）。
    var prompt: String?
    var reasoning: String?
    /// 发送这条消息时正在看的页码（从 1 开始）。
    var page: Int?
    var selection: String?
    var isAuto = false
    /// 一键讲解/自动讲解的目标页，用于判断某页是否已讲解过。
    var explainsPage: Int?
    var error: String?
    var stopped = false
    var usage: TokenUsage?
    /// 生成这条回答的模型（1.2 起记录）。
    var model: String?
    var createdAt = Date()

    var instruction: String { prompt ?? content }
}

struct ChatThread: Codable {
    var sourcePath: String
    var messages: [ChatMessage] = []
    var lastPage: Int?
    var updatedAt = Date()
}
