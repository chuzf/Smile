import Foundation

/// OpenAI Chat Completions 兼容接口（Kimi、豆包方舟及多数第三方网关）
struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    // 不传 temperature：部分网关会把请求转给不接受采样参数的 Claude 模型
    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct ChoiceMessage: Decodable { let content: String? }
            let message: ChoiceMessage
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }

    func complete(system: String, user: String) async throws -> String {
        guard let url = LLMHTTP.endpoint(baseURL, path: "/chat/completions") else {
            throw LLMError.invalidURL
        }
        let body = RequestBody(model: model, messages: [
            Message(role: "system", content: system),
            Message(role: "user", content: user),
        ])
        let request = try LLMHTTP.makeRequest(url: url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        let data = try await LLMHTTP.send(request, session: session)
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMError.emptyResponse
        }
        if decoded.choices.first?.finishReason == "length" { throw LLMError.truncated }
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LLMError.emptyResponse }
        return content
    }
}
