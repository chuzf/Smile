# AI 文字整理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 编辑器里一键把标题和正文交给用户自配的大模型（Kimi / 豆包 / Anthropic / 任意 OpenAI 或 Anthropic 兼容接口）整理，预览确认后写回，照片位置不变。

**Architecture:** `Core/AI/` 下分四层：配置（`AIConfig` + `AIConfigStore`，Key 存 Keychain）→ 网络（`LLMClient` 协议，OpenAI / Anthropic 两个实现，`LLMClientFactory` 按协议创建）→ 整理服务（`TextFormattingService` 组装 prompt、解析 JSON、校验段数）→ 编辑器（`iOSNoteEditorModel` 的 extension 生成快照并写回，视图负责按钮、遮罩、预览和错误提示）。spec：`docs/superpowers/specs/2026-10-18-ai-text-formatting-design.md`。

**Tech Stack:** SwiftUI, URLSession, Security（Keychain）, Swift Testing, XcodeGen, iOS 17+

**环境前提：** macOS + Xcode 26+。新增/删除源文件后先运行 `xcodegen generate`。`docs/` 与 `*.xcodeproj/` 在 `.gitignore` 中，但 `Smile.xcodeproj/project.pbxproj` 与 specs/plans 已被跟踪：这些文件需 `git add -f`。主工作区有一个与本功能无关、已暂存的 `PhotoLibraryPickerView.swift` 改动，**提交时不要带上它**（用 `git commit -m ... -- <路径>`，或在独立 worktree 中工作）。

**测试命令模板**（并行 worktree 必须各用各的 `-derivedDataPath`）：

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/smile-dd-<名字> \
  -only-testing:SmileTests/<SuiteStruct名> test 2>&1 | tail -30
```

---

## 文件清单

| 操作 | 路径 | 职责 | 任务 |
|------|------|------|------|
| 新增 | `Smile/Core/AI/AIConfig.swift` | 协议/预设/风格枚举、`AIConfig`、`AIConfigStore` | 1 |
| 新增 | `Smile/Core/AI/LLMClient.swift` | `LLMClient` 协议、`LLMError` + 中文文案、`LLMHTTP` 共用请求工具 | 1 |
| 新增 | `Smile/Core/AI/OpenAICompatibleClient.swift` | OpenAI 兼容实现 | 2 |
| 新增 | `Smile/Core/AI/AnthropicClient.swift` | Anthropic 兼容实现 | 2 |
| 新增 | `Smile/Core/AI/LLMClientFactory.swift` | 按配置创建 client | 2 |
| 新增 | `Smile/Core/AI/TextFormattingService.swift` | 输入/输出类型、prompt、解析 | 3 |
| 新增 | `Smile/Features/EntryEditor/iOSNoteEditorModel+Formatting.swift` | `FormattingSnapshot`、快照与写回 | 3 |
| 新增 | `Smile/Features/Settings/AISettingsView.swift` | 设置页 | 4 |
| 修改 | `Smile/Features/Settings/SettingsView.swift` | 入口 | 4 |
| 修改 | `README.md` | 功能说明 | 4 |
| 新增 | `Smile/Features/EntryEditor/FormattingPreviewSheet.swift` | 预览 sheet | 5 |
| 修改 | `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | 按钮、遮罩、弹窗、sheet | 5 |
| 新增 | `SmileTests/AIConfigTests.swift` | | 2 |
| 新增 | `SmileTests/LLMClientTests.swift` | | 2 |
| 新增 | `SmileTests/TextFormattingServiceTests.swift` | | 3 |
| 新增 | `SmileTests/iOSNoteEditorModelFormattingTests.swift` | | 3 |

**并行关系：** 任务 1 先做；任务 2、3 互不依赖，可并行；任务 4、5 依赖 2、3，彼此不依赖，可并行；任务 6 收尾。

---

### Task 1: 共用基础类型（配置 + LLMClient 协议）

**Files:**
- Create: `Smile/Core/AI/AIConfig.swift`
- Create: `Smile/Core/AI/LLMClient.swift`

- [ ] **Step 1: 写 `AIConfig.swift`**

```swift
import Foundation

enum AIProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI, anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Anthropic 兼容"
        }
    }
}

enum AIPreset: String, Codable, CaseIterable, Identifiable {
    case kimi, doubao, anthropic, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .doubao: return "豆包"
        case .anthropic: return "Anthropic"
        case .custom: return "自定义"
        }
    }

    /// 选中预设时填入的协议、地址和默认模型；自定义返回 nil，保留用户已填写的值
    var defaults: (apiProtocol: AIProtocol, baseURL: String, model: String)? {
        switch self {
        case .kimi: return (.openAI, "https://api.moonshot.cn/v1", "kimi-k2.6")
        case .doubao: return (.openAI, "https://ark.cn-beijing.volces.com/api/v3", "")
        case .anthropic: return (.anthropic, "https://api.anthropic.com", "claude-opus-5")
        case .custom: return nil
        }
    }
}

enum FormattingStyle: String, Codable, CaseIterable, Identifiable {
    case light, formal, concise, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "轻度润色"
        case .formal: return "书面化"
        case .concise: return "精简"
        case .custom: return "自定义"
        }
    }
}

struct AIConfig: Codable, Equatable {
    var preset: AIPreset
    var apiProtocol: AIProtocol
    var baseURL: String
    var model: String
    var style: FormattingStyle
    var customPrompt: String

    static var `default`: AIConfig {
        AIConfig(preset: .custom, apiProtocol: .openAI, baseURL: "", model: "",
                 style: .light, customPrompt: "")
            .applyingPreset(.kimi)
    }

    func applyingPreset(_ preset: AIPreset) -> AIConfig {
        var config = self
        config.preset = preset
        if let d = preset.defaults {
            config.apiProtocol = d.apiProtocol
            config.baseURL = d.baseURL
            config.model = d.model
        }
        return config
    }

    /// 只接受 https 地址
    var validatedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    func isComplete(apiKey: String?) -> Bool {
        guard validatedBaseURL != nil, !trimmedModel.isEmpty,
              let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return false }
        if style == .custom && customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }
}

/// 配置存 UserDefaults，API Key 只存 Keychain
struct AIConfigStore {
    static let configKey = "ai_config"
    static let apiKeyAccount = "ai_api_key"

    let defaults: UserDefaults
    let keychain: KeychainService

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func load() -> AIConfig {
        guard let data = defaults.data(forKey: Self.configKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else { return .default }
        return config
    }

    func save(_ config: AIConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.configKey)
    }

    func loadAPIKey() -> String? {
        guard let key = keychain.get(Self.apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// 传入空字符串表示清除
    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(Self.apiKeyAccount)
        } else {
            try keychain.set(Self.apiKeyAccount, value: trimmed)
        }
    }

    var isConfigured: Bool { load().isComplete(apiKey: loadAPIKey()) }
}
```

- [ ] **Step 2: 写 `LLMClient.swift`**

```swift
import Foundation

protocol LLMClient {
    func complete(system: String, user: String) async throws -> String
}

enum LLMError: Error, Equatable {
    case notConfigured
    case invalidURL
    case network(String)        // URLError 描述
    case unauthorized           // 401 / 403
    case rateLimited            // 429
    case http(Int, String)      // 其他非 2xx，附响应体前 200 字符
    case emptyResponse
}

extension LLMError {
    var userMessage: String {
        switch self {
        case .notConfigured, .invalidURL: return "AI 整理配置不完整，请到设置中检查"
        case .network: return "网络连接失败，请检查网络"
        case .unauthorized: return "API Key 无效或无权限，请到设置中检查"
        case .rateLimited: return "请求过于频繁或额度不足，请稍后再试"
        case .http(let code, _): return "服务返回错误（状态码 \(code)）"
        case .emptyResponse: return "整理结果格式异常，请重试或换个模型"
        }
    }
}

/// 两种协议共用的请求构造与发送
enum LLMHTTP {
    /// Opus 5 默认开启思考，耗时较长
    static let timeout: TimeInterval = 120

    /// 去掉末尾所有的 /
    static func trimmedBase(_ base: URL) -> String {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func makeRequest(url: URL, headers: [String: String], body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// 非 2xx 映射为 LLMError；任务取消时抛 CancellationError
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.emptyResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw LLMError.unauthorized
        case 429: throw LLMError.rateLimited
        default:
            throw LLMError.http(http.statusCode, String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
    }
}
```

- [ ] **Step 3: 编译**

Run: `xcodegen generate && xcodebuild -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/smile-dd-main build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add Smile/Core/AI/AIConfig.swift Smile/Core/AI/LLMClient.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: AI 整理的配置与 LLMClient 基础类型" -- Smile/Core/AI Smile.xcodeproj/project.pbxproj
```

---

### Task 2: 两种协议的 client、工厂与测试

**Files:**
- Create: `Smile/Core/AI/OpenAICompatibleClient.swift`
- Create: `Smile/Core/AI/AnthropicClient.swift`
- Create: `Smile/Core/AI/LLMClientFactory.swift`
- Test: `SmileTests/AIConfigTests.swift`, `SmileTests/LLMClientTests.swift`

- [ ] **Step 1: 写 `SmileTests/AIConfigTests.swift`**

```swift
import Testing
import Foundation
@testable import Smile

@Suite("AIConfig", .serialized)
struct AIConfigTests {
    private static let suiteName = "com.smilejar.test.aiconfig"

    private func makeStore() -> (AIConfigStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        let keychain = KeychainService(service: "com.smilejar.test.ai")
        try? keychain.delete(AIConfigStore.apiKeyAccount)
        return (AIConfigStore(defaults: defaults, keychain: keychain), defaults)
    }

    private func complete() -> AIConfig {
        var c = AIConfig.default
        c.baseURL = "https://api.example.com/v1"
        c.model = "m"
        return c
    }

    @Test func defaultIsKimiLight() {
        let c = AIConfig.default
        #expect(c.preset == .kimi)
        #expect(c.apiProtocol == .openAI)
        #expect(c.baseURL == "https://api.moonshot.cn/v1")
        #expect(c.model == "kimi-k2.6")
        #expect(c.style == .light)
    }

    @Test func loadReturnsDefaultWhenNothingSaved() {
        let (store, _) = makeStore()
        #expect(store.load() == .default)
    }

    @Test func saveAndLoadRoundTrip() {
        let (store, _) = makeStore()
        var c = AIConfig.default.applyingPreset(.custom)
        c.apiProtocol = .anthropic
        c.baseURL = "https://gw.example.com/api"
        c.model = "claude-opus-5"
        c.style = .custom
        c.customPrompt = "改成诗"
        store.save(c)
        #expect(store.load() == c)
    }

    @Test func applyingPresetFillsDefaults() {
        let c = AIConfig.default.applyingPreset(.anthropic)
        #expect(c.preset == .anthropic)
        #expect(c.apiProtocol == .anthropic)
        #expect(c.baseURL == "https://api.anthropic.com")
        #expect(c.model == "claude-opus-5")

        let d = AIConfig.default.applyingPreset(.doubao)
        #expect(d.apiProtocol == .openAI)
        #expect(d.baseURL == "https://ark.cn-beijing.volces.com/api/v3")
        #expect(d.model == "")
    }

    @Test func applyingCustomKeepsExistingFields() {
        let c = AIConfig.default.applyingPreset(.custom)
        #expect(c.preset == .custom)
        #expect(c.baseURL == AIConfig.default.baseURL)
        #expect(c.model == AIConfig.default.model)
    }

    @Test func isCompleteRequiresHttpsModelAndKey() {
        #expect(complete().isComplete(apiKey: "sk"))
        #expect(!complete().isComplete(apiKey: nil))
        #expect(!complete().isComplete(apiKey: "   "))

        var http = complete(); http.baseURL = "http://api.example.com/v1"
        #expect(!http.isComplete(apiKey: "sk"))

        var garbage = complete(); garbage.baseURL = "not a url"
        #expect(!garbage.isComplete(apiKey: "sk"))

        var noModel = complete(); noModel.model = "  "
        #expect(!noModel.isComplete(apiKey: "sk"))
    }

    @Test func customStyleRequiresPrompt() {
        var c = complete(); c.style = .custom; c.customPrompt = " "
        #expect(!c.isComplete(apiKey: "sk"))
        c.customPrompt = "改成诗"
        #expect(c.isComplete(apiKey: "sk"))
    }

    @Test func apiKeyStoredInKeychainNotDefaults() throws {
        let (store, defaults) = makeStore()
        try store.saveAPIKey("  sk-secret  ")
        #expect(store.loadAPIKey() == "sk-secret")
        let leaked = defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "sk-secret" }
        #expect(!leaked)

        try store.saveAPIKey("")
        #expect(store.loadAPIKey() == nil)
    }

    @Test func isConfiguredReflectsStoredConfigAndKey() throws {
        let (store, _) = makeStore()
        store.save(complete())
        #expect(!store.isConfigured)
        try store.saveAPIKey("sk")
        #expect(store.isConfigured)
        try store.saveAPIKey("")
    }
}
```

- [ ] **Step 2: 写 `SmileTests/LLMClientTests.swift`**

```swift
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
```

- [ ] **Step 3: 运行，确认失败**

Run: 测试命令模板，`-only-testing:SmileTests/LLMClientTests -only-testing:SmileTests/AIConfigTests`
Expected: 编译失败，`cannot find 'OpenAICompatibleClient' in scope`。

- [ ] **Step 4: 写 `OpenAICompatibleClient.swift`**

```swift
import Foundation

/// OpenAI Chat Completions 兼容接口（Kimi、豆包方舟及多数第三方网关）
struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    // 不传 temperature：部分网关会把请求转给不接受采样参数的 Claude 模型
    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct ChoiceMessage: Decodable { let content: String? }
            let message: ChoiceMessage
        }
        let choices: [Choice]
    }

    func complete(system: String, user: String) async throws -> String {
        guard let url = URL(string: LLMHTTP.trimmedBase(baseURL) + "/chat/completions") else {
            throw LLMError.invalidURL
        }
        let body = RequestBody(model: model, messages: [
            Message(role: "system", content: system),
            Message(role: "user", content: user),
        ])
        let request = try LLMHTTP.makeRequest(url: url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        let data = try await LLMHTTP.send(request, session: session)
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LLMError.emptyResponse }
        return content
    }
}
```

- [ ] **Step 5: 写 `AnthropicClient.swift`**

```swift
import Foundation

/// Anthropic Messages 兼容接口（Anthropic 官方及 moacode 等网关）
struct AnthropicClient: LLMClient {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16000

    let baseURL: URL
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    // 不传 temperature / thinking：Opus 4.7+、Opus 5、Sonnet 5 对采样参数返回 400
    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    /// base 已以 /v1 结尾时只拼 /messages
    var endpoint: URL? {
        let base = LLMHTTP.trimmedBase(baseURL)
        return URL(string: base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages")
    }

    func complete(system: String, user: String) async throws -> String {
        guard let url = endpoint else { throw LLMError.invalidURL }
        let body = RequestBody(model: model, maxTokens: Self.maxTokens, system: system,
                               messages: [Message(role: "user", content: user)])
        let request = try LLMHTTP.makeRequest(
            url: url,
            headers: ["x-api-key": apiKey, "anthropic-version": Self.apiVersion],
            body: body
        )
        let data = try await LLMHTTP.send(request, session: session)
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMError.emptyResponse
        }
        // 只取 text 块，忽略 thinking 等；refusal 时 content 为空
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
```

- [ ] **Step 6: 写 `LLMClientFactory.swift`**

```swift
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
```

- [ ] **Step 7: 运行测试，确认通过**

Run: 同 Step 3
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 8: 提交**

```bash
git add Smile/Core/AI SmileTests/AIConfigTests.swift SmileTests/LLMClientTests.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: OpenAI / Anthropic 兼容的 LLM client 与工厂" -- Smile/Core/AI SmileTests Smile.xcodeproj/project.pbxproj
```

---

### Task 3: 整理服务与编辑器模型写回

**Files:**
- Create: `Smile/Core/AI/TextFormattingService.swift`
- Create: `Smile/Features/EntryEditor/iOSNoteEditorModel+Formatting.swift`
- Test: `SmileTests/TextFormattingServiceTests.swift`, `SmileTests/iOSNoteEditorModelFormattingTests.swift`

- [ ] **Step 1: 写 `SmileTests/TextFormattingServiceTests.swift`**

```swift
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
```

- [ ] **Step 2: 写 `SmileTests/iOSNoteEditorModelFormattingTests.swift`**

```swift
import Testing
import Foundation
import SwiftUI
@testable import Smile

@Suite("iOSNoteEditorModel formatting")
struct iOSNoteEditorModelFormattingTests {
    private let a = UUID()
    private let b = UUID()
    private let photo = DraftAttachment(persistedID: nil, kind: .photo, relativePath: "p.jpg",
                                        transcript: nil, durationSeconds: nil)

    private func makeModel() -> iOSNoteEditorModel {
        let model = iOSNoteEditorModel()
        model.segments = [
            .text(id: a, content: "嗯标题\n那个正文一", alignment: .leading),
            .photo(photo),
            .text(id: b, content: "正文二", alignment: .center),
        ]
        model.isDirty = false
        return model
    }

    @Test func snapshotSplitsTitleAndSegments() throws {
        let snap = try #require(makeModel().formattingSnapshot())
        #expect(snap.input == FormattingInput(title: "嗯标题", segments: ["那个正文一", "正文二"]))
        #expect(snap.textSegmentIDs == [a, b])
        #expect(snap.layout == [.text(0), .photo, .text(1)])
    }

    @Test func snapshotNilWithoutText() {
        let model = iOSNoteEditorModel()
        model.segments = [.photo(photo)]
        #expect(model.formattingSnapshot() == nil)
        #expect(!model.canFormat)
    }

    @Test func canFormatRequiresNonBlankText() {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "  \n  ", alignment: .leading)]
        #expect(!model.canFormat)
        model.segments = [.text(id: a, content: "有字", alignment: .leading)]
        #expect(model.canFormat)
    }

    @Test func applyKeepsPhotoAndAlignment() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        let ok = model.applyFormatting(FormattingResult(title: "标题", segments: ["正文一。", "正文二。"]), to: snap)
        #expect(ok)
        #expect(model.isDirty)
        #expect(model.textContent(for: a) == "标题\n正文一。")
        #expect(model.segments[1].id == photo.id)
        guard case .text(let id, let content, let alignment) = model.segments[2] else {
            Issue.record("第三段应为文字"); return
        }
        #expect(id == b)
        #expect(content == "正文二。")
        #expect(alignment == .center)
    }

    @Test func applyWithEmptyFirstBodyHasNoTrailingNewline() throws {
        let model = iOSNoteEditorModel()
        model.segments = [.text(id: a, content: "嗯标题", alignment: .leading)]
        let snap = try #require(model.formattingSnapshot())
        #expect(snap.input == FormattingInput(title: "嗯标题", segments: [""]))
        #expect(model.applyFormatting(FormattingResult(title: "标题", segments: [""]), to: snap))
        #expect(model.textContent(for: a) == "标题")
    }

    @Test func applyReplacesNewlinesInTitle() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.applyFormatting(FormattingResult(title: "第一行\n第二行", segments: ["x", "y"]), to: snap)
        #expect(model.textContent(for: a) == "第一行 第二行\nx")
    }

    @Test func applyRejectsMismatchedCount() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        #expect(!model.applyFormatting(FormattingResult(title: "T", segments: ["x"]), to: snap))
        #expect(model.textContent(for: a) == "嗯标题\n那个正文一")
        #expect(!model.isDirty)
    }

    @Test func applyRejectsMissingSegment() throws {
        let model = makeModel()
        let snap = try #require(model.formattingSnapshot())
        model.segments.removeLast()
        #expect(!model.applyFormatting(FormattingResult(title: "T", segments: ["x", "y"]), to: snap))
        #expect(model.textContent(for: a) == "嗯标题\n那个正文一")
    }
}
```

- [ ] **Step 3: 运行，确认失败**

Run: 测试命令模板，`-only-testing:SmileTests/TextFormattingServiceTests -only-testing:SmileTests/iOSNoteEditorModelFormattingTests`
Expected: 编译失败，`cannot find 'FormattingInput' in scope`。

- [ ] **Step 4: 写 `TextFormattingService.swift`**

```swift
import Foundation

struct FormattingInput: Codable, Equatable {
    var title: String
    var segments: [String]      // 正文文字段，按编辑器顺序
}

struct FormattingResult: Codable, Equatable {
    var title: String
    var segments: [String]
}

enum FormattingError: Error, Equatable {
    case llm(LLMError)
    case malformedResponse      // 解析失败或段数不符
}

extension FormattingError {
    var userMessage: String {
        switch self {
        case .llm(let error): return error.userMessage
        case .malformedResponse: return "整理结果格式异常，请重试或换个模型"
        }
    }
}

struct TextFormattingService {
    let client: LLMClient
    let style: FormattingStyle
    let customPrompt: String

    func format(_ input: FormattingInput) async throws -> FormattingResult {
        let reply: String
        do {
            reply = try await client.complete(system: systemPrompt, user: Self.userMessage(for: input))
        } catch let error as LLMError {
            throw FormattingError.llm(error)
        }
        return try Self.parse(reply, expectedSegments: input.segments.count)
    }

    var systemPrompt: String {
        [Self.baseRules, styleInstruction, Self.outputFormat].joined(separator: "\n\n")
    }

    private var styleInstruction: String {
        switch style {
        case .light:
            return "整理要求（轻度润色）：" + Self.lightRules
        case .formal:
            return "整理要求（书面化）：先" + Self.lightRules + "再把口语化的表达改为通顺、自然的书面表达。保留全部事实和细节，不添加评论或总结。"
        case .concise:
            return "整理要求（精简）：先" + Self.lightRules + "再删去冗余、绕弯的表述，让文字更简洁。保留关键事实和情感，不添加评论或总结。"
        case .custom:
            return "整理要求：\n" + customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let lightRules = "去掉语气词（如「嗯」「啊」「呃」「那个」「就是说」）、口头禅和无意义的重复；补全标点，必要时在段内合理换行；改正错别字。保留原意、所有细节和第一人称口吻，不增删事实，不添加评论或总结。"

    private static let baseRules = """
    你是文字整理助手。用户会给你一条生活记录的标题和若干段正文（JSON），请按「整理要求」整理文字。
    规则：
    1. 输出语言与原文保持一致。
    2. 只输出一个 JSON 对象，不要输出任何解释、前后缀或 Markdown 代码块。
    3. segments 的数量必须与输入完全相同，顺序一一对应；不得合并、拆分、增加或删除段落。
    4. 输入中为空字符串的段，输出也必须是空字符串。
    5. 标题只有一行。输入的标题为空时，根据正文拟一个不超过 20 个字的标题；标题和正文都没有实质内容时，标题保持为空字符串。
    """

    private static let outputFormat = """
    输出格式：
    {"title": "整理后的标题", "segments": ["整理后的第 1 段", "整理后的第 2 段"]}
    """

    static func userMessage(for input: FormattingInput) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(input)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 兼容 ```json 代码块包裹、前后夹杂说明文字的回复
    static func parse(_ reply: String, expectedSegments: Int) throws -> FormattingResult {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            } else {
                text = ""
            }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let result = decode(text) ?? extractObject(from: text).flatMap(decode),
              result.segments.count == expectedSegments
        else { throw FormattingError.malformedResponse }
        return result
    }

    private static func decode(_ text: String) -> FormattingResult? {
        try? JSONDecoder().decode(FormattingResult.self, from: Data(text.utf8))
    }

    private static func extractObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}
```

- [ ] **Step 5: 写 `iOSNoteEditorModel+Formatting.swift`**

```swift
import Foundation

/// 发起整理时的文字快照；写回时按 id 对应，照片和对齐方式不参与
struct FormattingSnapshot: Equatable {
    let input: FormattingInput
    let textSegmentIDs: [UUID]   // 与 input.segments 一一对应；[0] 是承载标题的首个文字段
    let layout: [Block]          // 文字段与照片的排列，供预览显示照片占位

    enum Block: Equatable { case text(Int), photo }
}

extension iOSNoteEditorModel {
    func formattingSnapshot() -> FormattingSnapshot? {
        var title = ""
        var parts: [String] = []
        var ids: [UUID] = []
        var layout: [FormattingSnapshot.Block] = []
        for seg in segments {
            switch seg {
            case .text(let id, let content, _):
                if ids.isEmpty {
                    // 与 extractTitle() 一致：首个文字段的第一行是标题
                    let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    title = lines.first.map(String.init) ?? ""
                    parts.append(lines.count > 1 ? String(lines[1]) : "")
                } else {
                    parts.append(content)
                }
                layout.append(.text(ids.count))
                ids.append(id)
            case .photo:
                layout.append(.photo)
            }
        }
        guard !ids.isEmpty else { return nil }
        return FormattingSnapshot(input: FormattingInput(title: title, segments: parts),
                                  textSegmentIDs: ids, layout: layout)
    }

    var canFormat: Bool {
        guard let input = formattingSnapshot()?.input else { return false }
        return ([input.title] + input.segments).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 段数不符或快照里的文字段已不存在时不做任何修改，返回 false
    @discardableResult
    func applyFormatting(_ result: FormattingResult, to snapshot: FormattingSnapshot) -> Bool {
        guard result.segments.count == snapshot.textSegmentIDs.count else { return false }
        let currentIDs = Set(segments.compactMap { seg -> UUID? in
            if case .text(let id, _, _) = seg { return id } else { return nil }
        })
        guard snapshot.textSegmentIDs.allSatisfy(currentIDs.contains) else { return false }

        let title = result.title.replacingOccurrences(of: "\n", with: " ")
        for (index, id) in snapshot.textSegmentIDs.enumerated() {
            let body = result.segments[index]
            let content = index == 0 ? (body.isEmpty ? title : title + "\n" + body) : body
            updateText(content, for: id)
        }
        isDirty = true
        return true
    }
}
```

- [ ] **Step 6: 运行测试，确认通过**

Run: 同 Step 3
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: 提交**

```bash
git add Smile/Core/AI/TextFormattingService.swift Smile/Features/EntryEditor/iOSNoteEditorModel+Formatting.swift SmileTests/TextFormattingServiceTests.swift SmileTests/iOSNoteEditorModelFormattingTests.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: AI 整理服务与编辑器快照写回" -- Smile/Core/AI Smile/Features/EntryEditor SmileTests Smile.xcodeproj/project.pbxproj
```

---

### Task 4: 设置页、入口与 README

**Files:**
- Create: `Smile/Features/Settings/AISettingsView.swift`
- Modify: `Smile/Features/Settings/SettingsView.swift`（`Form {` 内、`Section("数据")` 之前）
- Modify: `README.md`

- [ ] **Step 1: 写 `AISettingsView.swift`**

```swift
import SwiftUI

struct AISettingsView: View {
    private let store = AIConfigStore()

    @State private var config = AIConfig.default
    @State private var loaded = false
    @State private var hasSavedKey = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("服务商") {
                Picker("服务商", selection: presetBinding) {
                    ForEach(AIPreset.allCases) { Text($0.displayName).tag($0) }
                }
                if config.preset == .custom {
                    Picker("接口协议", selection: $config.apiProtocol) {
                        ForEach(AIProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                TextField("接口地址", text: $config.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !config.baseURL.isEmpty && config.validatedBaseURL == nil {
                    Text("请填写以 https:// 开头的地址").font(.footnote).foregroundStyle(.red)
                }
                TextField("模型", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if config.preset == .doubao {
                    Text("填写方舟控制台中的模型 ID 或接入点 ID").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("API Key") {
                SecureField(hasSavedKey ? "已保存（输入新值可覆盖）" : "粘贴 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKeyIfNeeded)
                if hasSavedKey {
                    Button("清除 Key", role: .destructive, action: clearKey)
                }
                if let keyError {
                    Text(keyError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("整理风格") {
                Picker("风格", selection: $config.style) {
                    ForEach(FormattingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                if config.style == .custom {
                    TextEditor(text: $config.customPrompt)
                        .frame(minHeight: 120)
                }
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        testStatusView
                    }
                }
                .disabled(testState == .testing)
            } footer: {
                Text("整理时会把标题和正文文字发送给你配置的服务商，不发送照片、视频和语音。API Key 仅保存在本机钥匙串。")
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            config = store.load()
            hasSavedKey = store.loadAPIKey() != nil
        }
        .onChange(of: config) { _, newValue in
            store.save(newValue)
            testState = .idle
        }
        .onDisappear(perform: saveKeyIfNeeded)
    }

    private var presetBinding: Binding<AIPreset> {
        Binding(
            get: { config.preset },
            set: { config = config.applyingPreset($0) }
        )
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failure(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    private func saveKeyIfNeeded() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.saveAPIKey(trimmed)
            keyInput = ""
            hasSavedKey = true
            keyError = nil
        } catch {
            keyError = "API Key 保存失败，请重试"
        }
    }

    private func clearKey() {
        do {
            try store.saveAPIKey("")
            keyInput = ""
            hasSavedKey = false
            keyError = nil
        } catch {
            keyError = "清除失败，请重试"
        }
    }

    @MainActor
    private func testConnection() async {
        saveKeyIfNeeded()
        guard let key = store.loadAPIKey(), config.isComplete(apiKey: key) else {
            testState = .failure(LLMError.notConfigured.userMessage)
            return
        }
        testState = .testing
        do {
            let client = try LLMClientFactory.make(config: config, apiKey: key)
            _ = try await client.complete(system: "只回复 OK", user: "ping")
            testState = .success
        } catch let error as LLMError {
            testState = .failure(error.userMessage)
        } catch {
            testState = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
    }
}
```

- [ ] **Step 2: `SettingsView.swift` 加入口**

在 `Form {` 后、`Section("数据") {` 之前插入：

```swift
            Section("AI") {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label("AI 整理", systemImage: "wand.and.stars")
                }
            }
```

- [ ] **Step 3: 更新 `README.md`**

用 Edit 精确替换三处：
1. `- 可选 AI 自动标题(Claude Haiku 4.5,需自备 API Key)` → `- 可选 **AI 整理**：把标题和正文交给大模型，去掉语气词、口头禅并润色（支持 Kimi、豆包、Anthropic 及任意 OpenAI / Anthropic 兼容接口，需自备 API Key）`
2. `- Anthropic API(可选)` → `- 大模型 API（可选，OpenAI / Anthropic 兼容协议）`
3. 把 `## 配置 AI 自动标题(可选)` 整节（到 `## 项目结构` 之前）替换为：

```markdown
## 配置 AI 整理(可选)

1. App 内进入"我 → App 设置 → AI 整理"
2. 选择服务商：Kimi / 豆包 / Anthropic 会自动填好接口地址；moacode 等第三方网关选"自定义"，再选 OpenAI 兼容或 Anthropic 兼容协议并填写地址
3. 填写模型名（豆包填方舟模型 ID 或接入点 ID）和 API Key，点击"测试连接"
4. 编辑记录时点工具栏"整理"，预览确认后点"替换"

API Key 存于设备 Keychain，不离开本机。整理只发送标题和正文文字，**不发送照片/视频/语音**。

```

- [ ] **Step 4: 编译**

Run: `xcodegen generate && xcodebuild -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/smile-dd-<名字> build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add Smile/Features/Settings/AISettingsView.swift Smile/Features/Settings/SettingsView.swift README.md
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: AI 整理设置页" -- Smile/Features/Settings README.md Smile.xcodeproj/project.pbxproj
```

---

### Task 5: 预览 sheet 与编辑器接入

**Files:**
- Create: `Smile/Features/EntryEditor/FormattingPreviewSheet.swift`
- Modify: `Smile/Features/EntryEditor/iOSNoteEditorView.swift`

- [ ] **Step 1: 写 `FormattingPreviewSheet.swift`**

```swift
import SwiftUI

struct FormattingPreview: Identifiable {
    let id = UUID()
    let snapshot: FormattingSnapshot
    let result: FormattingResult
}

struct FormattingPreviewSheet: View {
    let preview: FormattingPreview
    let onReplace: () -> Void
    let onCancel: () -> Void

    @State private var showOriginal = false

    private var title: String { showOriginal ? preview.snapshot.input.title : preview.result.title }
    private var segments: [String] { showOriginal ? preview.snapshot.input.segments : preview.result.segments }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $showOriginal) {
                    Text("整理后").tag(false)
                    Text("原文").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title.isEmpty ? "（无标题）" : title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(title.isEmpty ? AppColors.textSecondary : AppColors.textPrimary)
                        ForEach(Array(preview.snapshot.layout.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .background(AppColors.backgroundGradient.ignoresSafeArea())
            .navigationTitle("整理结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("替换", action: onReplace).fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: FormattingSnapshot.Block) -> some View {
        switch block {
        case .text(let index):
            if !segments[index].isEmpty {
                Divider()
                Text(segments[index])
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .photo:
            Divider()
            Text("［照片］")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
```

- [ ] **Step 2: 编辑器加状态**

在 `iOSNoteEditorView` 的 `@FocusState private var focusedSegmentID: UUID?` 之前加：

```swift
    @State private var isFormatting = false
    @State private var formattingTask: Task<Void, Never>?
    @State private var formattingPreview: FormattingPreview?
    @State private var formattingErrorMessage: String?
    @State private var showAISetupAlert = false
    @State private var showAISettings = false
```

- [ ] **Step 3: body 加遮罩和修饰符**

`body` 的 `ZStack` 里，在 `VStack(spacing: 0) { ... }` 之后（`ZStack` 的闭合 `}` 之前）加：

```swift
            if isFormatting {
                formattingOverlay
            }
```

在 `.shareHandling(self)` 下一行加：

```swift
        .formattingHandling(self)
```

在 `.onDisappear {` 闭包的第一行加：

```swift
            formattingTask?.cancel()
```

- [ ] **Step 4: 工具栏按钮**

`toolbarRow` 中 `HStack(spacing: 18)` 改为 `HStack(spacing: 14)`（六个按钮放进 iPhone SE 宽度）。在「标签」按钮的 `.disabled(dictationService.isActive)` 之后、`Spacer()` 之前加：

```swift
            Button { startFormatting() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text("整理")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive || isFormatting || !model.canFormat)
```

- [ ] **Step 5: `isPresentingOther` 计入整理相关状态**

```swift
    private var isPresentingOther: Bool {
        showPhotoPicker || showCamera || showVoiceRecorder || showTagPicker ||
        showUnsavedAlert || showInsertPhotoError || showShareReadError || showSaveError || dictationError != nil ||
        isFormatting || formattingPreview != nil || formattingErrorMessage != nil || showAISetupAlert || showAISettings
    }
```

- [ ] **Step 6: 遮罩与整理流程**

在 `// MARK: - Helpers` 之前加：

```swift
    // MARK: - AI 整理

    private var formattingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.warmOrange)
                Text("整理中…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Button("取消") { cancelFormatting() }
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.warmOrange)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func startFormatting() {
        let store = AIConfigStore()
        let config = store.load()
        guard let apiKey = store.loadAPIKey(), config.isComplete(apiKey: apiKey) else {
            showAISetupAlert = true
            return
        }
        guard let snapshot = model.formattingSnapshot() else { return }
        let client: LLMClient
        do {
            client = try LLMClientFactory.make(config: config, apiKey: apiKey)
        } catch {
            formattingErrorMessage = (error as? LLMError ?? .notConfigured).userMessage
            return
        }
        let service = TextFormattingService(client: client, style: config.style, customPrompt: config.customPrompt)
        focusedSegmentID = nil
        isFormatting = true
        formattingTask = Task { @MainActor in
            do {
                let result = try await service.format(snapshot.input)
                guard !Task.isCancelled else { return }
                formattingPreview = FormattingPreview(snapshot: snapshot, result: result)
            } catch let error as FormattingError {
                if !Task.isCancelled { formattingErrorMessage = error.userMessage }
            } catch {
                // CancellationError：用户已取消，不提示
                if !Task.isCancelled && !(error is CancellationError) {
                    formattingErrorMessage = LLMError.network(error.localizedDescription).userMessage
                }
            }
            // 取消时 cancelFormatting() 已复位，这里不能覆盖新一轮的状态
            if !Task.isCancelled {
                isFormatting = false
                formattingTask = nil
            }
        }
    }

    private func cancelFormatting() {
        formattingTask?.cancel()
        formattingTask = nil
        isFormatting = false
    }

    fileprivate func applyFormattingPreview(_ preview: FormattingPreview) {
        formattingPreview = nil
        guard model.applyFormatting(preview.result, to: preview.snapshot) else {
            Task {
                // 等 sheet 退场后再弹提示
                try? await Task.sleep(for: .milliseconds(350))
                formattingErrorMessage = "内容已变化，未能替换，请重新整理。"
            }
            return
        }
    }
```

- [ ] **Step 7: 弹窗与 sheet 放进独立修饰符（避免 body 类型检查超时）**

在文件末尾 `applyShareHandling` 所在 extension 之后追加：

```swift
// MARK: - AI 整理相关的弹窗与 sheet（拆出 body，避免修饰符链过长导致类型检查超时）

private extension View {
    func formattingHandling(_ editor: iOSNoteEditorView) -> some View {
        editor.applyFormattingHandling(to: self)
    }
}

extension iOSNoteEditorView {
    fileprivate func applyFormattingHandling<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $formattingPreview) { preview in
                FormattingPreviewSheet(preview: preview) {
                    applyFormattingPreview(preview)
                } onCancel: {
                    formattingPreview = nil
                }
            }
            .sheet(isPresented: $showAISettings) {
                NavigationStack {
                    AISettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showAISettings = false }
                            }
                        }
                }
            }
            .alert("尚未配置 AI 整理", isPresented: $showAISetupAlert) {
                Button("去设置") { showAISettings = true }
                Button("取消", role: .cancel) { }
            } message: {
                Text("请先填写服务商、模型和 API Key。")
            }
            .alert("整理失败", isPresented: Binding(
                get: { formattingErrorMessage != nil },
                set: { if !$0 { formattingErrorMessage = nil } }
            )) {
                Button("好的", role: .cancel) { formattingErrorMessage = nil }
            } message: {
                Text(formattingErrorMessage ?? "")
            }
    }
}
```

- [ ] **Step 8: 编译并跑全部测试**

Run: `xcodegen generate && xcodebuild -project Smile.xcodeproj -scheme Smile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/smile-dd-<名字> test 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`（若有与本任务无关的既有失败，记录下来，不要改）

- [ ] **Step 9: 提交**

```bash
git add Smile/Features/EntryEditor/FormattingPreviewSheet.swift Smile/Features/EntryEditor/iOSNoteEditorView.swift
git add -f Smile.xcodeproj/project.pbxproj
git commit -m "feat: 编辑器接入 AI 整理（按钮、遮罩、预览替换）" -- Smile/Features/EntryEditor Smile.xcodeproj/project.pbxproj
```

---

### Task 6: 收尾验证

- [ ] **Step 1:** 合并全部分支后 `xcodegen generate`，跑全部测试，确认 `** TEST SUCCEEDED **`。
- [ ] **Step 2:** 模拟器手动检查：
  - 设置页切换预设，地址和模型会自动填入
  - 填 http 地址时出现红字提示
  - Key 保存后显示「已保存」，清除后恢复原状
  - 未配置时点「整理」弹出「去设置」，能打开设置页
  - 配置好以后：整理中遮罩可取消；预览能切换原文；替换后照片位置和居中对齐不变
- [ ] **Step 3:** 用 superpowers:requesting-code-review 做一次评审。
