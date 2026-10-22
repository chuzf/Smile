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
        #expect(body["output_config"] as? [String: String] == ["effort": "low"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "U"]])
    }

    @Test func anthropicOmitsEffortForModelsWithoutIt() async throws {
        respond(200, #"{"content":[{"type":"text","text":"OK"}]}"#)
        let client = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-haiku-4-5",
                                     apiKey: "sk-ant", session: StubURLProtocol.session())
        _ = try await client.complete(system: "S", user: "U")
        #expect(try bodyJSON()["output_config"] == nil)
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

    @Test func cancelledTaskThrowsCancellationError() async {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let client = anthropic()
        let task = Task { try await client.complete(system: "S", user: "U") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func systemCancelledWithoutTaskCancellationIsNetworkError() async {
        // 任务没被取消、URLSession 自己返回 -999：要提示，不能当作用户取消
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect {
            try await anthropic().complete(system: "S", user: "U")
        } throws: { error in
            if case LLMError.network = error { return true } else { return false }
        }
    }

    @Test func anthropicRefusalThrowsEmptyResponse() async {
        respond(200, #"{"content":[],"stop_reason":"refusal"}"#)
        await #expect(throws: LLMError.emptyResponse) { try await anthropic().complete(system: "S", user: "U") }
    }

    // MARK: Factory

    @Test func factoryPicksClientByProtocol() throws {
        #expect(try LLMClientFactory.make(provider: .make(preset: .kimi), apiKey: "sk") is OpenAICompatibleClient)
        #expect(try LLMClientFactory.make(provider: .make(preset: .anthropic), apiKey: "sk") is AnthropicClient)
    }

    @Test func factoryRejectsIncompleteConfig() {
        var p = AIProvider.make(preset: .kimi)
        p.baseURL = "http://insecure.example.com"
        #expect(throws: LLMError.invalidURL) { try LLMClientFactory.make(provider: p, apiKey: "sk") }
        #expect(throws: LLMError.notConfigured) { try LLMClientFactory.make(provider: .make(preset: .kimi), apiKey: " ") }
        var noModel = AIProvider.make(preset: .kimi); noModel.model = ""
        #expect(throws: LLMError.notConfigured) { try LLMClientFactory.make(provider: noModel, apiKey: "sk") }
    }

    // MARK: Model list

    private final class Recorder {
        var urls: [URL] = []
    }

    @Test(arguments: [
        ("https://api.example.com/v1", "https://api.example.com/v1/models"),
        ("https://api.example.com/v1/", "https://api.example.com/v1/models"),
        ("https://api.example.com/v1/chat/completions", "https://api.example.com/v1/models"),
        ("https://api.example.com/v1/models", "https://api.example.com/v1/models"),
    ])
    func openAIModelsEndpoint(base: String, expected: String) {
        #expect(openAI(base).modelsEndpoint?.absoluteString == expected)
    }

    @Test func openAIListsModels() async throws {
        respond(200, #"{"object":"list","data":[{"id":"kimi-k3"},{"id":" kimi-k2.6 "},{"id":"kimi-k3"},{"id":""}]}"#)
        let models = try await openAI().listModels()
        #expect(models == ["kimi-k3", "kimi-k2.6"])
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
    }

    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/models"),
        ("https://gw.example.com/api/v1/", "https://gw.example.com/api/v1/models"),
        ("https://gw.example.com/api/v1/messages", "https://gw.example.com/api/v1/models"),
    ])
    func anthropicModelsEndpoint(base: String, expected: String) {
        #expect(anthropic(base).modelsEndpoint?.absoluteString == expected)
    }

    @Test func anthropicPagesThroughModels() async throws {
        let recorder = Recorder()
        StubURLProtocol.handler = { request in
            recorder.urls.append(request.url!)
            let page = recorder.urls.count == 1
                ? #"{"data":[{"id":"claude-opus-5"}],"has_more":true,"last_id":"claude-opus-5"}"#
                : #"{"data":[{"id":"claude-sonnet-5"}],"has_more":false,"last_id":"claude-sonnet-5"}"#
            return (200, Data(page.utf8))
        }
        let models = try await anthropic().listModels()
        #expect(models == ["claude-opus-5", "claude-sonnet-5"])
        #expect(recorder.urls.map(\.absoluteString) == [
            "https://api.anthropic.com/v1/models?limit=1000",
            "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5",
        ])
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicClient.apiVersion)
    }

    @Test func anthropicStopsAfterMaxPages() async throws {
        let recorder = Recorder()
        StubURLProtocol.handler = { request in
            recorder.urls.append(request.url!)
            return (200, Data(#"{"data":[{"id":"m"}],"has_more":true,"last_id":"m"}"#.utf8))
        }
        #expect(try await anthropic().listModels() == ["m"])
        #expect(recorder.urls.count == AnthropicClient.maxModelPages)
    }

    @Test func listModelsMapsErrors() async {
        respond(401, "{}")
        await #expect(throws: LLMError.unauthorized) { try await openAI().listModels() }
        respond(200, "not json")
        await #expect(throws: LLMError.emptyResponse) { try await openAI().listModels() }
    }

    @Test func factoryListModelsValidatesInput() async throws {
        var p = AIProvider.make(preset: .custom)   // 模型为空也能拉取
        p.baseURL = "http://insecure.example.com"
        await #expect(throws: LLMError.invalidURL) { try await LLMClientFactory.listModels(provider: p, apiKey: "sk") }
        p.baseURL = "https://api.example.com/v1"
        await #expect(throws: LLMError.notConfigured) { try await LLMClientFactory.listModels(provider: p, apiKey: " ") }
        respond(200, #"{"data":[{"id":"m1"}]}"#)
        let models = try await LLMClientFactory.listModels(provider: p, apiKey: "sk", session: StubURLProtocol.session())
        #expect(models == ["m1"])
    }

    @Test func detailedMessageAppendsHTTPBody() {
        #expect(LLMError.http(400, "bad model").detailedMessage == LLMError.http(400, "").userMessage + "\nbad model")
        #expect(LLMError.unauthorized.detailedMessage == LLMError.unauthorized.userMessage)
    }
}
