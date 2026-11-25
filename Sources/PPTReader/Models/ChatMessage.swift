import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct TokenUsage: Codable, Equatable {
    var prompt: Int
    var completion: Int
    var cacheHit: Int?
    /// 这次写入缓存的输入 token（Kimi 等单独报告写入的服务商才有）。
    var cacheWrite: Int?
    /// 服务商报告的实际花费（OpenRouter 的 usage.cost，单位是 credits，按美元计价）。
    var cost: Double?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: MessageRole
    /// 用户消息：界面上显示的文字；助手消息：Markdown 回答。
    var content: String
    /// 用户消息实际发送给模型的指令（为空时使用 content）。
    var prompt: String?
    /// 用户消息发出时发给模型的完整文字（1.6 起保存），之后原样用作历史，让前缀缓存能够命中。
    var sentText: String?
    var reasoning: String?
    /// 发送这条消息时正在看的页码（从 1 开始）。
    var page: Int?
    var selection: String?
    /// 框选的区域（1.8 起）：截图在请求时按它重新渲染，selection 里是框内的文字。
    var region: PageRegion?
    var isAuto = false
    /// 一键讲解/自动讲解的目标页，用于判断某页是否已讲解过。
    var explainsPage: Int?
    var error: String?
    var stopped = false
    /// 回答达到长度上限被截断（1.6 起记录；可选类型以兼容旧记录）。
    var truncated: Bool?
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
    /// 较早的对话整理成的学习记录（1.6 起）。
    var record: StudyRecord?
}

/// 对话超出预算时，把要丢掉的较早对话整理成的学习记录。放在系统提示末尾，代替被丢掉的消息，
/// 让模型记得讲过什么、学生在哪里卡住、用过哪些例子（参考 Codex、Claude Code 的上下文压缩）。
struct StudyRecord: Codable, Equatable {
    var text: String
    /// 整理进记录的最后一条消息；之后的消息照常作为历史发送。
    var throughID: UUID
    /// 记录累计覆盖的消息条数，只用于显示。
    var messageCount: Int
    var createdAt = Date()
}
