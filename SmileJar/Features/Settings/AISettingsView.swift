import SwiftUI

struct AISettingsView: View {
    @AppStorage(AIServiceProvider.aiEnabledKey) private var aiEnabled = false
    @State private var apiKey: String = ""
    @State private var testResult: String?

    private let keychain = KeychainService()

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 自动标题", isOn: $aiEnabled)
            } footer: {
                Text("关闭时使用本地兜底(文本首句)。AI 标题只发送文本和转写内容,不发送图片、视频、音频。")
            }

            Section("Anthropic API Key") {
                SecureField("sk-ant-...", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") {
                    try? keychain.set(AIServiceProvider.keychainAPIKey, value: apiKey.trimmingCharacters(in: .whitespaces))
                    testResult = "已保存"
                }
                Button("测试连接") {
                    Task { await test() }
                }
                if let testResult {
                    Text(testResult)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)
                }
                Link("如何获取 API Key →", destination: URL(string: "https://console.anthropic.com")!)
            }
        }
        .navigationTitle("AI 标题")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = keychain.get(AIServiceProvider.keychainAPIKey) ?? ""
        }
    }

    private func test() async {
        let key = keychain.get(AIServiceProvider.keychainAPIKey) ?? apiKey
        guard !key.isEmpty else { testResult = "请先填入 API Key"; return }
        let svc = ClaudeAIService(apiKey: key)
        do {
            let r = try await svc.generateTitle(
                text: "今天遇到很久未见的老朋友,聊得很开心",
                context: TitleContext(groupName: "微笑储蓄罐", date: .now, hasMedia: false)
            )
            testResult = "✓ 连接成功:\(r)"
        } catch {
            testResult = "✗ 失败:\(error)"
        }
    }
}
