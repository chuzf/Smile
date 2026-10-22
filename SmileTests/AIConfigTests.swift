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
        let a = AISettings.default.providers[0], b = AISettings.default.providers[1]
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
        let kimi = s.providers[0], deepseek = s.providers[1]
        try store.saveAPIKey("sk-a", for: kimi)
        try store.saveAPIKey("sk-b", for: deepseek)

        let updated = try store.removeProvider(id: kimi.id, from: s)
        #expect(store.loadAPIKey(for: kimi) == nil)
        #expect(store.loadAPIKey(for: deepseek) == "sk-b")
        #expect(updated.activeProviderID == deepseek.id)
        #expect(store.load() == updated)
        try store.saveAPIKey("", for: deepseek)
    }

    @Test func isConfiguredUsesActiveProvidersKey() throws {
        let (store, _, _) = makeStore()
        let provider = complete()
        store.save(settings(with: provider))
        #expect(!store.isConfigured)
        try store.saveAPIKey("sk", for: provider)
        #expect(store.isConfigured)
        try store.saveAPIKey("", for: provider)
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
        #expect(store.loadAPIKey(for: kimi) == "sk-old")
        #expect(defaults.data(forKey: AIConfigStore.legacyConfigKey) == nil)
        #expect(keychain.get(AIConfigStore.legacyAPIKeyAccount) == nil)
        #expect(store.load() == s)   // 已保存，再读不会重新迁移
        try store.saveAPIKey("", for: kimi)
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
        #expect(store.loadAPIKey(for: custom) == "sk-old")
        try store.saveAPIKey("", for: custom)
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

    // MARK: 预设容错

    @Test func unknownPresetDecodesAsCustomInsteadOfDroppingSettings() throws {
        let (store, defaults, _) = makeStore()
        var s = AISettings.default; s.style = .concise
        s.providers.append(complete())
        store.save(s)
        let json = String(decoding: try #require(defaults.data(forKey: AIConfigStore.settingsKey)), as: UTF8.self)
            .replacingOccurrences(of: #""preset":"deepseek""#, with: #""preset":"future-ai""#)
        defaults.set(Data(json.utf8), forKey: AIConfigStore.settingsKey)

        let loaded = store.load()
        #expect(loaded.style == .concise)
        #expect(loaded.providers.count == 6)
        #expect(loaded.providers[1].preset == .custom)
        #expect(loaded.providers[1].baseURL == "https://api.deepseek.com")
    }

    // MARK: Key 绑定主机

    @Test func keyIsBoundToHostItWasSavedFor() throws {
        let (store, _, _) = makeStore()
        var s = AISettings.default
        let kimi = s.providers[0]
        try store.saveAPIKey("sk-kimi", for: kimi)
        #expect(store.loadAPIKey(for: kimi) == "sk-kimi")
        #expect(!store.hasKeyForOtherHost(kimi))

        // 换地址：Key 不再读出，按 ID 读（整理时的用法）也一样
        var moved = kimi; moved.baseURL = "https://evil.example.com/v1"
        s.providers[0] = moved; store.save(s)
        #expect(store.loadAPIKey(for: moved) == nil)
        #expect(store.loadAPIKey(for: moved.id) == nil)
        #expect(store.hasKeyForOtherHost(moved))
        #expect(!store.isConfigured)

        // 换预设同理
        let switched = kimi.applyingPreset(.deepseek)
        #expect(store.loadAPIKey(for: switched) == nil)

        // 只改路径、主机不变时仍可用；改回原地址也可用
        var samePath = kimi; samePath.baseURL = "https://API.moonshot.cn/v2"
        #expect(store.loadAPIKey(for: samePath) == "sk-kimi")

        // 为新地址重新填写后绑定新主机
        try store.saveAPIKey("sk-new", for: moved)
        #expect(store.loadAPIKey(for: moved) == "sk-new")
        #expect(store.loadAPIKey(for: kimi) == nil)
        try store.saveAPIKey("", for: moved)
        #expect(!store.hasKeyForOtherHost(kimi))
    }

    @Test func savingKeyNeedsValidBaseURL() {
        let (store, _, keychain) = makeStore()
        var p = complete(); p.baseURL = "http://api.example.com"
        #expect(throws: AIConfigError.self) { try store.saveAPIKey("sk", for: p) }
        #expect(keychain.get(AIConfigStore.apiKeyAccount(for: p.id)) == nil)
    }

    @Test func keysSavedBeforeHostBindingStayUsable() throws {
        let (store, defaults, keychain) = makeStore()
        var s = AISettings.default
        s.providers[1].baseURL = "https://gw.example.com/v1"
        store.save(s)
        defaults.removeObject(forKey: AIConfigStore.apiKeyHostsKey)
        try keychain.set(AIConfigStore.apiKeyAccount(for: s.providers[1].id), value: "sk-old")

        let loaded = store.load()
        #expect(store.loadAPIKey(for: loaded.providers[1]) == "sk-old")
        var moved = loaded.providers[1]; moved.baseURL = "https://other.example.com"
        #expect(store.loadAPIKey(for: moved) == nil)
        try store.saveAPIKey("", for: moved)
    }

    // MARK: 旧版 Key 迁移失败重试

    private struct KeychainFailure: Error {}

    private final class FakeKeychain: KeychainStoring {
        var items: [String: String] = [:]
        var failReads = false
        var failWrites = false

        func set(_ key: String, value: String) throws {
            if failWrites { throw KeychainFailure() }
            items[key] = value
        }

        func read(_ key: String) throws -> String? {
            if failReads { throw KeychainFailure() }
            return items[key]
        }

        func delete(_ key: String) throws {
            if failWrites { throw KeychainFailure() }
            items[key] = nil
        }
    }

    private func makeFakeStore() -> (AIConfigStore, UserDefaults, FakeKeychain) {
        let (_, defaults, _) = makeStore()
        let keychain = FakeKeychain()
        return (AIConfigStore(defaults: defaults, keychain: keychain), defaults, keychain)
    }

    private let legacyKimi = #"{"preset":"kimi","apiProtocol":"openAI","baseURL":"https://api.moonshot.cn/v1","model":"kimi-k2.6","style":"formal","customPrompt":""}"#

    @Test func legacyKeyKeptWhenReadFails() {
        let (store, defaults, keychain) = makeFakeStore()
        writeLegacy(legacyKimi, to: defaults)
        keychain.items[AIConfigStore.legacyAPIKeyAccount] = "sk-old"
        keychain.failReads = true

        let s = store.load()
        let kimi = s.providers[0]
        #expect(s.activeProviderID == kimi.id)
        // 读失败时不能当成没有而删掉旧 Key
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == "sk-old")

        keychain.failReads = false
        #expect(store.load() == s)
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == nil)
        #expect(store.loadAPIKey(for: kimi) == "sk-old")
    }

    @Test func legacyKeyRetriedAfterSettingsSaved() {
        let (store, defaults, keychain) = makeFakeStore()
        writeLegacy(legacyKimi, to: defaults)
        keychain.items[AIConfigStore.legacyAPIKeyAccount] = "sk-old"
        keychain.failWrites = true

        var s = store.load()
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == "sk-old")
        // 设置页随后保存了设置，下次读取走新格式，仍要重试复制旧 Key
        s.style = .concise
        store.save(s)

        keychain.failWrites = false
        let loaded = store.load()
        #expect(loaded == s)
        #expect(store.loadAPIKey(for: loaded.providers[0]) == "sk-old")
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == nil)
    }

    @Test func orphanedLegacyKeyMovesToActiveProviderWithoutKey() throws {
        let (store, _, keychain) = makeFakeStore()
        var s = AISettings.default
        s.activeProviderID = s.providers[1].id
        store.save(s)
        keychain.items[AIConfigStore.legacyAPIKeyAccount] = "sk-old"

        _ = store.load()
        #expect(store.loadAPIKey(for: s.providers[1]) == "sk-old")
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == nil)
    }

    @Test func legacyKeyDoesNotOverwriteNewKey() throws {
        let (store, defaults, keychain) = makeFakeStore()
        let s = AISettings.default
        store.save(s)
        try store.saveAPIKey("sk-new", for: s.providers[0])
        keychain.items[AIConfigStore.legacyAPIKeyAccount] = "sk-old"
        defaults.removeObject(forKey: AIConfigStore.legacyKeyResolvedKey)

        _ = store.load()
        #expect(store.loadAPIKey(for: s.providers[0]) == "sk-new")
        #expect(keychain.items[AIConfigStore.legacyAPIKeyAccount] == nil)
    }

    // MARK: 改名标记

    @Test func doubaoRenameFlagSetOnFirstLaunch() {
        let (store, defaults, _) = makeStore()
        #expect(store.load() == .default)
        #expect(defaults.bool(forKey: AIConfigStore.doubaoRenamedKey))

        var s = AISettings.default
        s.providers[2].name = "豆包"
        store.save(s)
        #expect(store.load().providers[2].name == "豆包")
    }

    @Test func saveSkipsUnchangedSettingsAndNotifiesOnChange() {
        let (store, defaults, _) = makeStore()
        var count = 0
        // 只数这个存储发出的，别的测试并行时也会发
        let token = NotificationCenter.default.addObserver(forName: AIConfigStore.didChangeNotification,
                                                           object: defaults, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        var s = AISettings.default
        store.save(s)
        store.save(s)
        #expect(count == 1)
        s.style = .formal
        store.save(s)
        #expect(count == 2)
    }
}
