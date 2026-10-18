import SwiftUI

struct AISettingsView: View {
    private let store = AIConfigStore()

    @State private var config = AIConfig.default
    @State private var loaded = false
    @State private var hasSavedKey = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("服务商") {
                Picker("服务商", selection: presetBinding) {
                    ForEach(AIPreset.allCases) { Text($0.displayName).tag($0) }
                }
                if config.preset == .custom {
                    Picker("接口协议", selection: $config.apiProtocol) {
                        ForEach(AIProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                TextField("接口地址", text: $config.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !config.baseURL.isEmpty && config.validatedBaseURL == nil {
                    Text("请填写以 https:// 开头的地址").font(.footnote).foregroundStyle(.red)
                }
                TextField("模型", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if config.preset == .doubao {
                    Text("填写方舟控制台中的模型 ID 或接入点 ID").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("API Key") {
                SecureField(hasSavedKey ? "已保存（输入新值可覆盖）" : "粘贴 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { saveKeyIfNeeded() }
                if hasSavedKey {
                    Button("清除 Key", role: .destructive, action: clearKey)
                }
                if let keyError {
                    Text(keyError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("整理风格") {
                Picker("风格", selection: $config.style) {
                    ForEach(FormattingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                if config.style == .custom {
                    TextEditor(text: $config.customPrompt)
                        .frame(minHeight: 120)
                }
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        testStatusView
                    }
                }
                .disabled(testState == .testing)
            } footer: {
                Text("整理时会把标题和正文文字发送给你配置的服务商，不发送照片、视频和语音。API Key 仅保存在本机钥匙串。")
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            config = store.load()
            hasSavedKey = store.loadAPIKey() != nil
        }
        .onChange(of: config) { _, newValue in
            store.save(newValue)
            testState = .idle
        }
        .onDisappear { saveKeyIfNeeded() }
    }

    private var presetBinding: Binding<AIPreset> {
        Binding(
            get: { config.preset },
            set: { config = config.applyingPreset($0) }
        )
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
        guard !trimmed.isEmpty else { return true }
        do {
            try store.saveAPIKey(trimmed)
            keyInput = ""
            hasSavedKey = true
            keyError = nil
            return true
        } catch {
            keyError = "API Key 保存失败，请重试"
            return false
        }
    }

    private func clearKey() {
        do {
            try store.saveAPIKey("")
            keyInput = ""
            hasSavedKey = false
            keyError = nil
        } catch {
            keyError = "清除失败，请重试"
        }
    }

    @MainActor
    private func testConnection() async {
        // Key 没写进去时不能拿旧 Key 去测
        guard saveKeyIfNeeded() else { return }
        guard let key = store.loadAPIKey(), config.isComplete(apiKey: key) else {
            testState = .failure(LLMError.notConfigured.userMessage)
            return
        }
        testState = .testing
        do {
            let client = try LLMClientFactory.make(config: config, apiKey: key)
            _ = try await client.complete(system: "只回复 OK", user: "ping")
            testState = .success
        } catch let error as LLMError {
            // 测试连接时附上响应体，方便排查模型名、参数等 400 错误；响应体里不含 Key
            if case .http(_, let body) = error, !body.isEmpty {
                testState = .failure(error.userMessage + "\n" + body)
            } else {
                testState = .failure(error.userMessage)
            }
        } catch {
            testState = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
    }
}
