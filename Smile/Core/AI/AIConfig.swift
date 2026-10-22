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
    case kimi, deepseek, doubao, openAI, anthropic, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        case .doubao: return "豆包"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .custom: return "自定义"
        }
    }

    /// 选中预设时填入的协议、地址和默认模型；自定义返回 nil，保留用户已填写的值
    var defaults: (apiProtocol: AIProtocol, baseURL: String, model: String)? {
        switch self {
        case .kimi: return (.openAI, "https://api.moonshot.cn/v1", "kimi-k3")
        case .deepseek: return (.openAI, "https://api.deepseek.com", "deepseek-flash")
        case .doubao: return (.openAI, "https://ark.cn-beijing.volces.com/api/v3", "")
        case .openAI: return (.openAI, "https://api.openai.com/v1", "gpt-6-luna")
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
        (.openAI, "6B1D3C2E-0005-4A7E-9C1A-5D3F2B8E0005"),
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

    static let consentedHostsKey = "ai_consented_hosts"

    /// 用户是否已同意把记录内容发送到这个主机
    func hasConsent(for host: String) -> Bool {
        let hosts = defaults.stringArray(forKey: Self.consentedHostsKey) ?? []
        return hosts.contains(host.lowercased())
    }

    func recordConsent(for host: String) {
        var hosts = defaults.stringArray(forKey: Self.consentedHostsKey) ?? []
        let host = host.lowercased()
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        defaults.set(hosts, forKey: Self.consentedHostsKey)
    }
}
