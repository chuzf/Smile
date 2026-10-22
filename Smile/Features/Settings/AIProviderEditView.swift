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
