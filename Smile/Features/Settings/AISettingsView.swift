import SwiftUI

struct AISettingsView: View {
    private let store = AIConfigStore()

    @State private var settings = AISettings.default
    @State private var loaded = false
    /// 已保存 Key 的服务商，列表里据此标「未填 Key」
    @State private var providersWithKey: Set<UUID> = []
    @State private var editingProviderID: UUID?
    @State private var pendingDeletion: AIProvider?
    @State private var deleteError: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        Form {
            Section("服务商") {
                ForEach(settings.providers) { provider in
                    providerRow(provider)
                }
                .onDelete { offsets in
                    pendingDeletion = offsets.first.map { settings.providers[$0] }
                }
                Menu {
                    ForEach(AIPreset.allCases) { preset in
                        Button(preset.displayName) { addProvider(preset) }
                    }
                } label: {
                    Label("添加服务商", systemImage: "plus")
                }
            }

            Section {
                Picker("风格", selection: $settings.style) {
                    ForEach(FormattingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.style == .custom {
                    TextEditor(text: $settings.customPrompt)
                        .frame(minHeight: 120)
                        .focused($promptFocused)
                }
            } header: {
                Text("整理风格")
            } footer: {
                Text("整理时会把标题和正文文字发送给启用中的服务商，不发送照片、视频和语音。API Key 仅保存在本机钥匙串。")
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        // 自定义提示词的 TextEditor 回车只会换行，Form 默认也不会因滑动或点空白收起键盘，需另给收起的办法
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { promptFocused = false }
            }
        }
        .navigationDestination(item: $editingProviderID) { id in
            AIProviderEditView(settings: $settings, providerID: id, store: store, onKeyChange: refreshKeys)
        }
        .onAppear {
            if !loaded {
                loaded = true
                settings = store.load()
            }
            refreshKeys()
        }
        .onChange(of: settings) { _, newValue in store.save(newValue) }
        .confirmationDialog("删除「\(pendingDeletion?.providerDisplayName ?? "")」？",
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDeletion) { provider in
            Button("删除", role: .destructive) { delete(provider) }
        } message: { _ in
            Text("这个服务商的 API Key 也会一并删除。")
        }
        .alert("删除失败，请重试", isPresented: Binding(get: { deleteError != nil },
                                                    set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { }
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        HStack {
            Button {
                settings.activeProviderID = provider.id
            } label: {
                HStack {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .opacity(provider.id == settings.activeProviderID ? 1 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.providerDisplayName)
                            .foregroundStyle(.primary)
                        Text(provider.trimmedModel.isEmpty ? "未填模型" : provider.trimmedModel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !providersWithKey.contains(provider.id) {
                        Text("未填 Key")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(provider.id == settings.activeProviderID ? .isSelected : [])

            Button {
                editingProviderID = provider.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑\(provider.providerDisplayName)")
        }
    }

    private func addProvider(_ preset: AIPreset) {
        let provider = AIProvider.make(preset: preset)
        settings.providers.append(provider)
        if settings.activeProvider == nil { settings.activeProviderID = provider.id }
        editingProviderID = provider.id
    }

    private func delete(_ provider: AIProvider) {
        do {
            settings = try store.removeProvider(id: provider.id, from: settings)
            refreshKeys()
        } catch {
            deleteError = "删除失败，请重试"
        }
    }

    private func refreshKeys() {
        providersWithKey = Set(settings.providers.map(\.id).filter { store.loadAPIKey(for: $0) != nil })
    }
}
