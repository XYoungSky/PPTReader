import Foundation

/// 一次性模型调用：不进聊天历史，只要模型最后输出的文字（JSON 还是 Markdown 由提示词约定）。
/// 学习记录整理用它；之后的路线图大纲、录音整理也用它，要分块的由调用方分成几次调用。
///
/// 连接配置由调用方给出，这里不读“当前服务商”，以后按任务配置模型时直接传入那个任务的配置。
/// 和聊天请求不同，这里不做出错后调整参数重试：失败就交给调用方，下次需要时再调用。
struct LLMTask: Sendable {
    let config: ConnectionConfig
    /// 组装好的请求体。
    let body: Data

    struct Output: Equatable, Sendable {
        /// 去掉首尾空白的输出文字，不会为空。
        var text: String
        var usage: TokenUsage?
        /// 达到 max_tokens 被截断，输出可能不完整（JSON 可能解析不了）。
        var truncated: Bool
    }

    enum Failure: LocalizedError, Equatable {
        /// 请求成功，但模型没有输出文字（只有思考内容或空白）。
        case emptyOutput

        var errorDescription: String? {
            tr("模型没有返回内容", "The model returned no content")
        }
    }

    /// 没有特别指定时 max_tokens 最多发这么多；够写一份学习记录，又不会在按 max_tokens 计算限额的服务上占用太多。
    static let defaultMaxOutput = 8_192

    /// 按这个模型已知的限制组装请求：max_tokens 取 `maxOutput` 和模型上限中较小的那个（已知不接受时不发送），
    /// 不再发送模型拒绝过的可选参数。
    /// - Parameters:
    ///   - quirks: `settings.quirks(config.providerID, config.model)`。
    ///   - cacheKey: 和聊天请求用同一个键，服务商才会把它们路由到同一份缓存。
    init(config: ConnectionConfig, messages: [[String: Any]], quirks: ModelQuirks,
         maxOutput: Int = LLMTask.defaultMaxOutput, cacheKey: String?) throws {
        let options = OpenAIClient.RequestOptions(maxTokens: Self.maxTokens(quirks: quirks, limit: maxOutput),
                                                  omit: Set(quirks.omit), cacheKey: cacheKey)
        self.config = config
        body = try OpenAIClient.makeBody(config: config, messages: messages, options: options).data
    }

    static func maxTokens(quirks: ModelQuirks, limit: Int) -> Int? {
        quirks.maxOutput == 0 ? nil : min(limit, quirks.maxOutput ?? limit)
    }

    /// 发送请求，收集输出，并把用量计入统计（只计 token，不算提问次数）。
    /// - Parameters:
    ///   - deck: 统计归到哪份课件（`ChatThread.sourcePath`）。
    ///   - task: 统计归到哪类任务。
    @MainActor
    func run(stats: StatsStore, deck: String, task: ModelTask) async throws -> Output {
        try await run(events: OpenAIClient.stream(config: config, body: body)) { usage in
            stats.recordReply(deck: deck, page: nil, model: config.model, kind: .housekeeping, task: task, usage: usage, at: Date())
        }
    }

    /// 收集输出。请求失败、输出为空时也会调用 `recordUsage`（已经消耗的 token 照样计入）；被取消时不调用，并抛出 `CancellationError`。
    @MainActor
    func run(events: AsyncThrowingStream<StreamEvent, Error>, recordUsage: (TokenUsage?) -> Void) async throws -> Output {
        var text = ""
        var usage: TokenUsage?
        var truncated = false
        var failure: Error?
        do {
            for try await event in events {
                switch event {
                case .content(let chunk): text += chunk
                case .usage(let value): usage = value
                case .finish(let reason): truncated = reason == "length"
                case .reasoning, .retrying: break
                }
            }
        } catch {
            failure = error
        }
        if Task.isCancelled { throw CancellationError() }
        recordUsage(usage)
        if let failure { throw failure }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyOutput }
        return Output(text: trimmed, usage: usage, truncated: truncated)
    }
}
