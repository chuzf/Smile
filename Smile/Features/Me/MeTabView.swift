import SwiftUI
import SwiftData

struct MeTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Group.sortOrder)]) private var groups: [Group]

    @State private var globalSearch = ""
    @State private var editingGroup: Group? = nil
    @State private var deleteBlockedGroup: Group? = nil

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
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !g.isBuiltIn {
                                Button(role: .destructive) {
                                    if g.canDelete {
                                        context.delete(g)
                                        try? context.save()
                                    } else {
                                        deleteBlockedGroup = g
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    editingGroup = g
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
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
            .sheet(item: $editingGroup) { group in
                EditGroupSheet(group: group)
            }
            .alert("无法删除", isPresented: Binding(
                get: { deleteBlockedGroup != nil },
                set: { if !$0 { deleteBlockedGroup = nil } }
            )) {
                Button("好的", role: .cancel) { deleteBlockedGroup = nil }
            } message: {
                Text("储蓄罐里还有内容，请先清空再删除。")
            }
        }
    }
}
