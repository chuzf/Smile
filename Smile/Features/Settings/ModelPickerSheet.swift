import SwiftUI

/// 从服务商拉取模型列表供选择；每次打开都重新拉取，不缓存
struct ModelPickerSheet: View {
    let provider: AIProvider
    let apiKey: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var query = ""
    /// 点「重试」时加一，重新触发 .task
    @State private var attempt = 0

    private enum LoadState: Equatable {
        case loading
        case missingConfig
        case failure(String)
        case loaded([String])
    }

    private var filteredModels: [String] {
        guard case .loaded(let models) = state else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("选择模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missingConfig:
            ContentUnavailableView("请先填写接口地址和 API Key", systemImage: "key")
        case .failure(let message):
            ContentUnavailableView {
                Label("获取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { attempt += 1 }
            }
        case .loaded(let models) where models.isEmpty:
            ContentUnavailableView("服务商没有返回模型，请手动填写", systemImage: "tray")
        case .loaded:
            List(filteredModels, id: \.self) { model in
                Button {
                    onSelect(model)
                    dismiss()
                } label: {
                    HStack {
                        Text(model).foregroundStyle(.primary)
                        Spacer()
                        if model == provider.trimmedModel {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            .overlay {
                if filteredModels.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
    }

    @MainActor
    private func load() async {
        guard let apiKey, provider.validatedBaseURL != nil else {
            state = .missingConfig
            return
        }
        state = .loading
        do {
            state = .loaded(try await LLMClientFactory.listModels(provider: provider, apiKey: apiKey))
        } catch is CancellationError {
            // 关闭 sheet 时请求随 .task 取消，不提示
        } catch LLMError.emptyResponse {
            // 通用文案说的是「整理结果」，列模型时换成专用的
            state = .failure("服务商返回的模型列表无法识别，请手动填写")
        } catch let error as LLMError {
            state = .failure(error.detailedMessage)
        } catch {
            state = .failure(LLMError.network(error.localizedDescription).userMessage)
        }
    }
}
