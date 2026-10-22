# AI 整理多服务商 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI 整理从只保存一套服务商配置，改为可配置多个服务商、由用户选择启用哪一个（spec：`docs/superpowers/specs/2026-10-22-ai-multi-provider-design.md`）。

**Architecture:** `AIConfig` 拆成 `AIProvider`（单个服务商）与 `AISettings`（列表、启用项、全局风格）。`AIConfigStore` 读写 `AISettings`，Key 按服务商 ID 分别存钥匙串，首次读取时迁移旧数据。设置页改为服务商列表 + 编辑页，编辑器整理时取启用中的服务商。

**Tech Stack:** Swift、SwiftUI、Swift Testing、Security（Keychain）、xcodegen

**环境前提：** macOS + Xcode。新增源文件后先 `xcodegen generate`。`docs/` 在 `.gitignore` 中，plan/spec 需 `git add -f`。

**测试命令：**

```bash
xcodegen generate
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/smile-dd-main \
  -only-testing:SmileTests/AIConfigTests -only-testing:SmileTests/LLMClientTests test 2>&1 | tail -30
```

**说明：** 删除 `AIConfig` 后，App 要等 Task 1–3 全部改完才能重新编译，所以只在 Task 3 结束时跑测试并提交一次。工作区里已有未提交的 `kimi-k3` 与 DeepSeek 预设改动，一并提交。

---

## 文件清单

| 文件 | 职责 |
|------|------|
| `Smile/Core/AI/AIConfig.swift` | `AIProtocol`/`AIPreset`/`FormattingStyle`（不变）、`AIProvider`、`AISettings`、`AIConfigStore`（含迁移） |
| `Smile/Core/AI/LLMClientFactory.swift` | `make(provider:apiKey:session:)` |
| `Smile/Features/Settings/AISettingsView.swift` | 服务商列表、添加/删除/切换、整理风格 |
| `Smile/Features/Settings/AIProviderEditView.swift`（新） | 单个服务商编辑、Key、测试连接、删除 |
| `Smile/Features/EntryEditor/iOSNoteEditorView.swift` | `startFormatting` 取启用中的服务商 |
| `SmileTests/AIConfigTests.swift` | 重写 |
| `SmileTests/LLMClientTests.swift` | 工厂测试改签名 |

---

### Task 1: 数据模型、存储与迁移

**Files:**
- Modify: `Smile/Core/AI/AIConfig.swift`（`AIConfig` 及 `AIConfigStore` 整段替换，前三个 enum 保留）
- Modify: `Smile/Core/AI/LLMClientFactory.swift`
- Test: `SmileTests/AIConfigTests.swift`（整文件替换）、`SmileTests/LLMClientTests.swift:220-234`

- [ ] **Step 1: 重写 `SmileTests/AIConfigTests.swift`**

```swift
import Testing
import Foundation
@testable import Smile

@Suite("AIConfig", .serialized)
struct AIConfigTests {
    private static let suiteName = "com.smilejar.test.aiconfig"
    private static let keychainService = "com.smilejar.test.ai"

    private func makeStore() -> (AIConfigStore, UserDefaults, KeychainService) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        let keychain = KeychainService(service: Self.keychainService)
        try? keychain.delete(AIConfigStore.legacyAPIKeyAccount)
        for provider in AISettings.default.providers {
            try? keychain.delete(AIConfigStore.apiKeyAccount(for: provider.id))
        }
        return (AIConfigStore(defaults: defaults, keychain: keychain), defaults, keychain)
    }

    private func complete() -> AIProvider {
        var p = AIProvider.make(preset: .custom)
        p.baseURL = "https://api.example.com/v1"
        p.model = "m"
        return p
    }

    private func settings(with provider: AIProvider) -> AISettings {
        AISettings(providers: [provider], activeProviderID: provider.id, style: .light, customPrompt: "")
    }

    // MARK: 默认值与预设

    @Test func defaultHasFourPresetsWithKimiActive() {
        let s = AISettings.default
        #expect(s.providers.map(\.preset) == [.kimi, .deepseek, .doubao, .anthropic])
        #expect(s.providers.map(\.name) == ["Kimi", "DeepSeek", "豆包", "Anthropic"])
        #expect(s.activeProvider?.preset == .kimi)
        #expect(s.style == .light)
        #expect(AISettings.default == AISettings.default)   // 预置项 ID 固定
    }

    @Test func presetsFillDefaults() {
        let kimi = AIProvider.make(preset: .kimi)
        #expect(kimi.apiProtocol == .openAI)
        #expect(kimi.baseURL == "https://api.moonshot.cn/v1")
        #expect(kimi.model == "kimi-k3")

        let deepseek = AIProvider.make(preset: .deepseek)
        #expect(deepseek.baseURL == "https://api.deepseek.com")
        #expect(deepseek.model == "deepseek-flash")

        let doubao = AIProvider.make(preset: .doubao)
        #expect(doubao.baseURL == "https://ark.cn-beijing.volces.com/api/v3")
        #expect(doubao.model == "")

        let anthropic = AIProvider.make(preset: .anthropic)
        #expect(anthropic.apiProtocol == .anthropic)
        #expect(anthropic.baseURL == "https://api.anthropic.com")
        #expect(anthropic.model == "claude-opus-5")

        let custom = AIProvider.make(preset: .custom)
        #expect(custom.name == "自定义")
        #expect(custom.apiProtocol == .openAI)
        #expect(custom.baseURL == "")
        #expect(custom.model == "")
    }

    @Test func applyingPresetRenamesOnlyUntouchedName() {
        let kimi = AIProvider.make(preset: .kimi)
        let switched = kimi.applyingPreset(.anthropic)
        #expect(switched.name == "Anthropic")
        #expect(switched.id == kimi.id)

        var renamed = kimi; renamed.name = "工作账号"
        #expect(renamed.applyingPreset(.anthropic).name == "工作账号")

        var gateway = complete(); gateway.apiProtocol = .anthropic
        let kept = gateway.applyingPreset(.custom)
        #expect(kept.baseURL == "https://api.example.com/v1")
        #expect(kept.apiProtocol == .anthropic)
    }

    @Test func providerDisplayName() {
        var custom = AIProvider.make(preset: .custom)
        custom.baseURL = "https://GW.example.com/v1"
        #expect(custom.consentHost == "gw.example.com")
        #expect(custom.providerDisplayName == "gw.example.com")
        custom.baseURL = "http://insecure.example.com"
        #expect(custom.consentHost == nil)
        #expect(custom.providerDisplayName == "自定义服务商")

        var named = AIProvider.make(preset: .kimi)
        #expect(named.providerDisplayName == "Kimi")
        named.name = "  "
        #expect(named.providerDisplayName == "api.moonshot.cn")
        named.name = " 工作 "
        #expect(named.providerDisplayName == "工作")
    }

    // MARK: 完整性

    @Test func providerCompletenessRequiresHttpsModelAndKey() {
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

    @Test func settingsCompletenessNeedsActiveProviderAndPrompt() {
        var s = settings(with: complete())
        #expect(s.isComplete(apiKey: "sk"))
        s.style = .custom; s.customPrompt = " "
        #expect(!s.isComplete(apiKey: "sk"))
        s.customPrompt = "改成诗"
        #expect(s.isComplete(apiKey: "sk"))
        s.activeProviderID = nil
        #expect(!s.isComplete(apiKey: "sk"))
    }

    // MARK: 删除

    @Test func removingProviderMovesActive() {
        let s = AISettings.default
        let kimi = s.providers[0], deepseek = s.providers[1]

        let other = s.removingProvider(id: deepseek.id)
        #expect(other.providers.count == 3)
        #expect(other.activeProviderID == kimi.id)

        let active = s.removingProvider(id: kimi.id)
        #expect(active.activeProviderID == deepseek.id)

        var empty = s
        for p in s.providers { empty = empty.removingProvider(id: p.id) }
        #expect(empty.providers.isEmpty)
        #expect(empty.activeProviderID == nil)
        #expect(empty.activeProvider == nil)
    }

    // MARK: 存储

    @Test func loadReturnsDefaultWhenNothingSaved() {
        let (store, _, _) = makeStore()
        #expect(store.load() == .default)
    }

    @Test func saveAndLoadRoundTrip() {
        let (store, _, _) = makeStore()
        var s = AISettings.default
        var gateway = complete(); gateway.apiProtocol = .anthropic; gateway.name = "网关"
        s.providers.append(gateway)
        s.activeProviderID = gateway.id
        s.style = .custom
        s.customPrompt = "改成诗"
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func apiKeysArePerProviderAndNotInDefaults() throws {
        let (store, defaults, _) = makeStore()
        let a = AISettings.default.providers[0].id, b = AISettings.default.providers[1].id
        try store.saveAPIKey("  sk-a  ", for: a)
        try store.saveAPIKey("sk-b", for: b)
        #expect(store.loadAPIKey(for: a) == "sk-a")
        #expect(store.loadAPIKey(for: b) == "sk-b")
        let leaked = defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.hasPrefix("sk-") == true }
        #expect(!leaked)

        try store.saveAPIKey("", for: a)
        #expect(store.loadAPIKey(for: a) == nil)
        #expect(store.loadAPIKey(for: b) == "sk-b")
        try store.saveAPIKey("", for: b)
    }

    @Test func removeProviderDeletesItsKey() throws {
        let (store, _, _) = makeStore()
        let s = AISettings.default
        let kimi = s.providers[0].id, deepseek = s.providers[1].id
        try store.saveAPIKey("sk-a", for: kimi)
        try store.saveAPIKey("sk-b", for: deepseek)

        let updated = try store.removeProvider(id: kimi, from: s)
        #expect(store.loadAPIKey(for: kimi) == nil)
        #expect(store.loadAPIKey(for: deepseek) == "sk-b")
        #expect(updated.activeProviderID == deepseek)
        #expect(store.load() == updated)
        try store.saveAPIKey("", for: deepseek)
    }

    @Test func isConfiguredUsesActiveProvidersKey() throws {
        let (store, _, _) = makeStore()
        let provider = complete()
        store.save(settings(with: provider))
        #expect(!store.isConfigured)
        try store.saveAPIKey("sk", for: provider.id)
        #expect(store.isConfigured)
        try store.saveAPIKey("", for: provider.id)
    }

    @Test func consentIsRecordedPerHost() {
        let (store, _, _) = makeStore()
        #expect(!store.hasConsent(for: "api.moonshot.cn"))
        store.recordConsent(for: "API.Moonshot.cn")
        store.recordConsent(for: "api.moonshot.cn")   // 重复记录不出错
        #expect(store.hasConsent(for: "api.moonshot.cn"))
        #expect(!store.hasConsent(for: "api.anthropic.com"))
    }

    // MARK: 旧版迁移

    private func writeLegacy(_ json: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: AIConfigStore.legacyConfigKey)
    }

    @Test func migratesLegacyPresetIntoMatchingProvider() throws {
        let (store, defaults, keychain) = makeStore()
        writeLegacy(#"{"preset":"kimi","apiProtocol":"openAI","baseURL":"https://api.moonshot.cn/v1","model":"kimi-k2.6","style":"formal","customPrompt":""}"#, to: defaults)
        try keychain.set(AIConfigStore.legacyAPIKeyAccount, value: "sk-old")

        let s = store.load()
        let kimi = s.providers[0]
        #expect(s.providers.count == 4)
        #expect(s.activeProviderID == kimi.id)
        #expect(kimi.model == "kimi-k2.6")
        #expect(s.style == .formal)
        #expect(store.loadAPIKey(for: kimi.id) == "sk-old")
        #expect(defaults.data(forKey: AIConfigStore.legacyConfigKey) == nil)
        #expect(keychain.get(AIConfigStore.legacyAPIKeyAccount) == nil)
        #expect(store.load() == s)   // 已保存，再读不会重新迁移
        try store.saveAPIKey("", for: kimi.id)
    }

    @Test func migratesLegacyCustomAsNewProvider() throws {
        let (store, defaults, keychain) = makeStore()
        writeLegacy(#"{"preset":"custom","apiProtocol":"anthropic","baseURL":"https://gw.example.com/api","model":"claude-opus-5","style":"custom","customPrompt":"改成诗"}"#, to: defaults)
        try keychain.set(AIConfigStore.legacyAPIKeyAccount, value: "sk-old")

        let s = store.load()
        #expect(s.providers.count == 5)
        let custom = try #require(s.activeProvider)
        #expect(custom.id == s.providers[4].id)
        #expect(custom.preset == .custom)
        #expect(custom.apiProtocol == .anthropic)
        #expect(custom.baseURL == "https://gw.example.com/api")
        #expect(custom.model == "claude-opus-5")
        #expect(s.customPrompt == "改成诗")
        #expect(store.loadAPIKey(for: custom.id) == "sk-old")
        try store.saveAPIKey("", for: custom.id)
    }

    @Test func doesNotMigrateWhenSettingsExist() {
        let (store, defaults, _) = makeStore()
        var s = AISettings.default; s.style = .concise
        store.save(s)
        writeLegacy(#"{"preset":"anthropic","apiProtocol":"anthropic","baseURL":"https://api.anthropic.com","model":"x","style":"formal","customPrompt":""}"#, to: defaults)
        #expect(store.load() == s)
    }
}
```

- [ ] **Step 2: 更新 `SmileTests/LLMClientTests.swift` 的工厂测试（第 220 行起两个 test）**

```swift
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
```

- [ ] **Step 3: 替换 `AIConfig.swift` 中 `struct AIConfig` 及 `struct AIConfigStore`**

```swift
/// 一个服务商的连接配置；Key 不在这里，按 `id` 单独存钥匙串
struct AIProvider: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var preset: AIPreset
    var apiProtocol: AIProtocol
    var baseURL: String
    var model: String

    /// 按预设新建一条；自定义预设地址和模型留空、协议为 OpenAI 兼容
    static func make(preset: AIPreset, id: UUID = UUID()) -> AIProvider {
        AIProvider(id: id, name: AIPreset.custom.displayName, preset: .custom,
                   apiProtocol: .openAI, baseURL: "", model: "")
            .applyingPreset(preset)
    }

    /// 换预设时重新填入协议、地址和模型（自定义保留原值）；名称没改过时跟着换成新预设的名字
    func applyingPreset(_ preset: AIPreset) -> AIProvider {
        var provider = self
        if name == self.preset.displayName { provider.name = preset.displayName }
        provider.preset = preset
        if let d = preset.defaults {
            provider.apiProtocol = d.apiProtocol
            provider.baseURL = d.baseURL
            provider.model = d.model
        }
        return provider
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

    /// 内容会发往的主机名（小写）；同意发送按它记录，换了服务商地址要重新征得同意
    var consentHost: String? { validatedBaseURL?.host()?.lowercased() }

    /// 列表和同意弹窗里给用户看的名称；没起名的自定义服务商显示主机名
    var providerDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || (preset == .custom && trimmed == AIPreset.custom.displayName) {
            return consentHost ?? "自定义服务商"
        }
        return trimmed
    }

    func isComplete(apiKey: String?) -> Bool {
        guard validatedBaseURL != nil, !trimmedModel.isEmpty,
              let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return false }
        return true
    }
}

/// AI 整理的全部设置：服务商列表、启用哪一个，以及所有服务商共用的整理风格
struct AISettings: Codable, Equatable {
    var providers: [AIProvider]
    var activeProviderID: UUID?
    var style: FormattingStyle
    var customPrompt: String

    /// 预置服务商用固定 ID：没保存过设置时每次读到的默认列表相同，按 ID 存的 Key 才对得上
    private static let presetProviders: [(AIPreset, String)] = [
        (.kimi, "6B1D3C2E-0001-4A7E-9C1A-5D3F2B8E0001"),
        (.deepseek, "6B1D3C2E-0002-4A7E-9C1A-5D3F2B8E0002"),
        (.doubao, "6B1D3C2E-0003-4A7E-9C1A-5D3F2B8E0003"),
        (.anthropic, "6B1D3C2E-0004-4A7E-9C1A-5D3F2B8E0004"),
    ]

    static var `default`: AISettings {
        let providers = presetProviders.map { AIProvider.make(preset: $0.0, id: UUID(uuidString: $0.1)!) }
        return AISettings(providers: providers, activeProviderID: providers.first?.id,
                          style: .light, customPrompt: "")
    }

    var activeProvider: AIProvider? { providers.first { $0.id == activeProviderID } }

    func isComplete(apiKey: String?) -> Bool {
        guard let provider = activeProvider, provider.isComplete(apiKey: apiKey) else { return false }
        if style == .custom && customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    /// 删掉的是启用项时改为启用第一条，删光了则为 nil
    func removingProvider(id: UUID) -> AISettings {
        var settings = self
        settings.providers.removeAll { $0.id == id }
        if settings.activeProviderID == id { settings.activeProviderID = settings.providers.first?.id }
        return settings
    }
}

/// 设置存 UserDefaults，API Key 只存 Keychain（每个服务商一条）
struct AIConfigStore {
    static let settingsKey = "ai_settings"
    static let legacyConfigKey = "ai_config"
    static let legacyAPIKeyAccount = "ai_api_key"

    static func apiKeyAccount(for id: UUID) -> String { "ai_api_key.\(id.uuidString)" }

    let defaults: UserDefaults
    let keychain: KeychainService

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func load() -> AISettings {
        if let data = defaults.data(forKey: Self.settingsKey),
           let settings = try? JSONDecoder().decode(AISettings.self, from: data) {
            return settings
        }
        return migrateLegacy() ?? .default
    }

    func save(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    func loadAPIKey(for id: UUID) -> String? {
        guard let key = keychain.get(Self.apiKeyAccount(for: id))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// 传入空字符串表示清除
    func saveAPIKey(_ key: String, for id: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(Self.apiKeyAccount(for: id))
        } else {
            try keychain.set(Self.apiKeyAccount(for: id), value: trimmed)
        }
    }

    /// 先删 Key 再从列表移除并保存；删 Key 失败时抛错，列表不变
    func removeProvider(id: UUID, from settings: AISettings) throws -> AISettings {
        try keychain.delete(Self.apiKeyAccount(for: id))
        let updated = settings.removingProvider(id: id)
        save(updated)
        return updated
    }

    var isConfigured: Bool {
        let settings = load()
        return settings.isComplete(apiKey: settings.activeProviderID.flatMap { loadAPIKey(for: $0) })
    }

    // MARK: 旧版迁移

    /// 旧版只保存一套配置
    private struct LegacyConfig: Decodable {
        var preset: AIPreset
        var apiProtocol: AIProtocol
        var baseURL: String
        var model: String
        var style: FormattingStyle
        var customPrompt: String
    }

    /// 把旧配置合并进默认列表并启用，旧 Key 移到这一条下；Key 写入失败时不保存，下次读取再试
    private func migrateLegacy() -> AISettings? {
        guard let data = defaults.data(forKey: Self.legacyConfigKey),
              let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) else { return nil }
        var settings = AISettings.default
        settings.style = legacy.style
        settings.customPrompt = legacy.customPrompt
        let index: Int
        if legacy.preset != .custom, let i = settings.providers.firstIndex(where: { $0.preset == legacy.preset }) {
            index = i
        } else {
            settings.providers.append(.make(preset: .custom))
            index = settings.providers.count - 1
        }
        settings.providers[index].apiProtocol = legacy.apiProtocol
        settings.providers[index].baseURL = legacy.baseURL
        settings.providers[index].model = legacy.model
        let id = settings.providers[index].id
        settings.activeProviderID = id

        if let key = keychain.get(Self.legacyAPIKeyAccount) {
            do { try keychain.set(Self.apiKeyAccount(for: id), value: key) } catch { return settings }
        }
        save(settings)
        // 新数据已保存，旧数据删不掉也不会再被读取
        try? keychain.delete(Self.legacyAPIKeyAccount)
        defaults.removeObject(forKey: Self.legacyConfigKey)
        return settings
    }

    // MARK: 发送内容的同意
    // （hasConsent / recordConsent 原样保留）
}
```

- [ ] **Step 4: 更新 `LLMClientFactory.swift`**

```swift
enum LLMClientFactory {
    static func make(provider: AIProvider, apiKey: String, session: URLSession = .shared) throws -> LLMClient {
        guard let base = provider.validatedBaseURL else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !provider.trimmedModel.isEmpty else { throw LLMError.notConfigured }
        switch provider.apiProtocol {
        case .openAI:
            return OpenAICompatibleClient(baseURL: base, model: provider.trimmedModel, apiKey: key, session: session)
        case .anthropic:
            return AnthropicClient(baseURL: base, model: provider.trimmedModel, apiKey: key, session: session)
        }
    }
}
```

（此时 App 尚不能编译，Task 3 后统一验证。）

### Task 2: 编辑器整理流程

**Files:** Modify `Smile/Features/EntryEditor/iOSNoteEditorView.swift:422-443`

- [ ] **Step 1: 替换 `startFormatting` 开头到创建 service 为止**

```swift
    fileprivate func startFormatting() {
        guard !isFormatting else { return }
        let store = AIConfigStore()
        let settings = store.load()
        guard let provider = settings.activeProvider,
              let apiKey = store.loadAPIKey(for: provider.id), settings.isComplete(apiKey: apiKey),
              let host = provider.consentHost else {
            showAISetupAlert = true
            return
        }
        // 内容会发给第三方服务商：第一次发往这个地址前先说明并征得同意（App Store 审核指南 5.1.2）
        guard store.hasConsent(for: host) else {
            aiConsentRequest = AIConsentRequest(host: host, providerName: provider.providerDisplayName)
            return
        }
        let client: LLMClient
        do {
            client = try LLMClientFactory.make(provider: provider, apiKey: apiKey)
        } catch {
            formattingErrorMessage = (error as? LLMError ?? .notConfigured).userMessage
            return
        }
        let service = TextFormattingService(client: client, style: settings.style, customPrompt: settings.customPrompt)
```

### Task 3: 设置页

**Files:**
- Modify: `Smile/Features/Settings/AISettingsView.swift`（整文件替换）
- Create: `Smile/Features/Settings/AIProviderEditView.swift`

- [ ] **Step 1: `AISettingsView.swift`**

```swift
import SwiftUI

struct AISettingsView: View {
    private let store = AIConfigStore()

    @State private var settings = AISettings.default
    @State private var loaded = false
    /// 已保存 Key 的服务商，列表里据此标「未填 Key」
    @State private var providersWithKey: Set<UUID> = []
    @State private var editingProviderID: UUID?
    @State private var pendingDeletion: AIProvider?
    @State private var deleteError: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        Form {
            Section("服务商") {
                ForEach(settings.providers) { provider in
                    providerRow(provider)
                }
                .onDelete { offsets in
                    pendingDeletion = offsets.first.map { settings.providers[$0] }
                }
                Menu {
                    ForEach(AIPreset.allCases) { preset in
                        Button(preset.displayName) { addProvider(preset) }
                    }
                } label: {
                    Label("添加服务商", systemImage: "plus")
                }
            }

            Section {
                Picker("风格", selection: $settings.style) {
                    ForEach(FormattingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.style == .custom {
                    TextEditor(text: $settings.customPrompt)
                        .frame(minHeight: 120)
                        .focused($promptFocused)
                }
            } header: {
                Text("整理风格")
            } footer: {
                Text("整理时会把标题和正文文字发送给启用中的服务商，不发送照片、视频和语音。API Key 仅保存在本机钥匙串。")
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        // 自定义提示词的 TextEditor 回车只会换行，Form 默认也不会因滑动或点空白收起键盘，需另给收起的办法
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { promptFocused = false }
            }
        }
        .navigationDestination(item: $editingProviderID) { id in
            AIProviderEditView(settings: $settings, providerID: id, store: store, onKeyChange: refreshKeys)
        }
        .onAppear {
            if !loaded {
                loaded = true
                settings = store.load()
            }
            refreshKeys()
        }
        .onChange(of: settings) { _, newValue in store.save(newValue) }
        .confirmationDialog("删除「\(pendingDeletion?.providerDisplayName ?? "")」？",
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDeletion) { provider in
            Button("删除", role: .destructive) { delete(provider) }
        } message: { _ in
            Text("这个服务商的 API Key 也会一并删除。")
        }
        .alert("删除失败，请重试", isPresented: Binding(get: { deleteError != nil },
                                                    set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { }
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        HStack {
            Button {
                settings.activeProviderID = provider.id
            } label: {
                HStack {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .opacity(provider.id == settings.activeProviderID ? 1 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.providerDisplayName)
                            .foregroundStyle(.primary)
                        Text(provider.trimmedModel.isEmpty ? "未填模型" : provider.trimmedModel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !providersWithKey.contains(provider.id) {
                        Text("未填 Key")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(provider.id == settings.activeProviderID ? .isSelected : [])

            Button {
                editingProviderID = provider.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑\(provider.providerDisplayName)")
        }
    }

    private func addProvider(_ preset: AIPreset) {
        let provider = AIProvider.make(preset: preset)
        settings.providers.append(provider)
        if settings.activeProvider == nil { settings.activeProviderID = provider.id }
        editingProviderID = provider.id
    }

    private func delete(_ provider: AIProvider) {
        do {
            settings = try store.removeProvider(id: provider.id, from: settings)
            refreshKeys()
        } catch {
            deleteError = "删除失败，请重试"
        }
    }

    private func refreshKeys() {
        providersWithKey = Set(settings.providers.map(\.id).filter { store.loadAPIKey(for: $0) != nil })
    }
}
```

- [ ] **Step 2: `AIProviderEditView.swift`**

```swift
import SwiftUI

/// 编辑一个服务商：连接配置、API Key、测试连接、删除
struct AIProviderEditView: View {
    @Binding var settings: AISettings
    let providerID: UUID
    let store: AIConfigStore
    /// Key 保存或清除后通知列表刷新「未填 Key」标记
    let onKeyChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var hasSavedKey = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var testState: TestState = .idle
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case name, baseURL, model, apiKey
    }

    private enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    private var exists: Bool { settings.providers.contains { $0.id == providerID } }

    /// 删除后返回前视图还会刷新，此时已找不到这一条，给个占位值
    private var provider: AIProvider {
        settings.providers.first { $0.id == providerID } ?? .make(preset: .custom, id: providerID)
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { provider },
            set: { newValue in
                guard let i = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
                settings.providers[i] = newValue
            }
        )
    }

    private var presetBinding: Binding<AIPreset> {
        Binding(
            get: { provider.preset },
            set: { providerBinding.wrappedValue = provider.applyingPreset($0) }
        )
    }

    var body: some View {
        Form {
            Section("服务商") {
                TextField("名称", text: providerBinding.name)
                    .focused($focusedField, equals: .name)
                Picker("预设", selection: presetBinding) {
                    ForEach(AIPreset.allCases) { Text($0.displayName).tag($0) }
                }
                if provider.preset == .custom {
                    Picker("接口协议", selection: providerBinding.apiProtocol) {
                        ForEach(AIProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                TextField("接口地址", text: providerBinding.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .baseURL)
                if !provider.baseURL.isEmpty && provider.validatedBaseURL == nil {
                    Text("请填写以 https:// 开头的地址").font(.footnote).foregroundStyle(.red)
                }
                TextField("模型", text: providerBinding.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)
                if provider.preset == .doubao {
                    Text("填写方舟控制台中的模型 ID 或接入点 ID").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("API Key") {
                SecureField(hasSavedKey ? "已保存（输入新值可覆盖）" : "粘贴 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .apiKey)
                    .onSubmit { saveKeyIfNeeded() }
                if hasSavedKey {
                    Button("清除 Key", role: .destructive, action: clearKey)
                }
                if let keyError {
                    Text(keyError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    focusedField = nil
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        testStatusView
                    }
                }
                .disabled(testState == .testing)
            }

            Section {
                Button("删除服务商", role: .destructive) { confirmingDelete = true }
                if let deleteError {
                    Text(deleteError).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(provider.providerDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .onAppear { hasSavedKey = store.loadAPIKey(for: providerID) != nil }
        .onChange(of: provider) {
            // 列表页的 onChange 不在屏幕上时不一定触发，这里也保存一次
            if exists { store.save(settings) }
            testState = .idle
        }
        .onChange(of: focusedField) { oldValue, _ in
            // 不按回车直接离开 Key 输入框时也保存，否则要等退出页面才写入
            if oldValue == .apiKey { saveKeyIfNeeded() }
        }
        .onDisappear { saveKeyIfNeeded() }
        .confirmationDialog("删除「\(provider.providerDisplayName)」？", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteProvider)
        } message: {
            Text("这个服务商的 API Key 也会一并删除。")
        }
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

    /// 返回 false 表示输入了新 Key 但写入 Keychain 失败
    @discardableResult
    private func saveKeyIfNeeded() -> Bool {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // 服务商已删除时不再写 Key，否则会留下没人用的钥匙串记录
        guard !trimmed.isEmpty, exists else { return true }
        do {
            try store.saveAPIKey(trimmed, for: providerID)
            keyInput = ""
            hasSavedKey = true
            keyError = nil
            onKeyChange()
            return true
        } catch {
            keyError = "API Key 保存失败，请重试"
            return false
        }
    }

    private func clearKey() {
        do {
            try store.saveAPIKey("", for: providerID)
            keyInput = ""
            hasSavedKey = false
            keyError = nil
            onKeyChange()
        } catch {
            keyError = "清除失败，请重试"
        }
    }

    private func deleteProvider() {
        do {
            settings = try store.removeProvider(id: providerID, from: settings)
            keyInput = ""
            onKeyChange()
            dismiss()
        } catch {
            deleteError = "删除失败，请重试"
        }
    }

    @MainActor
    private func testConnection() async {
        // Key 没写进去时不能拿旧 Key 去测
        guard saveKeyIfNeeded() else { return }
        let tested = provider
        guard let key = store.loadAPIKey(for: providerID), tested.isComplete(apiKey: key) else {
            testState = .failure(LLMError.notConfigured.userMessage)
            return
        }
        testState = .testing
        let result: TestState
        do {
            let client = try LLMClientFactory.make(provider: tested, apiKey: key)
            _ = try await client.complete(system: "只回复 OK", user: "ping")
            result = .success
        } catch let error as LLMError {
            // 测试连接时附上响应体，方便排查模型名、参数等 400 错误；响应体里不含 Key
            if case .http(_, let body) = error, !body.isEmpty {
                result = .failure(error.userMessage + "\n" + body)
            } else {
                result = .failure(error.userMessage)
            }
        } catch {
            result = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
        // 等待期间用户改了配置时 onChange 已把状态复位，旧请求的结果不再对应当前配置，丢弃
        guard provider == tested, testState == .testing else { return }
        testState = result
    }
}
```

- [ ] **Step 3: 生成工程、编译、跑测试**

Run: `xcodegen generate` 然后上面的测试命令（`AIConfigTests` + `LLMClientTests`），再跑全量 `test`。
Expected: 全部通过。

- [ ] **Step 4: 提交**

```bash
git add Smile/Core/AI Smile/Features/Settings Smile/Features/EntryEditor/iOSNoteEditorView.swift SmileTests/AIConfigTests.swift SmileTests/LLMClientTests.swift
git add -f Smile.xcodeproj/project.pbxproj docs/superpowers/plans/2026-10-22-ai-multi-provider.md
git commit -m "feat: AI 整理支持配置多个服务商并选择启用哪一个……"
```
