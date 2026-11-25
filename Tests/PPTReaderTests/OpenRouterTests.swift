import Foundation
import Testing
@testable import PPTReader

/// OpenRouter 第二阶段：Claude 的缓存断点、隐私路由、模型元数据、实际花费。
@Suite("OpenRouter")
struct OpenRouterTests {
    private func config(_ kind: ProviderPreset = .openRouter, model: String = "anthropic/claude-sonnet-5.5",
                        privacy: ProviderPrivacy = .any) -> ConnectionConfig {
        ConnectionConfig(providerID: UUID(), kind: kind, baseURL: kind.baseURL, apiKey: "k", model: model,
                         thinking: true, privacy: privacy)
    }

    private let chat: [[String: Any]] = [
        ["role": "system", "content": "课件"],
        ["role": "user", "content": "第一问"],
        ["role": "assistant", "content": "第一答"],
        ["role": "user", "content": "第二问"],
    ]

    private func body(_ config: ConnectionConfig, _ messages: [[String: Any]], omit: Set<String> = [])
        throws -> (json: [String: Any], optional: [String]) {
        let (data, optional) = try OpenAIClient.makeBody(config: config, messages: messages,
                                                         options: .init(omit: omit))
        return (try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), optional)
    }

    private func sentMessages(_ json: [String: Any]) throws -> [[String: Any]] {
        try #require(json["messages"] as? [[String: Any]])
    }

    /// 这条消息被标成缓存断点：内容是分段数组，最后一段文字带 cache_control。
    private func isMarked(_ message: [String: Any]) -> Bool {
        guard let parts = message["content"] as? [[String: Any]],
              let text = parts.last(where: { $0["type"] as? String == "text" }) else { return false }
        return (text["cache_control"] as? [String: String]) == ["type": "ephemeral"]
    }

    // MARK: - 缓存断点

    @Test("Claude：系统提示和当轮提问之前的那条消息加断点，当轮提问不加", arguments: ["anthropic/claude-sonnet-5.5", "~anthropic/claude-sonnet-latest"])
    func claudeBreakpoints(_ model: String) throws {
        let (json, optional) = try body(config(model: model), chat)
        let messages = try sentMessages(json)
        #expect(messages.map(isMarked) == [true, false, true, false])
        #expect(messages[3]["content"] as? String == "第二问")
        // 分段后文字不变
        let system = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(system.count == 1 && system[0]["text"] as? String == "课件")
        #expect(optional.contains("cache_control"))
    }

    @Test("只有系统提示和当轮提问时，只在系统提示上加")
    func firstQuestion() throws {
        let (json, _) = try body(config(), [chat[0], chat[3]])
        #expect(try sentMessages(json).map(isMarked) == [true, false])
    }

    @Test("带截图的当轮提问不加断点")
    func imageQuestionUnmarked() throws {
        var messages = chat
        messages[3] = ["role": "user", "content": [
            ["type": "text", "text": "第二问"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]],
        ]]
        let sent = try sentMessages(try body(config(), messages).json)
        #expect(sent.map(isMarked) == [true, false, true, false])
        let parts = try #require(sent[3]["content"] as? [[String: Any]])
        #expect(parts.allSatisfy { $0["cache_control"] == nil })
    }

    @Test("已经是分段数组的消息，标在最后一段文字上")
    func marksLastTextPart() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "s"],
            ["role": "user", "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"],
                                         ["type": "image_url", "image_url": ["url": "x"]]]],
            ["role": "user", "content": "q"],
        ]
        let parts = try #require(OpenAIClient.withCacheBreakpoints(messages)[1]["content"] as? [[String: Any]])
        #expect(parts[0]["cache_control"] == nil)
        #expect(parts[1]["cache_control"] != nil)
        #expect(parts[2]["cache_control"] == nil)
    }

    @Test("其他模型、其他接口类型、拒绝过 cache_control 的模型不加")
    func noBreakpoints() throws {
        let cases: [(ConnectionConfig, Set<String>)] = [(config(model: "openai/gpt-5.2"), []),
                                                        (config(.custom, model: "anthropic/claude-sonnet-5.5"), []),
                                                        (config(), ["cache_control"])]
        for (config, omit) in cases {
            let (json, optional) = try body(config, chat, omit: omit)
            #expect(try sentMessages(json).allSatisfy { $0["content"] is String })
            #expect(!optional.contains("cache_control"))
        }
    }

    // MARK: - 隐私

    @Test("隐私设置发成 provider 路由参数")
    func privacy() throws {
        #expect(try body(config(privacy: .any), chat).json["provider"] == nil)
        let deny = try #require(try body(config(privacy: .noCollection), chat).json["provider"] as? [String: Any])
        #expect(deny["data_collection"] as? String == "deny" && deny["zdr"] == nil)
        let zdr = try #require(try body(config(privacy: .zeroRetention), chat).json["provider"] as? [String: Any])
        #expect(zdr["data_collection"] as? String == "deny" && zdr["zdr"] as? Bool == true)
        // 别的接口类型不认识这个参数，不发
        #expect(try body(config(.deepSeek, model: "deepseek-chat", privacy: .zeroRetention), chat).json["provider"] == nil)
        // 隐私限制即使在 omit 里也照发：不能因为误判而悄悄失效
        let kept = try body(config(privacy: .noCollection), chat, omit: ["provider"])
        #expect(kept.json["provider"] != nil && !kept.optional.contains("provider"))
    }

    @Test("报错里带“Provider returned error”时，不会把隐私参数当成不被接受")
    func providerWordInError() {
        let error = APIError.http(400, "Provider returned error\nsome upstream failure")
        let (_, optional) = try! OpenAIClient.makeBody(config: config(privacy: .noCollection), messages: chat, options: .init())
        #expect(error.requestProblem(sentParameters: optional, maxTokens: nil) != .unsupported("provider"))
    }

    @Test("打开隐私限制后没有可用上游时，提示可以放宽")
    func privacyHint() {
        let data = Data(#"{"error":{"message":"No endpoints found matching your data policy","code":404}}"#.utf8)
        let strict = OpenAIClient.httpError(404, data, config(privacy: .noCollection)).localizedDescription
        #expect(strict.contains("No endpoints found"))
        #expect(strict.contains(tr("隐私限制", "privacy setting")))
        let loose = OpenAIClient.httpError(404, data, config(privacy: .any)).localizedDescription
        #expect(!loose.contains(tr("隐私限制", "privacy setting")))
    }

    // MARK: - 花费

    @Test("读出 usage 里的实际花费")
    func cost() {
        let usage = OpenAIClient.parseUsage(["prompt_tokens": 1_200, "completion_tokens": 300, "cost": 0.00042,
                                             "prompt_tokens_details": ["cached_tokens": 1_000, "cache_write_tokens": 0]])
        #expect(usage.cost == 0.00042)
        #expect(usage.cacheHit == 1_000)
        #expect(OpenAIClient.parseUsage(["prompt_tokens": 1, "completion_tokens": 1]).cost == nil)
    }

    @Test("统计累计花费；旧的统计没有花费时为 0")
    func costInStats() throws {
        var log = StatsLog()
        let now = Date()
        log.addReply(deck: "/a.pdf", page: 1, model: "m", kind: .question, task: .chat,
                     usage: TokenUsage(prompt: 1, completion: 1, cost: 0.25), at: now)
        log.addReply(deck: "/a.pdf", page: nil, model: "m", kind: .housekeeping, task: .record,
                     usage: TokenUsage(prompt: 1, completion: 1, cost: 0.5), at: now)
        log.addReply(deck: "/a.pdf", page: 1, model: "d", kind: .question, task: .chat,
                     usage: TokenUsage(prompt: 1, completion: 1), at: now)
        let day = try #require(log.days[StatsLog.key(for: now)])
        #expect(day.decks["/a.pdf"]?.tokens.cost == 0.75)
        #expect(day.models["m"]?.cost == 0.75 && day.models["d"]?.cost == 0)
        #expect(day.tasks["chat"]?.cost == 0.25)

        let old = try JSONDecoder().decode(TokenTally.self, from: Data(#"{"requests":3,"prompt":10}"#.utf8))
        #expect(old.cost == 0 && old.requests == 3)
    }

    @Test("花费的显示", arguments: [(0.004, "<$0.01"), (0.42, "$0.42"), (3.456, "$3.46"), (12.34, "$12.3"), (128.6, "$129")])
    func money(_ value: Double, _ expected: String) {
        #expect(StatsFormat.money(value) == expected)
    }

    // MARK: - 模型元数据

    @Test("从模型列表读出识图、最大输出和价格")
    func modelMetadata() throws {
        let entries: [[String: Any]] = [
            ["id": "anthropic/claude-sonnet-5.5", "context_length": 1_000_000,
             "architecture": ["input_modalities": ["text", "image"]],
             "top_provider": ["context_length": 1_000_000, "max_completion_tokens": 64_000],
             "pricing": ["prompt": "0.000003", "completion": "0.000015", "input_cache_read": "0.0000003"]],
            ["id": "deepseek/deepseek-v4", "architecture": ["input_modalities": ["text"]],
             "pricing": ["prompt": "0", "completion": "0"]],
            ["id": "openrouter/auto", "pricing": ["prompt": "-1", "completion": "-1"]],
            ["id": "plain-model"],
        ]
        let list = OpenAIClient.parseModels(entries)
        #expect(list.names == ["anthropic/claude-sonnet-5.5", "deepseek/deepseek-v4", "openrouter/auto", "plain-model"])
        #expect(list.windows["anthropic/claude-sonnet-5.5"] == 1_000_000)

        let claude = try #require(list.infos["anthropic/claude-sonnet-5.5"])
        #expect(claude.acceptsImages == true && claude.maxOutput == 64_000)
        #expect(claude.price?.label == "$3 / $15")
        #expect(claude.price?.cacheRead == 0.0000003)

        let deepseek = try #require(list.infos["deepseek/deepseek-v4"])
        #expect(deepseek.acceptsImages == false)
        #expect(deepseek.price?.label == tr("免费", "Free"))

        // 按实际路由计价的模型价格为负，不显示；什么都没报告的模型没有元数据
        #expect(list.infos["openrouter/auto"] == nil)
        #expect(list.infos["plain-model"] == nil)
    }

    @Test("价格按每百万 token 显示", arguments: [(0.00000015, "0.15"), (0.0000006, "0.6"), (0.000075, "75"), (0.000000001, "<0.01")])
    func perMillion(_ perToken: Double, _ expected: String) {
        #expect(ModelPrice.perMillion(perToken) == expected)
    }

    @Test("旧版本保存的服务商没有元数据和隐私设置，读出默认值")
    func decodesOldProvider() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"OR","baseURL":"https://openrouter.ai/api/v1","kind":"openRouter"}"#
        let provider = try JSONDecoder().decode(APIProvider.self, from: Data(json.utf8))
        #expect(provider.modelInfo.isEmpty && provider.privacy == .any)
    }
}
