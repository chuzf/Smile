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

    @Test func defaultHasPresetProvidersWithKimiActive() {
        let s = AISettings.default
        #expect(s.providers.map(\.preset) == [.kimi, .deepseek, .doubao, .openAI, .anthropic])
        #expect(s.providers.map(\.name) == ["Kimi", "DeepSeek", "火山方舟", "OpenAI", "Anthropic"])
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

        let openAI = AIProvider.make(preset: .openAI)
        #expect(openAI.apiProtocol == .openAI)
        #expect(openAI.baseURL == "https://api.openai.com/v1")
        #expect(openAI.model == "gpt-6-luna")

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
        #expect(other.providers.count == 4)
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
        #expect(s.providers.count == 5)
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
        #expect(s.providers.count == 6)
        let custom = try #require(s.activeProvider)
        #expect(custom.id == s.providers[5].id)
        #expect(custom.preset == .custom)
        #expect(custom.apiProtocol == .anthropic)
        #expect(custom.baseURL == "https://gw.example.com/api")
        #expect(custom.model == "claude-opus-5")
        #expect(s.customPrompt == "改成诗")
        #expect(store.loadAPIKey(for: custom.id) == "sk-old")
        try store.saveAPIKey("", for: custom.id)
    }

    @Test func renamesSavedDoubaoOnce() throws {
        let (store, defaults, _) = makeStore()
        var s = AISettings.default
        s.providers[2].name = "豆包"
        var renamedByUser = AIProvider.make(preset: .doubao); renamedByUser.name = "方舟工作"
        var otherPreset = AIProvider.make(preset: .custom); otherPreset.name = "豆包"
        s.providers += [renamedByUser, otherPreset]
        store.save(s)

        let loaded = store.load()
        #expect(loaded.providers[2].name == "火山方舟")
        #expect(loaded.providers[5].name == "方舟工作")
        #expect(loaded.providers[6].name == "豆包")
        #expect(defaults.bool(forKey: AIConfigStore.doubaoRenamedKey))

        // 改过一次后，用户再起名叫「豆包」不会被改回
        var again = loaded
        again.providers[2].name = "豆包"
        store.save(again)
        #expect(store.load().providers[2].name == "豆包")
    }

    @Test func doesNotMigrateWhenSettingsExist() {
        let (store, defaults, _) = makeStore()
        var s = AISettings.default; s.style = .concise
        store.save(s)
        writeLegacy(#"{"preset":"anthropic","apiProtocol":"anthropic","baseURL":"https://api.anthropic.com","model":"x","style":"formal","customPrompt":""}"#, to: defaults)
        #expect(store.load() == s)
    }
}
