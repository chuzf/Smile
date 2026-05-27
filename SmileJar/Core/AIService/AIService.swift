import Foundation

struct TitleContext: Sendable {
    var groupName: String
    var date: Date
    var hasMedia: Bool
}

protocol AIService: Sendable {
    func generateTitle(text: String, context: TitleContext) async throws -> String
}

enum AIServiceError: Error {
    case noAPIKey
    case timeout
    case invalidResponse
    case network(Error)
}
