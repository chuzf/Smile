import Testing
import Foundation
@testable import Smile

/// 拦截 URLSession 请求；静态状态只在本 serialized suite 内使用
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() { handler = nil; lastRequest = nil; lastBody = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite("LLMClient", .serialized)
struct LLMClientTests {
    init() { StubURLProtocol.reset() }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(StubURLProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func respond(_ status: Int, _ json: String) {
        StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    private func openAI(_ base: String = "https://api.example.com/v1/") -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: URL(string: base)!, model: "kimi-k2.6", apiKey: "sk-1",
                               session: StubURLProtocol.session())
    }

    private func anthropic(_ base: String = "https://api.anthropic.com") -> AnthropicClient {
        AnthropicClient(baseURL: URL(string: base)!, model: "claude-opus-5", apiKey: "sk-ant",
                        session: StubURLProtocol.session())
    }

    // MARK: OpenAI

    @Test func openAIBuildsRequest() async throws {
        respond(200, #"{"choices":[{"message":{"role":"assistant","content":"好"}}]}"#)
        let reply = try await openAI().complete(system: "S", user: "U")
        #expect(reply == "好")

        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try bodyJSON()
        #expect(body["model"] as? String == "kimi-k2.6")
        #expect(body["temperature"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "S"], ["role": "user", "content": "U"]])
    }

    @Test func openAIEmptyContentThrows() async {
        respond(200, #"{"choices":[{"message":{"content":null}}]}"#)
        await #expect(throws: LLMError.emptyResponse) { try await openAI().complete(system: "S", user: "U") }
    }

    @Test func statusCodesMapToErrors() async {
        respond(401, "{}")
        await #expect(throws: LLMError.unauthorized) { try await openAI().complete(system: "S", user: "U") }
        respond(403, "{}")
        await #expect(throws: LLMError.unauthorized) { try await anthropic().complete(system: "S", user: "U") }
        respond(429, "{}")
        await #expect(throws: LLMError.rateLimited) { try await openAI().complete(system: "S", user: "U") }
        respond(500, "boom")
        await #expect(throws: LLMError.http(500, "boom")) { try await anthropic().complete(system: "S", user: "U") }
    }

    @Test func networkFailureMapsToNetworkError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await openAI().complete(system: "S", user: "U")
            Issue.record("应当抛错")
        } catch let error as LLMError {
            guard case .network = error else { Issue.record("实际为 \(error)"); return }
        } catch {
            Issue.record("实际为 \(error)")
        }
    }

    // MARK: Anthropic

    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"),
        ("https://gw.example.com/api", "https://gw.example.com/api/v1/messages"),
        ("https://gw.example.com/api/v1/", "https://gw.example.com/api/v1/messages"),
        ("https://gw.example.com/api/v1/messages", "https://gw.example.com/api/v1/messages"),
    ])
    func anthropicEndpoint(base: String, expected: String) async throws {
        respond(200, #"{"content":[{"type":"text","text":"OK"}]}"#)
        _ = try await anthropic(base).complete(system: "S", user: "U")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == expected)
    }

    @Test func anthropicBuildsRequest() async throws {
        respond(200, #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"你"},{"type":"text","text":"好"}],"stop_reason":"end_turn"}"#)
        let reply = try await anthropic().complete(system: "S", user: "U")
        #expect(reply == "你好")

        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try bodyJSON()
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["max_tokens"] as? Int == 16000)
        #expect(body["system"] as? String == "S")
        #expect(body["temperature"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "U"]])
    }

    @Test func openAIFullEndpointIsNotDuplicated() async throws {
        respond(200, #"{"choices":[{"message":{"content":"好"}}]}"#)
        _ = try await openAI("https://api.example.com/v1/chat/completions").complete(system: "S", user: "U")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func openAILengthFinishThrowsTruncated() async {
        respond(200, #"{"choices":[{"message":{"content":"{\"title\":"},"finish_reason":"length"}]}"#)
        await #expect(throws: LLMError.truncated) { try await openAI().complete(system: "S", user: "U") }
    }

    @Test func anthropicGatewayAlsoSendsBearer() async throws {
        respond(200, #"{"content":[{"type":"text","text":"OK"}]}"#)
        _ = try await anthropic("https://gw.example.com/api").complete(system: "S", user: "U")
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant")
    }

    @Test func anthropicMaxTokensThrowsTruncated() async {
        respond(200, #"{"content":[{"type":"text","text":"{\"title\":"}],"stop_reason":"max_tokens"}"#)
        await #expect(throws: LLMError.truncated) { try await anthropic().complete(system: "S", user: "U") }
    }

    @Test func timeoutMapsToTimeoutError() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await #expect(throws: LLMError.timeout) { try await openAI().complete(system: "S", user: "U") }
    }

    @Test func cancelledRequestThrowsCancellationError() async {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await anthropic().complete(system: "S", user: "U") }
    }

    @Test func anthropicRefusalThrowsEmptyResponse() async {
        respond(200, #"{"content":[],"stop_reason":"refusal"}"#)
        await #expect(throws: LLMError.emptyResponse) { try await anthropic().complete(system: "S", user: "U") }
    }

    // MARK: Factory

    @Test func factoryPicksClientByProtocol() throws {
        var c = AIConfig.default
        #expect(try LLMClientFactory.make(config: c, apiKey: "sk") is OpenAICompatibleClient)
        c = c.applyingPreset(.anthropic)
        #expect(try LLMClientFactory.make(config: c, apiKey: "sk") is AnthropicClient)
    }

    @Test func factoryRejectsIncompleteConfig() {
        var c = AIConfig.default
        c.baseURL = "http://insecure.example.com"
        #expect(throws: LLMError.invalidURL) { try LLMClientFactory.make(config: c, apiKey: "sk") }
        #expect(throws: LLMError.notConfigured) { try LLMClientFactory.make(config: .default, apiKey: " ") }
        var noModel = AIConfig.default; noModel.model = ""
        #expect(throws: LLMError.notConfigured) { try LLMClientFactory.make(config: noModel, apiKey: "sk") }
    }
}
