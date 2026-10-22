# 从服务商拉取模型列表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 服务商编辑页的模型可以从服务商拉取列表来选，同时保留手动填写（spec：`docs/superpowers/specs/2026-10-22-ai-model-list-design.md`）。

**Architecture:** 两个具体 client 各加 `listModels()`（OpenAI 兼容取 `/models`，Anthropic 兼容取 `/v1/models` 并分页），工厂按协议分发；新增 `ModelPickerSheet` 负责拉取与选择，编辑页模型输入框旁加「选择」按钮。

**Tech Stack:** Swift 5.10、SwiftUI（iOS 17）、Swift Testing、xcodegen

**测试命令：**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/smile-dd-main \
  -only-testing:SmileTests/LLMClientTests test 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)"
```

---

### Task 1: 拉取接口（TDD）

**Files:**
- Modify: `Smile/Core/AI/LLMClient.swift`（`LLMError` 扩展、`LLMHTTP`）
- Modify: `Smile/Core/AI/OpenAICompatibleClient.swift`、`Smile/Core/AI/AnthropicClient.swift`、`Smile/Core/AI/LLMClientFactory.swift`
- Test: `SmileTests/LLMClientTests.swift`

- [ ] **Step 1: 在 `LLMClientTests` 末尾（工厂测试之后、struct 结束之前）加测试**

```swift
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
```

- [ ] **Step 2: 跑测试，确认编译失败**（`modelsEndpoint` / `listModels` / `detailedMessage` 未定义）

- [ ] **Step 3: `LLMClient.swift`——在 `extension LLMError` 中 `userMessage` 之后加**

```swift
    /// 设置页用：http 错误附上响应体，方便排查模型名、参数等问题；响应体里不含 Key
    var detailedMessage: String {
        if case .http(_, let body) = self, !body.isEmpty { return userMessage + "\n" + body }
        return userMessage
    }
```

在 `enum LLMHTTP` 中 `makeRequest` 之后加：

```swift
    /// 列模型很快，不用等整理文字那么久
    static let modelListTimeout: TimeInterval = 30

    static func makeGetRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: modelListTimeout)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// 两种协议列模型的响应都是 data[].id；Anthropic 另有分页字段
    struct ModelPage: Decodable {
        struct Item: Decodable { let id: String }
        let data: [Item]
        let hasMore: Bool?
        let lastId: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastId = "last_id"
        }
    }

    static func decodeModelPage(_ data: Data) throws -> ModelPage {
        guard let page = try? JSONDecoder().decode(ModelPage.self, from: data) else { throw LLMError.emptyResponse }
        return page
    }

    /// 去掉首尾空白和空串，按首次出现去重，保持服务商返回的顺序
    static func normalizedModelIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
```

- [ ] **Step 4: `OpenAICompatibleClient.swift`——`complete` 之后加**

```swift
    /// 用户填了完整的 /chat/completions 端点时，换成同级的 /models
    var modelsEndpoint: URL? {
        var base = LLMHTTP.trimmedBase(baseURL)
        if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        guard let url = URL(string: base) else { return nil }
        return LLMHTTP.endpoint(url, path: "/models")
    }

    func listModels() async throws -> [String] {
        guard let url = modelsEndpoint else { throw LLMError.invalidURL }
        let request = LLMHTTP.makeGetRequest(url: url, headers: ["Authorization": "Bearer \(apiKey)"])
        let page = try LLMHTTP.decodeModelPage(try await LLMHTTP.send(request, session: session))
        return LLMHTTP.normalizedModelIDs(page.data.map(\.id))
    }
```

- [ ] **Step 5: `AnthropicClient.swift`——`maxTokens` 之后加常量，`complete` 之后加方法**

```swift
    /// 列模型最多翻几页，防止网关一直返回 has_more
    static let maxModelPages = 5
```

```swift
    /// base 已以 /v1 结尾时只拼 /models；填的是 /v1/messages 完整端点时换成同级的 /models
    var modelsEndpoint: URL? {
        var base = LLMHTTP.trimmedBase(baseURL)
        if base.hasSuffix("/v1/messages") { base.removeLast("/messages".count) }
        return URL(string: base.hasSuffix("/v1") ? base + "/models" : base + "/v1/models")
    }

    func listModels() async throws -> [String] {
        guard let endpoint = modelsEndpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LLMError.invalidURL
        }
        var ids: [String] = []
        var afterID: String?
        for _ in 0..<Self.maxModelPages {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = query
            guard let url = components.url else { throw LLMError.invalidURL }
            let data = try await LLMHTTP.send(LLMHTTP.makeGetRequest(url: url, headers: headers), session: session)
            let page = try LLMHTTP.decodeModelPage(data)
            ids += page.data.map(\.id)
            guard page.hasMore == true, let last = page.lastId else { break }
            afterID = last
        }
        return LLMHTTP.normalizedModelIDs(ids)
    }
```

- [ ] **Step 6: `LLMClientFactory.swift`——`make` 之后加**

```swift
    /// 拉取模型列表；不要求已填模型
    static func listModels(provider: AIProvider, apiKey: String, session: URLSession = .shared) async throws -> [String] {
        guard let base = provider.validatedBaseURL else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.notConfigured }
        switch provider.apiProtocol {
        case .openAI:
            return try await OpenAICompatibleClient(baseURL: base, model: "", apiKey: key, session: session).listModels()
        case .anthropic:
            return try await AnthropicClient(baseURL: base, model: "", apiKey: key, session: session).listModels()
        }
    }
```

- [ ] **Step 7: 跑 `LLMClientTests`，全部通过**

### Task 2: 选择模型的界面

**Files:**
- Create: `Smile/Features/Settings/ModelPickerSheet.swift`
- Modify: `Smile/Features/Settings/AIProviderEditView.swift`

- [ ] **Step 1: 新建 `ModelPickerSheet.swift`**

```swift
import SwiftUI

/// 从服务商拉取模型列表供选择；每次打开都重新拉取，不缓存
struct ModelPickerSheet: View {
    let provider: AIProvider
    let apiKey: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var query = ""
    /// 点「重试」时加一，重新触发 .task
    @State private var attempt = 0

    private enum LoadState: Equatable {
        case loading
        case missingConfig
        case failure(String)
        case loaded([String])
    }

    private var filteredModels: [String] {
        guard case .loaded(let models) = state else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("选择模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missingConfig:
            ContentUnavailableView("请先填写接口地址和 API Key", systemImage: "key")
        case .failure(let message):
            ContentUnavailableView {
                Label("获取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { attempt += 1 }
            }
        case .loaded(let models) where models.isEmpty:
            ContentUnavailableView("服务商没有返回模型，请手动填写", systemImage: "tray")
        case .loaded:
            List(filteredModels, id: \.self) { model in
                Button {
                    onSelect(model)
                    dismiss()
                } label: {
                    HStack {
                        Text(model).foregroundStyle(.primary)
                        Spacer()
                        if model == provider.trimmedModel {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            .overlay {
                if filteredModels.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
    }

    @MainActor
    private func load() async {
        guard let apiKey, provider.validatedBaseURL != nil else {
            state = .missingConfig
            return
        }
        state = .loading
        do {
            state = .loaded(try await LLMClientFactory.listModels(provider: provider, apiKey: apiKey))
        } catch is CancellationError {
            // 关闭 sheet 时请求随 .task 取消，不提示
        } catch LLMError.emptyResponse {
            // 通用文案说的是「整理结果」，列模型时换成专用的
            state = .failure("服务商返回的模型列表无法识别，请手动填写")
        } catch let error as LLMError {
            state = .failure(error.detailedMessage)
        } catch {
            state = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
    }
}
```

- [ ] **Step 2: `AIProviderEditView.swift`**

在 `TestState` 之后加：

```swift
    private struct ModelPickerRequest: Identifiable {
        let id = UUID()
        let provider: AIProvider
        let apiKey: String?
    }
```

`@State` 区加 `@State private var modelPicker: ModelPickerRequest?`。

模型 TextField 改为：

```swift
                HStack {
                    TextField("模型", text: providerBinding.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .model)
                    Button("选择", action: openModelPicker)
                        .buttonStyle(.borderless)
                }
```

body 修饰符末尾加：

```swift
        .sheet(item: $modelPicker) { request in
            ModelPickerSheet(provider: request.provider, apiKey: request.apiKey) { model in
                providerBinding.wrappedValue.model = model
            }
        }
```

方法区加：

```swift
    private func openModelPicker() {
        focusedField = nil
        // 先存好刚输入的 Key，同测试连接；写入失败时 Key 区已显示错误，不弹出
        guard saveKeyIfNeeded() else { return }
        modelPicker = ModelPickerRequest(provider: provider, apiKey: store.loadAPIKey(for: providerID))
    }
```

`testConnection` 中 LLMError 分支改用 `detailedMessage`：

```swift
        } catch let error as LLMError {
            // 测试连接时附上响应体，方便排查模型名、参数等 400 错误
            result = .failure(error.detailedMessage)
        }
```

- [ ] **Step 3: `xcodegen generate`，跑全量测试，全部通过**

- [ ] **Step 4: 提交**

```bash
git add Smile/Core/AI Smile/Features/Settings SmileTests/LLMClientTests.swift
git add -f Smile.xcodeproj/project.pbxproj docs/superpowers/plans/2026-10-22-ai-model-list.md
git commit -m "feat: 服务商编辑页的模型可从服务商拉取列表选择……"
```
