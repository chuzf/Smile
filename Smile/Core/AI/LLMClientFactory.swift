import Foundation

enum LLMClientFactory {
    static func make(provider: AIProvider, apiKey: String, session: URLSession = .shared) throws -> LLMClient {
        guard let base = provider.validatedBaseURL else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !provider.trimmedModel.isEmpty else { throw LLMError.notConfigured }
        switch provider.apiProtocol {
        case .openAI:
            return OpenAICompatibleClient(baseURL: base, model: provider.trimmedModel, apiKey: key, session: session)
        case .anthropic:
            return AnthropicClient(baseURL: base, model: provider.trimmedModel, apiKey: key, session: session)
        }
    }

    /// 拉取模型列表；不要求已填模型
    static func listModels(provider: AIProvider, apiKey: String, session: URLSession = .shared) async throws -> [String] {
        guard let base = provider.validatedBaseURL else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.notConfigured }
        switch provider.apiProtocol {
        case .openAI:
            return try await OpenAICompatibleClient(baseURL: base, model: "", apiKey: key, session: session).listModels()
        case .anthropic:
            return try await AnthropicClient(baseURL: base, model: "", apiKey: key, session: session).listModels()
        }
    }
}
