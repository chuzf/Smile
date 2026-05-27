import Foundation

struct AIServiceCoordinator: AIService {
    let primary: AIService?
    let fallback: AIService

    func generateTitle(text: String, context: TitleContext) async throws -> String {
        if let primary = primary {
            do {
                return try await primary.generateTitle(text: text, context: context)
            } catch {
                // 降级,不抛错
            }
        }
        return try await fallback.generateTitle(text: text, context: context)
    }
}
