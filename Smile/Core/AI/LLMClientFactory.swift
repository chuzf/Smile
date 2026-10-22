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
}
