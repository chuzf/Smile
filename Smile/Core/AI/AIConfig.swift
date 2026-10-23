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

    /// 不认识的预设（如新版本才有的）按自定义解码，免得整份设置解码失败、回落成默认值再被保存覆盖
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIPreset(rawValue: raw) ?? .custom
    }

    var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        // rawValue 仍为 doubao，已保存的设置按它解码；方舟上也有 DeepSeek、Kimi 等模型，按平台命名
        case .doubao: return "火山方舟"
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
/// Key 绑定保存它时的接口主机：换了预设或地址后旧 Key 不再读出，避免把这家的 Key 发给另一家
struct AIConfigStore {
    static let settingsKey = "ai_settings"
    static let legacyConfigKey = "ai_config"
    static let legacyAPIKeyAccount = "ai_api_key"
    /// 豆包预设改名为火山方舟后，已保存的旧名称只改一次，之后用户再起名叫「豆包」不受影响
    static let doubaoRenamedKey = "ai_doubao_renamed"
    /// 服务商 ID → 保存 Key 时的接口主机；单独存放，不跟设置一起被别的页面的旧副本覆盖
    static let apiKeyHostsKey = "ai_api_key_hosts"
    /// 已为加入主机绑定之前保存的 Key 补记主机（按当时的地址），只补一次
    static let apiKeyHostsBackfilledKey = "ai_api_key_hosts_backfilled"
    /// 旧版 Key 要移到哪个服务商下；复制成功或确认没有旧 Key 后清掉
    static let legacyKeyTargetKey = "ai_legacy_key_target"
    static let legacyKeyResolvedKey = "ai_legacy_key_resolved"
    /// 设置或 Key 有变化时发出，同时存在的多个设置页据此重新读取
    static let didChangeNotification = Notification.Name("AIConfigStore.didChange")

    static func apiKeyAccount(for id: UUID) -> String { "ai_api_key.\(id.uuidString)" }

    let defaults: UserDefaults
    let keychain: any KeychainStoring

    init(defaults: UserDefaults = .standard, keychain: any KeychainStoring = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func load() -> AISettings {
        let settings: AISettings
        if let data = defaults.data(forKey: Self.settingsKey),
           var saved = try? JSONDecoder().decode(AISettings.self, from: data) {
            if !defaults.bool(forKey: Self.doubaoRenamedKey) {
                for i in saved.providers.indices
                where saved.providers[i].preset == .doubao && saved.providers[i].name == "豆包" {
                    saved.providers[i].name = AIPreset.doubao.displayName
                }
                // 先记下再保存：保存会发通知，设置页收到后重新读取时不再重复改名
                defaults.set(true, forKey: Self.doubaoRenamedKey)
                save(saved)
            }
            settings = saved
        } else {
            settings = migrateLegacy() ?? .default
        }
        // 首次启动、迁移后的列表里已是新名称，也记下，之后用户起名叫「豆包」不会被改
        defaults.set(true, forKey: Self.doubaoRenamedKey)
        backfillKeyHostsIfNeeded(settings)
        resolveLegacyKeyIfNeeded(settings)
        return settings
    }

    /// 内容没变时不写也不发通知，设置页重新读取后触发的保存不会来回循环
    func save(_ settings: AISettings) {
        // 按解码后的值比较：编码结果的键顺序不保证每次相同
        if let existing = defaults.data(forKey: Self.settingsKey),
           (try? JSONDecoder().decode(AISettings.self, from: existing)) == settings { return }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
        notifyChange()
    }

    /// 只返回为这个服务商当前接口主机保存的 Key；换了预设或地址后返回 nil，需重新填写
    func loadAPIKey(for provider: AIProvider) -> String? {
        guard let host = provider.consentHost, keyHost(for: provider.id) == host else { return nil }
        return storedAPIKey(for: provider.id)
    }

    /// 按已保存设置里这一条的当前地址校验，同 `loadAPIKey(for: AIProvider)`
    func loadAPIKey(for id: UUID) -> String? {
        guard let provider = load().providers.first(where: { $0.id == id }) else { return nil }
        return loadAPIKey(for: provider)
    }

    /// 钥匙串里有 Key，但是为别的接口地址保存的，不会再发出
    func hasKeyForOtherHost(_ provider: AIProvider) -> Bool {
        storedAPIKey(for: provider.id) != nil && loadAPIKey(for: provider) == nil
    }

    /// 传入空字符串表示清除；保存时记下当前接口主机，地址无效时不保存
    func saveAPIKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(Self.apiKeyAccount(for: provider.id))
            setKeyHost(nil, for: provider.id)
        } else {
            guard let host = provider.consentHost else { throw AIConfigError.invalidBaseURL }
            try keychain.set(Self.apiKeyAccount(for: provider.id), value: trimmed)
            setKeyHost(host, for: provider.id)
        }
        notifyChange()
    }

    /// 先删 Key 再从列表移除并保存；删 Key 失败时抛错，列表不变
    func removeProvider(id: UUID, from settings: AISettings) throws -> AISettings {
        try keychain.delete(Self.apiKeyAccount(for: id))
        setKeyHost(nil, for: id)
        let updated = settings.removingProvider(id: id)
        save(updated)
        return updated
    }

    var isConfigured: Bool {
        let settings = load()
        return settings.isComplete(apiKey: settings.activeProvider.flatMap { loadAPIKey(for: $0) })
    }

    private func storedAPIKey(for id: UUID) -> String? {
        guard let key = keychain.get(Self.apiKeyAccount(for: id))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private func keyHost(for id: UUID) -> String? {
        (defaults.dictionary(forKey: Self.apiKeyHostsKey) as? [String: String])?[id.uuidString]
    }

    private func setKeyHost(_ host: String?, for id: UUID) {
        var hosts = defaults.dictionary(forKey: Self.apiKeyHostsKey) as? [String: String] ?? [:]
        hosts[id.uuidString] = host
        defaults.set(hosts, forKey: Self.apiKeyHostsKey)
    }

    /// 加入主机绑定之前保存的 Key 没记主机，按各服务商现在的地址补记一次
    private func backfillKeyHostsIfNeeded(_ settings: AISettings) {
        guard !defaults.bool(forKey: Self.apiKeyHostsBackfilledKey) else { return }
        var hosts = defaults.dictionary(forKey: Self.apiKeyHostsKey) as? [String: String] ?? [:]
        for provider in settings.providers where hosts[provider.id.uuidString] == nil {
            hosts[provider.id.uuidString] = provider.consentHost
        }
        defaults.set(hosts, forKey: Self.apiKeyHostsKey)
        defaults.set(true, forKey: Self.apiKeyHostsBackfilledKey)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: defaults)
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

    /// 把旧配置合并进默认列表并启用、保存；旧 Key 由 `resolveLegacyKeyIfNeeded` 移到这一条下
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

        defaults.set(id.uuidString, forKey: Self.legacyKeyTargetKey)
        defaults.removeObject(forKey: Self.legacyKeyResolvedKey)
        save(settings)
        defaults.removeObject(forKey: Self.legacyConfigKey)
        return settings
    }

    /// 旧 Key 只在确认不存在或已复制到新位置后才删；读写失败（如设备锁定）时保留，下次读取再试。
    /// 新格式设置已存在时也会重试，早先复制失败但设置已被保存的用户也能找回旧 Key
    private func resolveLegacyKeyIfNeeded(_ settings: AISettings) {
        guard !defaults.bool(forKey: Self.legacyKeyResolvedKey) else { return }
        let legacyKey: String?
        do { legacyKey = try keychain.read(Self.legacyAPIKeyAccount) } catch { return }
        var copied = false
        if let legacyKey {
            // 只复制到迁移时记下的那一条；没记目标时不猜（用户可能已切换启用的服务商，
            // 猜错会把旧 Key 发到别家主机），直接删掉旧 Key，让用户重新填写
            let targetID = defaults.string(forKey: Self.legacyKeyTargetKey).flatMap(UUID.init(uuidString:))
            if let targetID, let target = settings.providers.first(where: { $0.id == targetID }) {
                do {
                    // 用户已给这一条填过新 Key 时不覆盖
                    if try keychain.read(Self.apiKeyAccount(for: target.id)) == nil {
                        try keychain.set(Self.apiKeyAccount(for: target.id), value: legacyKey)
                        setKeyHost(target.consentHost, for: target.id)
                        copied = true
                    }
                } catch { return }
            }
            do { try keychain.delete(Self.legacyAPIKeyAccount) } catch { return }
        }
        defaults.removeObject(forKey: Self.legacyKeyTargetKey)
        defaults.set(true, forKey: Self.legacyKeyResolvedKey)
        // 标记完再通知：设置页收到后重新读取时不再重复处理
        if copied { notifyChange() }
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

enum AIConfigError: Error {
    /// 接口地址不是有效的 https 地址，Key 无处绑定
    case invalidBaseURL
}
