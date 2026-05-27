import SwiftUI
import SwiftData

struct MeTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Group.sortOrder)]) private var groups: [Group]

    @State private var globalSearch = ""
    @State private var editingGroupID: UUID? = nil
    @State private var draftName: String = ""
    @FocusState private var isEditFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppColors.textSecondary)
                        TextField("全局搜索所有记录", text: $globalSearch)
                    }
                }
                if !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("搜索结果") {
                        let results = (try? SearchService.search(in: context, query: globalSearch, group: nil)) ?? []
                        if results.isEmpty {
                            Text("没找到匹配的记录").foregroundStyle(AppColors.textSecondary)
                        } else {
                            ForEach(results) { e in
                                NavigationLink {
                                    EntryDetailView(entry: e)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(e.title.isEmpty ? "(无标题)" : e.title)
                                        Text(e.group?.name ?? "—")
                                            .font(.caption)
                                            .foregroundStyle(AppColors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("分组管理") {
                    ForEach(groups) { g in
                        if editingGroupID == g.id {
                            HStack {
                                Image(systemName: g.iconSymbol)
                                    .foregroundStyle(Color(hex: g.colorHex))
                                TextField("分组名称", text: $draftName)
                                    .focused($isEditFocused)
                                    .onSubmit { commitEdit() }
                                Spacer()
                                Button { cancelEdit() } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                .buttonStyle(.plain)
                                Button { commitEdit() } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppColors.warmOrange)
                                }
                                .buttonStyle(.plain)
                                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .deleteDisabled(true)
                        } else {
                            HStack {
                                Image(systemName: g.iconSymbol)
                                    .foregroundStyle(Color(hex: g.colorHex))
                                Text(g.name)
                                Spacer()
                                Text("\(g.entries.count)")
                                    .foregroundStyle(AppColors.textSecondary)
                                if g.isBuiltIn {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                } else {
                                    Button { startEdit(g) } label: {
                                        Image(systemName: "pencil")
                                            .foregroundStyle(AppColors.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .deleteDisabled(!g.canDelete)
                        }
                    }
                    .onDelete(perform: deleteCustom)
                }

                Section("设置") {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("App 设置", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("我")
        }
    }

    private func deleteCustom(at offsets: IndexSet) {
        for idx in offsets {
            let g = groups[idx]
            guard g.canDelete else { continue }
            context.delete(g)
        }
        try? context.save()
    }

    private func startEdit(_ group: Group) {
        draftName = group.name
        editingGroupID = group.id
        Task { @MainActor in
            isEditFocused = true
        }
    }

    private func commitEdit() {
        guard let id = editingGroupID,
              let group = groups.first(where: { $0.id == id }) else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        try? context.save()
        cancelEdit()
    }

    private func cancelEdit() {
        editingGroupID = nil
        draftName = ""
        isEditFocused = false
    }
}
