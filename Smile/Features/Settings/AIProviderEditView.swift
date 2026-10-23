import SwiftUI

/// 编辑一个服务商：连接配置、API Key、测试连接、删除
struct AIProviderEditView: View {
    @Binding var settings: AISettings
    let providerID: UUID
    let store: AIConfigStore
    /// Key 保存或清除后通知列表刷新「未填 Key」标记
    let onKeyChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 为当前接口主机保存过 Key
    @State private var hasSavedKey = false
    /// 钥匙串里的 Key 是为原来的地址保存的；换了预设或地址后不再发出，需重新填写
    @State private var keyForOtherHost = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var testState: TestState = .idle
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var modelPicker: ModelPickerRequest?
    /// 返回时输入的 Key 存不进去，询问继续编辑还是放弃
    @State private var confirmingDiscardKey = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name, baseURL, model, apiKey
    }

    private enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    private struct ModelPickerRequest: Identifiable {
        let id = UUID()
        let provider: AIProvider
        let apiKey: String?
    }

    private var exists: Bool { settings.providers.contains { $0.id == providerID } }

    /// 输入了还没写入钥匙串的 Key
    private var hasUnsavedKey: Bool {
        exists && !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                HStack {
                    TextField("模型", text: providerBinding.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .model)
                    Button("选择", action: openModelPicker)
                        .buttonStyle(.borderless)
                }
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
                if keyForOtherHost {
                    Text("接口地址已更改，原 Key 不会发往新地址，请重新填写").font(.footnote).foregroundStyle(.orange)
                }
                if hasSavedKey || keyForOtherHost {
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
        // 有未保存的 Key 时换成自己的返回按钮，先保存再离开；隐藏系统返回按钮也会关掉侧滑返回，免得 Key 悄悄丢掉
        .navigationBarBackButtonHidden(hasUnsavedKey)
        .toolbar {
            if hasUnsavedKey {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: goBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("返回")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        // settings 是列表页的副本，列表页收到别处保存的通知时已重新读取，这里保存的不是旧副本
        .onAppear(perform: refreshKeyState)
        .onReceive(NotificationCenter.default.publisher(for: AIConfigStore.didChangeNotification)) { _ in
            refreshKeyState()
        }
        .onChange(of: provider) {
            // 列表页的 onChange 不在屏幕上时不一定触发，这里也保存一次
            if exists { store.save(settings) }
            testState = .idle
            refreshKeyState()
        }
        .onChange(of: keyInput) { _, newValue in
            // 开始输入新 Key 时，进行中或已有的测试结果不再对应当前 Key
            if !newValue.isEmpty { testState = .idle }
        }
        .onChange(of: focusedField) { oldValue, _ in
            // 不按回车直接离开 Key 输入框时也保存，否则要等退出页面才写入
            if oldValue == .apiKey { saveKeyIfNeeded() }
        }
        // 兜底：被上层直接关掉等没经过返回按钮的情况
        .onDisappear { saveKeyIfNeeded() }
        .alert("API Key 尚未保存", isPresented: $confirmingDiscardKey) {
            Button("继续编辑", role: .cancel) {
                // 地址无效时定位到地址栏，否则回到 Key 输入框
                focusedField = provider.validatedBaseURL == nil ? .baseURL : .apiKey
            }
            Button("放弃 Key", role: .destructive) {
                keyInput = ""
                keyError = nil
                dismiss()
            }
        } message: {
            Text(keyError ?? "API Key 保存失败")
        }
        .confirmationDialog("删除「\(provider.providerDisplayName)」？", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteProvider)
        } message: {
            Text("这个服务商的 API Key 也会一并删除。")
        }
        .sheet(item: $modelPicker) { request in
            ModelPickerSheet(provider: request.provider, apiKey: request.apiKey) { model in
                providerBinding.wrappedValue.model = model
            }
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
            try store.saveAPIKey(trimmed, for: provider)
            keyInput = ""
            testState = .idle
            refreshKeyState()
            keyError = nil
            onKeyChange()
            return true
        } catch AIConfigError.invalidBaseURL {
            // Key 要绑定接口主机，地址无效时没法保存
            keyError = "请先填写以 https:// 开头的接口地址，再保存 Key"
            return false
        } catch {
            keyError = "API Key 保存失败，请重试"
            return false
        }
    }

    /// 先保存输入的 Key，存不进去时提示，不直接离开
    private func goBack() {
        focusedField = nil
        if saveKeyIfNeeded() {
            dismiss()
        } else {
            confirmingDiscardKey = true
        }
    }

    private func refreshKeyState() {
        hasSavedKey = store.loadAPIKey(for: provider) != nil
        keyForOtherHost = store.hasKeyForOtherHost(provider)
    }

    private func clearKey() {
        do {
            try store.saveAPIKey("", for: provider)
            keyInput = ""
            // 测试进行中清除 Key，结果不能再显示成功
            testState = .idle
            refreshKeyState()
            keyError = nil
            onKeyChange()
        } catch {
            keyError = "清除失败，请重试"
        }
    }

    private func openModelPicker() {
        focusedField = nil
        // 先存好刚输入的 Key，同测试连接；写入失败时 Key 区已显示错误，不弹出
        guard saveKeyIfNeeded() else { return }
        modelPicker = ModelPickerRequest(provider: provider, apiKey: store.loadAPIKey(for: provider))
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
        guard let key = store.loadAPIKey(for: tested), tested.isComplete(apiKey: key) else {
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
            // 测试连接时附上响应体，方便排查模型名、参数等 400 错误
            result = .failure(error.detailedMessage)
        } catch {
            result = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
        // 等待期间用户改了配置或 Key 时状态已复位，旧请求的结果不再对应当前配置，丢弃
        guard provider == tested, store.loadAPIKey(for: provider) == key, testState == .testing else { return }
        testState = result
    }
}
