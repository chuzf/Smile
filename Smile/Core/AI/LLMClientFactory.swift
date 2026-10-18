import Foundation

enum LLMClientFactory {
    static func make(config: AIConfig, apiKey: String, session: URLSession = .shared) throws -> LLMClient {
        guard let base = config.validatedBaseURL else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !config.trimmedModel.isEmpty else { throw LLMError.notConfigured }
        switch config.apiProtocol {
        case .openAI:
            return OpenAICompatibleClient(baseURL: base, model: config.trimmedModel, apiKey: key, session: session)
        case .anthropic:
            return AnthropicClient(baseURL: base, model: config.trimmedModel, apiKey: key, session: session)
        }
    }
}
