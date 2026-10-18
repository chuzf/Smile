import Testing
import Foundation
@testable import Smile

final class FakeLLMClient: LLMClient {
    var reply: Result<String, Error>
    private(set) var lastSystem: String?
    private(set) var lastUser: String?

    init(_ reply: Result<String, Error>) { self.reply = reply }

    func complete(system: String, user: String) async throws -> String {
        lastSystem = system
        lastUser = user
        return try reply.get()
    }
}

@Suite("TextFormattingService")
struct TextFormattingServiceTests {
    private let input = FormattingInput(title: "嗯今天", segments: ["那个我去了公园", ""])

    private func service(_ reply: String, style: FormattingStyle = .light, prompt: String = "") -> (TextFormattingService, FakeLLMClient) {
        let client = FakeLLMClient(.success(reply))
        return (TextFormattingService(client: client, style: style, customPrompt: prompt), client)
    }

    @Test func systemPromptContainsRulesAndStyle() {
        let light = service("").0.systemPrompt
        #expect(light.contains("segments 的数量必须与输入完全相同"))
        #expect(light.contains("语气词"))
        #expect(service("", style: .formal).0.systemPrompt.contains("书面"))
        #expect(service("", style: .concise).0.systemPrompt.contains("精简"))
        #expect(service("", style: .custom, prompt: "改成诗").0.systemPrompt.contains("改成诗"))
    }

    @Test func userMessageIsJSONOfInput() throws {
        let text = TextFormattingService.userMessage(for: input)
        let decoded = try JSONDecoder().decode(FormattingInput.self, from: Data(text.utf8))
        #expect(decoded == input)
    }

    @Test func formatSendsPromptsAndParsesPlainJSON() async throws {
        let (svc, client) = service(#"{"title":"今天","segments":["我去了公园。",""]}"#)
        let result = try await svc.format(input)
        #expect(result == FormattingResult(title: "今天", segments: ["我去了公园。", ""]))
        #expect(client.lastSystem == svc.systemPrompt)
        #expect(client.lastUser == TextFormattingService.userMessage(for: input))
    }

    @Test func parsesFencedJSON() throws {
        let reply = "```json\n{\"title\":\"T\",\"segments\":[\"a\",\"\"]}\n```"
        let result = try TextFormattingService.parse(reply, expectedSegments: 2)
        #expect(result == FormattingResult(title: "T", segments: ["a", ""]))
    }

    @Test func parsesJSONWithSurroundingText() throws {
        let reply = "好的，整理如下：\n{\"title\":\"T\",\"segments\":[\"a\"]}\n希望有帮助"
        let result = try TextFormattingService.parse(reply, expectedSegments: 1)
        #expect(result.segments == ["a"])
    }

    @Test func segmentCountMismatchThrows() {
        #expect(throws: FormattingError.malformedResponse) {
            try TextFormattingService.parse(#"{"title":"T","segments":["a"]}"#, expectedSegments: 2)
        }
    }

    @Test func nonJSONThrows() {
        #expect(throws: FormattingError.malformedResponse) {
            try TextFormattingService.parse("抱歉，我无法处理", expectedSegments: 1)
        }
    }

    @Test func llmErrorIsWrapped() async {
        let client = FakeLLMClient(.failure(LLMError.rateLimited))
        let svc = TextFormattingService(client: client, style: .light, customPrompt: "")
        await #expect(throws: FormattingError.llm(.rateLimited)) { try await svc.format(input) }
    }

    @Test func userMessages() {
        #expect(FormattingError.malformedResponse.userMessage == "整理结果格式异常，请重试或换个模型")
        #expect(FormattingError.llm(.unauthorized).userMessage == LLMError.unauthorized.userMessage)
    }
}
