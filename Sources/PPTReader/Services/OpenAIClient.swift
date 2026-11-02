import Foundation

enum StreamEvent: Sendable {
    case reasoning(String)
    case content(String)
    case usage(TokenUsage)
}

enum APIError: LocalizedError {
    case missingKey
    case missingModel
    case invalidURL(String)
    case http(Int, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            tr("尚未设置 API Key", "API key not set")
        case .missingModel:
            tr("请先在设置中选择或填写模型名称", "Choose or enter a model name in Settings first")
        case .invalidURL(let url):
            tr("API 地址无效：", "Invalid API URL: ") + url
        case .http(let code, let message):
            "\(Self.hint(for: code)) (HTTP \(code))" + (message.isEmpty ? "" : "\n\(message)")
                + (Self.isCodingAgentOnly(code, message)
                    ? "\n" + tr("Kimi Code 会员订阅的 API 目前只对编程工具开放。可以改用 Kimi 开放平台（按量付费）的 API Key。",
                                "The Kimi Code membership API is currently limited to coding tools. You can use a Kimi Platform (pay-as-you-go) API key instead.")
                    : "")
        case .server(let message):
            tr("服务端错误：", "Server error: ") + message
        }
    }

    /// 400/422 往往是模型不接受图片等参数问题，可以去掉图片后重试。
    var isBadRequest: Bool {
        if case .http(let code, _) = self { return code == 400 || code == 422 }
        return false
    }

    /// Kimi Code 拒绝非编程工具时返回 403，并提示 “only available for Coding Agents”。
    private static func isCodingAgentOnly(_ code: Int, _ message: String) -> Bool {
        code == 403 && message.range(of: "coding agent", options: .caseInsensitive) != nil
    }

    private static func hint(for code: Int) -> String {
        switch code {
        case 400: tr("请求格式有误", "Bad request")
        case 401: tr("API Key 无效", "Invalid API key")
        case 402: tr("账户余额不足", "Insufficient balance")
        case 403: tr("没有访问权限", "Access denied")
        case 404: tr("模型或地址不存在", "Model or URL not found")
        case 422: tr("请求参数有误", "Invalid parameters")
        case 429: tr("请求过于频繁", "Rate limited")
        case 500...599: tr("服务暂时不可用", "Service unavailable")
        default: tr("请求失败", "Request failed")
        }
    }
}

/// 测试连接的结果。
enum ConnectionCheck {
    /// 接口返回了模型列表。
    case models([String])
    /// 接口不提供模型列表，但用当前模型发送的请求成功了。
    case reachable
}

/// OpenAI 兼容的 Chat Completions 客户端（DeepSeek、Kimi、OpenAI、本地 Ollama 等均可）。
enum OpenAIClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        for suffix in ["/chat/completions", "/models"] where trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
        }
        guard let url = URL(string: trimmed + "/" + path), url.host != nil else {
            throw APIError.invalidURL(base)
        }
        return url
    }

    private static func request(_ config: ConnectionConfig, path: String) throws -> URLRequest {
        guard !config.apiKey.isEmpty else { throw APIError.missingKey }
        var request = URLRequest(url: try endpoint(config.baseURL, path))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// - Parameter messages: 已序列化好的 messages 数组（JSON）。
    static func stream(config: ConnectionConfig, messages: Data) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw APIError.missingModel
                    }
                    var request = try request(config, path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try body(config: config, messages: messages)

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 32_000 { break }
                        }
                        throw APIError.http(status, errorMessage(from: data))
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let error = json["error"] as? [String: Any] {
                            throw APIError.server(error["message"] as? String ?? "unknown")
                        }
                        if let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any] {
                            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.content(content))
                            }
                        }
                        // 大多数服务把 usage 放在顶层（其余分片为 null），Kimi 放在最后一个 choice 里
                        let choiceUsage = (json["choices"] as? [[String: Any]])?.first?["usage"] as? [String: Any]
                        if let usage = (json["usage"] as? [String: Any]) ?? choiceUsage {
                            continuation.yield(.usage(parseUsage(usage)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func body(config: ConnectionConfig, messages: Data) throws -> Data {
        let messagesJSON = try JSONSerialization.jsonObject(with: messages)
        var body: [String: Any] = [
            "model": config.model,
            "messages": messagesJSON,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // DeepSeek 用 thinking 参数开关深度思考（默认开启）；其他服务不认识这个参数，不发送
        if isDeepSeek(config.baseURL) {
            body["thinking"] = ["type": config.thinking ? "enabled" : "disabled"]
        }
        // Kimi Code 用 reasoning_effort（low / high / max）调整思考强度；不设置时使用模型默认值
        if isKimiCode(config.baseURL), config.reasoningEffort != .auto {
            body["reasoning_effort"] = config.reasoningEffort.rawValue
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func isDeepSeek(_ baseURL: String) -> Bool {
        baseURL.lowercased().contains("deepseek.com")
    }

    /// Kimi Code 会员订阅接口：国内 api.kimi.com/coding，海外 api.kimi.ai/coding。
    static func isKimiCode(_ baseURL: String) -> Bool {
        let lower = baseURL.lowercased()
        return (lower.contains("api.kimi.com") || lower.contains("api.kimi.ai")) && lower.contains("/coding")
    }

    private static func parseUsage(_ json: [String: Any]) -> TokenUsage {
        let cached = (json["prompt_cache_hit_tokens"] as? Int)
            ?? ((json["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
            ?? (json["cached_tokens"] as? Int)
        return TokenUsage(
            prompt: json["prompt_tokens"] as? Int ?? 0,
            completion: json["completion_tokens"] as? Int ?? 0,
            cacheHit: cached
        )
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return String(data: data.prefix(500), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 获取模型列表，同时用来测试连接是否可用。
    static func listModels(config: ConnectionConfig) async throws -> [String] {
        var request = try request(config, path: "models")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status, errorMessage(from: data)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return models.sorted()
    }

    /// 测试连接：优先获取模型列表；接口不提供列表（404 / 405）时，用当前模型发一个极短的请求。
    static func testConnection(config: ConnectionConfig) async throws -> ConnectionCheck {
        do {
            return .models(try await listModels(config: config))
        } catch APIError.http(let code, _) where code == 404 || code == 405 {
            guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.missingModel }
            try await ping(config: config)
            return .reachable
        }
    }

    private static func ping(config: ConnectionConfig) async throws {
        var request = try request(config, path: "chat/completions")
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 16,
            "stream": false,
        ] as [String: Any])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status, errorMessage(from: data)) }
    }
}
