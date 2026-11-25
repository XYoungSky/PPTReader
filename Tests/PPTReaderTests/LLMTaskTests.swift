import Foundation
import Testing
@testable import PPTReader

/// 一次性模型调用：请求体按模型限制组装，输出收集和统计的规则与迁移前的学习记录整理一致。
@Suite("一次性调用")
@MainActor
struct LLMTaskTests {
    private let messages: [[String: Any]] = [["role": "system", "content": "s"], ["role": "user", "content": "u"]]

    private func config(_ kind: ProviderPreset = .deepSeek) -> ConnectionConfig {
        ConnectionConfig(providerID: UUID(), kind: kind, baseURL: kind.baseURL, apiKey: "k", model: "m", thinking: true)
    }

    private func json(_ task: LLMTask) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: task.body) as? [String: Any])
    }

    private func events(_ list: [StreamEvent], error: Error? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in list { continuation.yield(event) }
            continuation.finish(throwing: error)
        }
    }

    // MARK: - 请求体

    @Test("max_tokens 取上限和模型已知上限中较小的，已知不接受时不发送",
          arguments: [(nil, 8_192), (4_096, 4_096), (100_000, 8_192), (0, nil)] as [(Int?, Int?)])
    func maxTokens(_ maxOutput: Int?, _ expected: Int?) throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(maxOutput: maxOutput), cacheKey: nil)
        #expect(try json(task)["max_tokens"] as? Int == expected)
    }

    @Test("可以指定更大的上限")
    func customLimit() throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), maxOutput: 16_000, cacheKey: nil)
        #expect(try json(task)["max_tokens"] as? Int == 16_000)
    }

    @Test("不发送模型拒绝过的参数")
    func omit() throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(omit: ["stream_options", "thinking"]), cacheKey: nil)
        let body = try json(task)
        #expect(body["stream_options"] == nil && body["thinking"] == nil)
        #expect(body["stream"] as? Bool == true)
    }

    @Test("消息原样发送，缓存键和聊天请求一样带上")
    func messagesAndCacheKey() throws {
        let task = try LLMTask(config: config(.openRouter), messages: messages, quirks: ModelQuirks(), cacheKey: "pptreader-abc")
        let body = try json(task)
        #expect(body["prompt_cache_key"] as? String == "pptreader-abc")
        #expect(body["model"] as? String == "m")
        let sent = try #require(body["messages"] as? [[String: String]])
        #expect(sent == [["role": "system", "content": "s"], ["role": "user", "content": "u"]])
    }

    // MARK: - 收集输出

    @Test("拼接输出、去掉首尾空白，用量计入一次；思考内容和重试提示不算输出")
    func collects() async throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), cacheKey: nil)
        let usage = TokenUsage(prompt: 1_000, completion: 200, cacheHit: 900)
        var recorded: [TokenUsage?] = []
        let output = try await task.run(events: events([
            .retrying(attempt: 1, of: 3), .reasoning("想一想"), .content("\n  学习"), .content("记录 \n"),
            .usage(usage), .finish("stop"),
        ])) { recorded.append($0) }
        #expect(output == LLMTask.Output(text: "学习记录", usage: usage, truncated: false))
        #expect(recorded == [usage])
    }

    @Test("达到长度上限时标记截断，但仍返回已有的输出")
    func truncated() async throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), cacheKey: nil)
        let output = try await task.run(events: events([.content("{\"a\":"), .finish("length")])) { _ in }
        #expect(output.truncated)
        #expect(output.text == "{\"a\":")
    }

    @Test("请求失败时抛出原来的错误，已消耗的用量照样计入")
    func failure() async throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), cacheKey: nil)
        var recorded: [TokenUsage?] = []
        await #expect(throws: URLError.self) {
            _ = try await task.run(events: events([.content("半截"), .usage(TokenUsage(prompt: 5, completion: 1))],
                                                  error: URLError(.networkConnectionLost))) { recorded.append($0) }
        }
        #expect(recorded == [TokenUsage(prompt: 5, completion: 1)])
    }

    @Test("只有思考内容或空白时算失败，用量照样计入")
    func emptyOutput() async throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), cacheKey: nil)
        var recorded: [TokenUsage?] = []
        await #expect(throws: LLMTask.Failure.emptyOutput) {
            _ = try await task.run(events: events([.reasoning("想了很久"), .content(" \n ")])) { recorded.append($0) }
        }
        #expect(recorded == [nil])
    }

    @Test("被取消时不计入统计")
    func cancelled() async throws {
        let task = try LLMTask(config: config(), messages: messages, quirks: ModelQuirks(), cacheKey: nil)
        // 不结束的流：只有取消能让它停下
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        continuation.yield(.content("还没写完"))
        let recorded = Counter()
        let running = Task { try await task.run(events: stream) { _ in recorded.value += 1 } }
        running.cancel()
        let result = await running.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(recorded.value == 0)
        continuation.finish()
    }

    // MARK: - 学习记录整理的请求

    @Test("整理请求和聊天请求的系统提示相同，课件部分能共用缓存")
    func recordSharesPrefix() throws {
        let context = PromptBuilder.Context(title: "Deck", pageCount: 3, currentPage: 2, text: nil, latestText: nil,
                                            charLimit: 50_000, historyLimit: 20, tokenBudget: 64_000, pageImageJPEG: nil)
        var question = PromptBuilder.userMessage(for: .question("为什么？", selection: nil), page: 2)
        question.sentText = PromptBuilder.composeText(question, context: context)
        let answer = ChatMessage(role: .assistant, content: "因为……")
        let next = PromptBuilder.userMessage(for: .question("那下一页呢？", selection: nil), page: 3)
        let chat = PromptBuilder.requestMessages(history: [question, answer, next], context: context)
        let record = PromptBuilder.recordRequest(past: [question, answer], context: context)
        let chatSystem = try #require(chat.messages.first?["content"] as? String)
        #expect(record.messages.first?["role"] as? String == "system")
        #expect(record.messages.first?["content"] as? String == chatSystem)
        // 整理指令放在最后，作为一条用户消息
        #expect(record.messages.last?["role"] as? String == "user")
        #expect(record.messages.count == 4)
    }
}

@MainActor
private final class Counter {
    var value = 0
}
