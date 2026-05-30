import Foundation

enum AIServiceProvider {

    static let aiEnabledKey = "ai_title_enabled"
    static let keychainAPIKey = "anthropic_api_key"

    static func currentService() -> AIService {
        let enabled = UserDefaults.standard.bool(forKey: aiEnabledKey)
        let key = KeychainService().get(keychainAPIKey) ?? ""

        if enabled, !key.isEmpty {
            return AIServiceCoordinator(
                primary: ClaudeAIService(apiKey: key),
                fallback: LocalTitleService()
            )
        }
        return AIServiceCoordinator(primary: nil, fallback: LocalTitleService())
    }
}
