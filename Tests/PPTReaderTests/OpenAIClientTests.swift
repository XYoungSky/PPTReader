import Foundation
import Testing
@testable import PPTReader

/// 请求体：每种接口类型只发它认识的专有参数。
@Suite("请求体")
struct RequestBodyTests {
    private func config(_ kind: ProviderPreset, baseURL: String? = nil, effort: ReasoningEffort = .auto,
                        thinking: Bool = true, longCache: Bool = false) -> ConnectionConfig {
        ConnectionConfig(providerID: UUID(), kind: kind, baseURL: baseURL ?? kind.baseURL, apiKey: "k",
                         model: "m", thinking: thinking, reasoningEffort: effort, longCache: longCache)
    }

    private func body(_ config: ConnectionConfig, options: OpenAIClient.RequestOptions = .init())
        throws -> (json: [String: Any], optional: [String]) {
        let (data, optional) = try OpenAIClient.makeBody(config: config, messages: [["role": "user", "content": "hi"]], options: options)
        return (try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), optional)
    }

    @Test("OpenRouter 用 reasoning.effort", arguments: [ReasoningEffort.none, .low, .medium, .high, .xhigh, .max])
    func openRouterEffort(_ effort: ReasoningEffort) throws {
        let (json, optional) = try body(config(.openRouter, effort: effort))
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == effort.rawValue)
        #expect(json["reasoning_effort"] == nil)
        #expect(optional.contains("reasoning"))
    }

    @Test("Kimi Code 用 reasoning_effort", arguments: [ReasoningEffort.low, .high, .max])
    func kimiCodeEffort(_ effort: ReasoningEffort) throws {
        let (json, _) = try body(config(.kimiCode, effort: effort))
        #expect(json["reasoning_effort"] as? String == effort.rawValue)
        #expect(json["reasoning"] == nil)
    }

    @Test("默认强度不发送")
    func autoEffortOmitted() throws {
        for kind in [ProviderPreset.openRouter, .kimiCode] {
            let (json, _) = try body(config(kind, effort: .auto))
            #expect(json["reasoning"] == nil && json["reasoning_effort"] == nil)
        }
    }

    /// 改过接口类型后，保存的强度可能不在新类型的选项里，这时不能发出对方不认识的取值。
    @Test("接口类型不支持的强度不发送")
    func unsupportedEffortOmitted() throws {
        let cases: [(ProviderPreset, ReasoningEffort)] = [
            (.kimiCode, .medium), (.kimiCode, .none), (.openRouter, .minimal),
            (.deepSeek, .high), (.kimiPlatform, .high), (.custom, .high),
        ]
        for (kind, effort) in cases {
            let (json, optional) = try body(config(kind, effort: effort))
            #expect(json["reasoning"] == nil, "\(kind) \(effort)")
            #expect(json["reasoning_effort"] == nil, "\(kind) \(effort)")
            #expect(!optional.contains("reasoning") && !optional.contains("reasoning_effort"))
        }
    }

    @Test("模型拒绝过的参数不再发送")
    func omittedParameter() throws {
        var options = OpenAIClient.RequestOptions()
        options.omit = ["reasoning", "prompt_cache_key"]
        options.cacheKey = "deck"
        let (json, optional) = try body(config(.openRouter, effort: .high), options: options)
        #expect(json["reasoning"] == nil)
        #expect(json["prompt_cache_key"] == nil)
        #expect(!optional.contains("reasoning"))
        #expect(optional.contains("stream_options"))
    }

    @Test("prompt_cache_key 只发给 OpenAI 和 OpenRouter")
    func cacheKey() throws {
        var options = OpenAIClient.RequestOptions()
        options.cacheKey = "deck-1"
        let sent: [(ConnectionConfig, Bool)] = [
            (config(.openRouter), true),
            // 经代理访问 OpenRouter 时地址认不出来，按保存的类型判断
            (config(.openRouter, baseURL: "https://proxy.example.com/v1"), true),
            (config(.custom, baseURL: "https://api.openai.com/v1"), true),
            (config(.custom, baseURL: "https://example.com/v1"), false),
            (config(.deepSeek), false),
            (config(.kimiCode), false),
            (config(.kimiPlatform), false),
        ]
        for (config, expected) in sent {
            let (json, _) = try body(config, options: options)
            #expect((json["prompt_cache_key"] as? String == "deck-1") == expected, "\(config.kind) \(config.baseURL)")
        }
        let (json, _) = try body(config(.openRouter))
        #expect(json["prompt_cache_key"] == nil, "没有 cacheKey 时不发送")
    }

    @Test("DeepSeek 的 thinking 开关")
    func deepSeekThinking() throws {
        for on in [true, false] {
            let (json, _) = try body(config(.deepSeek, thinking: on))
            let thinking = try #require(json["thinking"] as? [String: Any])
            #expect(thinking["type"] as? String == (on ? "enabled" : "disabled"))
        }
        let (json, _) = try body(config(.openRouter))
        #expect(json["thinking"] == nil)
    }

    @Test("Kimi 开放平台缓存保留 1 小时")
    func kimiPlatformCacheTTL() throws {
        let (on, _) = try body(config(.kimiPlatform, longCache: true))
        #expect((on["prompt_cache_options"] as? [String: Any])?["ttl"] as? String == "1h")
        let (off, _) = try body(config(.kimiPlatform, longCache: false))
        #expect(off["prompt_cache_options"] == nil)
        let (other, _) = try body(config(.openRouter, longCache: true))
        #expect(other["prompt_cache_options"] == nil)
    }

    @Test("max_tokens 不算可选参数")
    func maxTokens() throws {
        var options = OpenAIClient.RequestOptions()
        options.maxTokens = 2048
        options.omit = ["max_tokens"]
        let (json, optional) = try body(config(.openRouter), options: options)
        #expect(json["max_tokens"] as? Int == 2048)
        #expect(!optional.contains("max_tokens"))
    }
}

/// 错误分类：哪些失败值得自动重试。
@Suite("错误与重试")
struct ErrorClassificationTests {
    private let openRouter = ConnectionConfig(providerID: UUID(), kind: .openRouter, baseURL: "https://openrouter.ai/api/v1",
                                              apiKey: "k", model: "m", thinking: false)
    private let deepSeek = ConnectionConfig(providerID: UUID(), kind: .deepSeek, baseURL: "https://api.deepseek.com",
                                            apiKey: "k", model: "m", thinking: false)

    private func errorJSON(_ message: String, metadata: [String: Any]? = nil) -> Data {
        var error: [String: Any] = ["code": 503, "message": message]
        if let metadata { error["metadata"] = metadata }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    private func failure(_ status: Int, _ data: Data = Data(), config: ConnectionConfig? = nil,
                         retryAfter: Double? = nil) -> OpenAIClient.HTTPFailure {
        let config = config ?? openRouter
        return OpenAIClient.HTTPFailure(error: OpenAIClient.httpError(status, data, config), status: status,
                                        retryAfter: retryAfter, permanent: OpenAIClient.isPermanent(status, data, config))
    }

    @Test("OpenRouter 上游过载的 503 可以重试")
    func overloadedIsTransient() {
        let data = errorJSON("Provider overloaded", metadata: ["error_type": "provider_overloaded"])
        #expect(!OpenAIClient.isPermanent(503, data, openRouter))
        #expect(OpenAIClient.retryDelay(for: failure(503, data), attempt: 0) != nil)
    }

    @Test("OpenRouter 没有可用上游的 503 不重试")
    func noProviderIsPermanent() {
        let data = errorJSON("No endpoints found that support image input")
        #expect(OpenAIClient.isPermanent(503, data, openRouter))
        #expect(OpenAIClient.retryDelay(for: failure(503, data), attempt: 0) == nil)
        guard case .http(503, let message) = OpenAIClient.httpError(503, data, openRouter) else {
            Issue.record("应为 HTTP 错误")
            return
        }
        #expect(message.contains("No endpoints found"))
        #expect(message.split(separator: "\n").count == 2, "原始信息之后附一行提示")
    }

    /// 网关自己返回的 503（HTML 或空响应）不是 OpenRouter 的路由结论，应当当作临时故障重试。
    @Test("OpenRouter 不带错误 JSON 的 503 可以重试")
    func gatewayOutageIsTransient() {
        for data in [Data(), Data("<html>503 Service Temporarily Unavailable</html>".utf8)] {
            #expect(!OpenAIClient.isPermanent(503, data, openRouter))
            #expect(OpenAIClient.retryDelay(for: failure(503, data), attempt: 0) != nil)
        }
    }

    @Test("其他服务商的 503 照常重试")
    func otherProviders503() {
        let data = errorJSON("busy")
        #expect(!OpenAIClient.isPermanent(503, data, deepSeek))
        #expect(OpenAIClient.retryDelay(for: failure(503, data, config: deepSeek), attempt: 0) != nil)
    }

    @Test("OpenRouter 402 提示充值，并且不重试")
    func openRouterCredits() {
        let data = errorJSON("Insufficient credits")
        guard case .http(402, let message) = OpenAIClient.httpError(402, data, openRouter) else {
            Issue.record("应为 HTTP 402")
            return
        }
        #expect(message.contains("openrouter.ai/settings/credits"))
        #expect(OpenAIClient.retryDelay(for: failure(402, data), attempt: 0) == nil)
    }

    @Test("上游错误的 metadata.raw 带进报错信息")
    func upstreamRaw() {
        let data = errorJSON("Provider returned error", metadata: ["raw": "image input is not supported"])
        guard case .http(_, let message) = OpenAIClient.httpError(400, data, openRouter) else {
            Issue.record("应为 HTTP 错误")
            return
        }
        #expect(message.hasPrefix("Provider returned error\nimage input is not supported"))
    }

    @Test("可重试的状态码按指数退避")
    func backoff() {
        for status in [408, 429, 500, 502, 503, 504, 529] {
            #expect(OpenAIClient.retryDelay(for: failure(status, config: deepSeek), attempt: 0) == 1.5)
            #expect(OpenAIClient.retryDelay(for: failure(status, config: deepSeek), attempt: 2) == 6)
        }
        for status in [400, 401, 403, 404, 413, 422] {
            #expect(OpenAIClient.retryDelay(for: failure(status, config: deepSeek), attempt: 0) == nil, "\(status)")
        }
    }

    @Test("Retry-After：短的照等，长的直接报错")
    func retryAfter() {
        #expect(OpenAIClient.retryDelay(for: failure(429, config: deepSeek, retryAfter: 5), attempt: 0) == 5)
        #expect(OpenAIClient.retryDelay(for: failure(429, config: deepSeek, retryAfter: 0), attempt: 0) == 0.5)
        #expect(OpenAIClient.retryDelay(for: failure(429, config: deepSeek, retryAfter: 60), attempt: 0) == nil)
    }

    @Test("额度用尽的 429 不重试")
    func quotaExhausted() {
        for message in ["You exceeded your current quota", "Insufficient Balance", "账户余额不足"] {
            let data = try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
            #expect(OpenAIClient.retryDelay(for: failure(429, data, config: deepSeek), attempt: 0) == nil, "\(message)")
        }
    }

    @Test("连接中断可以重试，取消不重试")
    func urlErrors() {
        #expect(OpenAIClient.retryDelay(for: URLError(.networkConnectionLost), attempt: 1) == 3)
        #expect(OpenAIClient.retryDelay(for: URLError(.cancelled), attempt: 0) == nil)
        #expect(OpenAIClient.retryDelay(for: URLError(.timedOut), attempt: 0) == nil)
    }
}

/// 流式分片里的思考内容。
@Suite("思考内容")
struct ReasoningTextTests {
    @Test func reasoningContent() {
        #expect(OpenAIClient.reasoningText(in: ["reasoning_content": "a"]) == "a")
        #expect(OpenAIClient.reasoningText(in: ["reasoning": "b"]) == "b")
    }

    @Test("OpenRouter 的 reasoning_details")
    func reasoningDetails() {
        let delta: [String: Any] = ["reasoning_details": [
            ["type": "reasoning.text", "text": "x"],
            ["type": "reasoning.summary", "summary": "y"],
            ["type": "reasoning.encrypted", "data": "opaque"],
        ]]
        #expect(OpenAIClient.reasoningText(in: delta) == "xy")
    }

    @Test("只有加密内容或空字符串时没有思考文字")
    func empty() {
        #expect(OpenAIClient.reasoningText(in: ["reasoning_details": [["type": "reasoning.encrypted", "data": "z"]]]) == nil)
        #expect(OpenAIClient.reasoningText(in: ["reasoning": ""]) == nil)
        #expect(OpenAIClient.reasoningText(in: ["content": "hi"]) == nil)
    }

    @Test("reasoning 为空时退回 reasoning_details")
    func fallback() {
        #expect(OpenAIClient.reasoningText(in: ["reasoning": "", "reasoning_details": [["text": "d"]]]) == "d")
    }
}
