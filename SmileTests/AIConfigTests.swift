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
