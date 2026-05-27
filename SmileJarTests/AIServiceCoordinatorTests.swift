import Testing
import Foundation
@testable import SmileJar

struct StubFailingService: AIService {
    func generateTitle(text: String, context: TitleContext) async throws -> String {
        throw AIServiceError.invalidResponse
    }
}

struct StubAIService: AIService {
    let title: String
    func generateTitle(text: String, context: TitleContext) async throws -> String {
        title
    }
}

@Suite("AIServiceCoordinator")
struct AIServiceCoordinatorTests {
    let ctx = TitleContext(groupName: "微笑储蓄罐", date: Date(), hasMedia: false)

    @Test func usesPrimaryWhenSuccess() async throws {
        let coord = AIServiceCoordinator(
            primary: StubAIService(title: "AI 标题"),
            fallback: LocalTitleService()
        )
        let t = try await coord.generateTitle(text: "今天很好", context: ctx)
        #expect(t == "AI 标题")
    }

    @Test func fallsBackOnPrimaryFailure() async throws {
        let coord = AIServiceCoordinator(
            primary: StubFailingService(),
            fallback: LocalTitleService()
        )
        let t = try await coord.generateTitle(text: "今天很好", context: ctx)
        #expect(t == "今天很好")
    }

    @Test func usesFallbackWhenNoPrimary() async throws {
        let coord = AIServiceCoordinator(primary: nil, fallback: LocalTitleService())
        let t = try await coord.generateTitle(text: "下班路上看到夕阳", context: ctx)
        #expect(t == "下班路上看到夕阳")
    }
}
