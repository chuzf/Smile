import Foundation

/// Anthropic Messages 兼容接口（Anthropic 官方及 moacode 等网关）
struct AnthropicClient: LLMClient {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16000
    /// 列模型最多翻几页，防止网关一直返回 has_more
    static let maxModelPages = 5

    let baseURL: URL
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    // 不传 temperature / thinking：Opus 4.7+、Opus 5、Sonnet 5 对采样参数返回 400
    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let outputConfig: OutputConfig?

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    private struct OutputConfig: Encodable {
        let effort: String
    }

    /// 支持 effort 参数的模型（Haiku 4.5、Sonnet 4.5 及更早的模型会对它返回 400）。
    /// 按包含匹配，兼容网关加前缀的模型名，比如 "anthropic/claude-opus-5"
    private static let effortModels = [
        "claude-opus-5", "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
        "claude-sonnet-5", "claude-sonnet-4-6", "claude-fable-5", "claude-mythos-5",
    ]

    /// 整理文字不需要深度推理。Opus 5 等模型默认开启思考，思考 token 也计入 max_tokens，
    /// 默认 effort 下长文容易被截断；low 减少思考量，也更快更省。不认识的模型不传，避免 400
    private var outputConfig: OutputConfig? {
        let name = model.lowercased()
        return Self.effortModels.contains(where: name.contains) ? OutputConfig(effort: "low") : nil
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    /// base 已以 /v1 结尾时只拼 /messages；已是完整端点时原样使用
    var endpoint: URL? {
        let base = LLMHTTP.trimmedBase(baseURL)
        if base.hasSuffix("/v1/messages") { return URL(string: base) }
        return URL(string: base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages")
    }

    /// 官方 API 只认 x-api-key；不少第三方网关按 Bearer 鉴权，所以非官方地址两个头都带
    var headers: [String: String] {
        var headers = ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
        if baseURL.host()?.lowercased() != "api.anthropic.com" {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    func complete(system: String, user: String) async throws -> String {
        guard let url = endpoint else { throw LLMError.invalidURL }
        let body = RequestBody(model: model, maxTokens: Self.maxTokens, system: system,
                               messages: [Message(role: "user", content: user)],
                               outputConfig: outputConfig)
        let request = try LLMHTTP.makeRequest(
            url: url,
            headers: headers,
            body: body
        )
        let data = try await LLMHTTP.send(request, session: session)
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMError.emptyResponse
        }
        if decoded.stopReason == "max_tokens" { throw LLMError.truncated }
        // 只取 text 块，忽略 thinking 等；refusal 时 content 为空
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    /// base 已以 /v1 结尾时只拼 /models；填的是 /v1/messages 完整端点时换成同级的 /models
    var modelsEndpoint: URL? {
        var base = LLMHTTP.trimmedBase(baseURL)
        if base.hasSuffix("/v1/messages") { base.removeLast("/messages".count) }
        return URL(string: base.hasSuffix("/v1") ? base + "/models" : base + "/v1/models")
    }

    func listModels() async throws -> [String] {
        guard let endpoint = modelsEndpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LLMError.invalidURL
        }
        var ids: [String] = []
        var afterID: String?
        for _ in 0..<Self.maxModelPages {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = query
            guard let url = components.url else { throw LLMError.invalidURL }
            let data = try await LLMHTTP.send(LLMHTTP.makeGetRequest(url: url, headers: headers), session: session)
            let page = try LLMHTTP.decodeModelPage(data)
            ids += page.data.map(\.id)
            guard page.hasMore == true, let last = page.lastId else { break }
            afterID = last
        }
        return LLMHTTP.normalizedModelIDs(ids)
    }
}
