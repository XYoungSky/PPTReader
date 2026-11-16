import Foundation

enum StreamEvent: Sendable {
    case reasoning(String)
    case content(String)
    case usage(TokenUsage)
    /// 生成结束的原因，如 stop、length（达到长度上限）。
    case finish(String)
    /// 还没有输出时连接失败，正在第 attempt 次（共 of 次）重试。
    case retrying(attempt: Int, of: Int)
}

enum APIError: LocalizedError {
    case missingKey
    case missingModel
    case invalidURL(String)
    case http(Int, String)
    /// 用 Kimi Code 会员的 Key 请求了别的地址（通常是开放平台 api.moonshot.cn），被拒绝为 401。
    case kimiCodeKeyMismatch(String)
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
        case .kimiCodeKeyMismatch(let message):
            "\(Self.hint(for: 401)) (HTTP 401)" + (message.isEmpty ? "" : "\n\(message)") + "\n"
                + tr("这是 Kimi Code 会员订阅的 Key（sk-kimi- 开头），只能用于 https://api.kimi.com/coding/v1。api.moonshot.cn 是按量付费的 Kimi 开放平台，需要在 platform.moonshot.cn 另外创建 Key。",
                     "This is a Kimi Code membership key (sk-kimi-…), which only works with https://api.kimi.com/coding/v1. api.moonshot.cn is the pay-as-you-go Kimi Platform and needs its own key from platform.moonshot.cn.")
        case .server(let message):
            tr("服务端错误：", "Server error: ") + message
        }
    }

    /// 400/413/422 往往是参数问题（图片、上下文长度、max_tokens、不认识的参数），调整后可以重试。
    var isBadRequest: Bool {
        if case .http(let code, _) = self { return code == 400 || code == 413 || code == 422 }
        return false
    }

    /// 从 400 类错误的说明里判断是哪里出了问题。各家的措辞不同，只按关键词粗略判断，认不出时返回 nil。
    /// - Parameters:
    ///   - sentParameters: 这次请求发送了的可选参数名。
    ///   - maxTokens: 这次请求发送的 max_tokens（没发送为 nil）。
    func requestProblem(sentParameters: [String], maxTokens: Int?) -> RequestProblem? {
        guard isBadRequest, case .http(_, let message) = self else { return nil }
        let lower = message.lowercased()
        let numbers = Self.numbers(in: message)
        let contextHints = ["context length", "context_length", "context window", "maximum context", "token limit",
                            "too many tokens", "prompt is too long", "input is too long", "tokens exceed", "上下文长度", "超出.*token"]
        if contextHints.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return .contextLength(limit: numbers.first { $0 >= 1024 })
        }
        if maxTokens != nil, ["max_tokens", "max_completion_tokens", "max_output_tokens"].contains(where: lower.contains) {
            // 报错里通常会写出允许的上限，取比这次请求的值小的最大那个数
            return .maxTokens(limit: numbers.filter { $0 >= 256 && $0 < maxTokens! }.max())
        }
        if ["image", "vision", "multimodal", "multi-modal", "多模态", "图片", "图像"].contains(where: lower.contains) {
            return .image
        }
        if let parameter = sentParameters.first(where: { lower.contains($0) }) {
            return .unsupported(parameter)
        }
        return nil
    }

    private static func numbers(in text: String) -> [Int] {
        // 去掉数字中间的千位分隔符（"128,000"）
        let plain = text.replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
        return plain.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
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

/// 400 类错误的具体原因，用于决定怎样调整后重试。
enum RequestProblem: Equatable {
    /// 模型不接受图片。
    case image
    /// 上下文超长；能从报错里读出上限时附上。
    case contextLength(limit: Int?)
    /// max_tokens 超出范围或不被接受；能读出允许的上限时附上。
    case maxTokens(limit: Int?)
    /// 不接受某个可选参数。
    case unsupported(String)
}

/// 测试连接的结果。
enum ConnectionCheck {
    /// 接口返回了模型列表，以及其中报告了上下文窗口的模型。
    case models([String], windows: [String: Int])
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
        var request = URLRequest(url: try endpoint(config.baseURL, path))
        if config.apiKey.isEmpty {
            // 本机或局域网里的服务（Ollama、LM Studio 等）通常不需要 Key
            guard isLocal(config.baseURL) else { throw APIError.missingKey }
        } else {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// 本机或局域网地址。
    static func isLocal(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed)?.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    /// 请求的可选部分。
    struct RequestOptions: Sendable {
        /// 为空时不发送，由服务商使用默认值。
        var maxTokens: Int?
        /// 这个模型不接受、不再发送的可选参数。
        var omit: Set<String> = []
        /// 缓存路由键：同一份课件的请求带同一个键，服务商会尽量把它们发到同一份缓存（目前只对 OpenAI 发送）。
        var cacheKey: String?
    }

    /// 组装请求体。返回实际发送了的可选参数名，出错时用来判断是哪个参数不被接受。
    static func makeBody(config: ConnectionConfig, messages: [[String: Any]], options: RequestOptions) throws -> (data: Data, optionalParameters: [String]) {
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
        ]
        var optional: [String] = []
        func add(_ key: String, _ value: Any) {
            guard !options.omit.contains(key) else { return }
            body[key] = value
            optional.append(key)
        }
        add("stream_options", ["include_usage": true])
        if let maxTokens = options.maxTokens { body["max_tokens"] = maxTokens }
        // DeepSeek 用 thinking 参数开关深度思考（默认开启）；其他服务不认识这个参数，不发送
        if config.kind.hasThinkingToggle {
            add("thinking", ["type": config.thinking ? "enabled" : "disabled"])
        }
        // Kimi Code 用 reasoning_effort（low / high / max）调整思考强度；不设置时使用模型默认值
        if config.kind.hasReasoningEffort, config.reasoningEffort != .auto {
            add("reasoning_effort", config.reasoningEffort.rawValue)
        }
        // Kimi 开放平台的缓存默认只保留 5 分钟，学生在一页上停留稍久，下一问就要全价重算整份课件；
        // 改成 1 小时后首次写入贵一些，但之后一小时内的提问都能命中
        if config.kind.hasCacheTTL, config.longCache {
            add("prompt_cache_options", ["mode": "implicit", "ttl": "1h"])
        }
        // OpenAI 按 prompt_cache_key 把请求路由到同一份缓存（Codex 用会话 ID）
        if let key = options.cacheKey, isOpenAI(config.baseURL) {
            add("prompt_cache_key", key)
        }
        return (try JSONSerialization.data(withJSONObject: body), optional)
    }

    /// 还没收到任何输出时，限流、服务端临时故障和连接中断最多自动重试这么多次。
    private static let maxRetries = 3

    /// 非 2xx 响应，附带重试需要的信息。
    private struct HTTPFailure: Error {
        let error: APIError
        let status: Int
        let retryAfter: Double?
    }

    /// - Parameter body: `makeBody` 组装好的请求体。
    static func stream(config: ConnectionConfig, body: Data) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw APIError.missingModel
                    }
                    var request = try request(config, path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = body

                    var yielded = false
                    var attempt = 0
                    while true {
                        do {
                            try await streamOnce(request, config) { event in
                                yielded = true
                                continuation.yield(event)
                            }
                            break
                        } catch {
                            // 已经输出了内容就不再重试，以免回答重复
                            guard !yielded, attempt < maxRetries, let delay = retryDelay(for: error, attempt: attempt) else {
                                throw (error as? HTTPFailure)?.error ?? error
                            }
                            attempt += 1
                            continuation.yield(.retrying(attempt: attempt, of: maxRetries))
                            try await Task.sleep(for: .seconds(delay))
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

    private static func streamOnce(_ request: URLRequest, _ config: ConnectionConfig, emit: (StreamEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 32_000 { break }
            }
            let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            throw HTTPFailure(error: httpError(status, data, config), status: status, retryAfter: retryAfter)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any] {
                throw APIError.server(error["message"] as? String ?? "unknown")
            }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let delta = choice?["delta"] as? [String: Any] {
                if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
                    emit(.reasoning(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    emit(.content(content))
                }
            }
            if let reason = choice?["finish_reason"] as? String {
                emit(.finish(reason))
            }
            // 大多数服务把 usage 放在顶层（其余分片为 null），Kimi 放在最后一个 choice 里
            if let usage = (json["usage"] as? [String: Any]) ?? (choice?["usage"] as? [String: Any]) {
                emit(.usage(parseUsage(usage)))
            }
        }
    }

    /// 可以重试时返回等待的秒数：限流和服务端临时故障按 Retry-After 或指数退避，连接中断稍等即重试。
    /// 额度用尽、余额不足这类重试也没用的错误，以及要等很久的限流，直接报错。
    private static func retryDelay(for error: Error, attempt: Int) -> Double? {
        let backoff = 1.5 * pow(2, Double(attempt))
        if let failure = error as? HTTPFailure {
            guard [408, 429, 500, 502, 503, 504, 529].contains(failure.status) else { return nil }
            if case .http(_, let message) = failure.error,
               ["quota", "balance", "insufficient", "billing", "余额", "额度"].contains(where: message.lowercased().contains) {
                return nil
            }
            if let wait = failure.retryAfter { return wait <= 20 ? max(wait, 0.5) : nil }
            return backoff
        }
        if let urlError = error as? URLError,
           [.networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse].contains(urlError.code) {
            return backoff
        }
        return nil
    }

    static func isOpenAI(_ baseURL: String) -> Bool {
        baseURL.lowercased().contains("api.openai.com")
    }

    /// 只用于从地址推断接口类型；发请求时按保存的类型判断。
    static func isDeepSeek(_ baseURL: String) -> Bool {
        baseURL.lowercased().contains("deepseek.com")
    }

    /// Kimi Code 会员订阅接口：国内 api.kimi.com/coding，海外 api.kimi.ai/coding。
    static func isKimiCode(_ baseURL: String) -> Bool {
        let lower = baseURL.lowercased()
        return (lower.contains("api.kimi.com") || lower.contains("api.kimi.ai")) && lower.contains("/coding")
    }

    /// Kimi Code 会员的 Key 以 sk-kimi- 开头，只能配合 Kimi Code 地址使用。
    static func isKimiCodeKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-kimi-")
    }

    /// 把非 2xx 响应转成错误；Kimi Code 的 Key 用错地址时给出明确提示。
    private static func httpError(_ status: Int, _ data: Data, _ config: ConnectionConfig) -> APIError {
        let message = errorMessage(from: data)
        if status == 401, isKimiCodeKey(config.apiKey), !isKimiCode(config.baseURL) {
            return .kimiCodeKeyMismatch(message)
        }
        return .http(status, message)
    }

    private static func parseUsage(_ json: [String: Any]) -> TokenUsage {
        let cached = (json["prompt_cache_hit_tokens"] as? Int)
            ?? ((json["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
            ?? (json["cached_tokens"] as? Int)
        // Kimi 单独报告写入缓存的 token（prompt_tokens_details.cache_write_tokens）
        let written = (json["prompt_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int
        return TokenUsage(
            prompt: json["prompt_tokens"] as? Int ?? 0,
            completion: json["completion_tokens"] as? Int ?? 0,
            cacheHit: cached,
            cacheWrite: written
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
    static func listModels(config: ConnectionConfig) async throws -> (names: [String], windows: [String: Int]) {
        var request = try request(config, path: "models")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw httpError(status, data, config) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["data"] as? [[String: Any]] ?? []
        var windows: [String: Int] = [:]
        for entry in entries {
            if let id = entry["id"] as? String, let window = contextWindow(in: entry) { windows[id] = window }
        }
        return (entries.compactMap { $0["id"] as? String }.sorted(), windows)
    }

    /// 有些接口会在模型列表里报告上下文长度（OpenRouter、vLLM、部分国内服务商），字段名各不相同。
    private static func contextWindow(in entry: [String: Any]) -> Int? {
        let keys = ["context_length", "context_window", "max_context_length", "max_model_len", "max_input_tokens", "context_size"]
        for key in keys {
            if let value = (entry[key] as? NSNumber)?.intValue, value >= 1024 { return value }
        }
        if let top = entry["top_provider"] as? [String: Any], let value = (top["context_length"] as? NSNumber)?.intValue, value >= 1024 {
            return value
        }
        return nil
    }

    /// 测试连接：优先获取模型列表；接口不提供列表（404 / 405）时，用当前模型发一个极短的请求。
    static func testConnection(config: ConnectionConfig) async throws -> ConnectionCheck {
        do {
            let list = try await listModels(config: config)
            return .models(list.names, windows: list.windows)
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
        guard (200..<300).contains(status) else { throw httpError(status, data, config) }
    }
}
