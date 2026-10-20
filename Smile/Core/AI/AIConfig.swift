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

    /// 内容会发往的主机名（小写）；同意发送按它记录，换了服务商地址要重新征得同意
    var consentHost: String? { validatedBaseURL?.host()?.lowercased() }

    /// 同意弹窗里给用户看的服务商名称
    var providerDisplayName: String {
        preset == .custom ? (consentHost ?? "自定义服务商") : preset.displayName
    }

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
