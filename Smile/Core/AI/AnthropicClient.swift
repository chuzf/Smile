import Foundation

/// Anthropic Messages 兼容接口（Anthropic 官方及 moacode 等网关）
struct AnthropicClient: LLMClient {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16000

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

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
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
                               messages: [Message(role: "user", content: user)])
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
}
