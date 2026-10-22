import SwiftUI
import SwiftData

struct MeTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(LockSessionManager.self) private var lockSession
    @Query(sort: [SortDescriptor(\Group.sortOrder)]) private var groups: [Group]
    @Query(sort: [SortDescriptor(\Tag.name)]) private var allTags: [Tag]

    @State private var globalSearch = ""
    @State private var searchResults: [Entry] = []
    @State private var searchNavEntry: Entry?
    @State private var editingGroup: Group? = nil
    @State private var deleteBlockedGroup: Group? = nil
    @State private var editingTag: Tag? = nil
    @State private var deletingTag: Tag? = nil

    var body: some View {
        NavigationStack {
            List {
                searchSection
                groupSection
                tagSection
                settingsSection
            }
            // 搜索后往下翻结果时收起键盘，不然键盘挡住半屏结果
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("我")
            .navigationDestination(item: $searchNavEntry) { entry in
                EntryDetailView(entry: entry)
            }
            .task(id: SearchKey(query: globalSearch, unlocked: lockSession.unlockedGroupIDs.union(lockSession.unlockedEntryIDs))) {
                // 不在 body 里搜：每次刷新都全量取一遍；输入停顿后再搜
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                searchResults = (try? SearchService.search(
                    in: context, query: globalSearch, group: nil,
                    isSearchable: isAccessible
                )) ?? []
            }
            .onChange(of: lockSession.relockEpoch) { _, _ in
                // 全部重新上锁后，退出从搜索打开的加锁条目
                if let e = searchNavEntry, e.isLocked || (e.group?.isLocked ?? false) {
                    searchNavEntry = nil
                }
            }
            .sheet(item: $editingGroup) { group in
                EditGroupSheet(group: group)
            }
            .sheet(item: $editingTag) { tag in
                EditTagSheet(tag: tag)
            }
            .alert("无法删除", isPresented: Binding(
                get: { deleteBlockedGroup != nil },
                set: { if !$0 { deleteBlockedGroup = nil } }
            )) {
                Button("好的", role: .cancel) { deleteBlockedGroup = nil }
            } message: {
                Text("储蓄罐里还有内容，请先清空再删除。")
            }
            .alert("删除标签", isPresented: Binding(
                get: { deletingTag != nil },
                set: { if !$0 { deletingTag = nil } }
            )) {
                Button("取消", role: .cancel) { deletingTag = nil }
                Button("删除", role: .destructive) {
                    if let tag = deletingTag {
                        context.delete(tag)
                        try? context.save()
                    }
                    deletingTag = nil
                }
            } message: {
                if let tag = deletingTag {
                    Text("该标签用于 \(tag.entries.count) 条记录，删除后会从这些记录移除。")
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.textSecondary)
                TextField("全局搜索所有记录", text: $globalSearch)
            }
        }
        if !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            Section("搜索结果") {
                let results = searchResults
                if results.isEmpty {
                    Text("没找到匹配的记录").foregroundStyle(AppColors.textSecondary)
                } else {
                    ForEach(results) { e in
                        let entryLocked = e.isLocked && !lockSession.isEntryUnlocked(e.id)
                        let groupLocked = (e.group?.isLocked ?? false) && !lockSession.isGroupUnlocked(e.group?.id ?? UUID())
                        let isLocked = entryLocked || groupLocked
                        Button {
                            handleSearchResultTap(e)
                        } label: {
                            VStack(alignment: .leading) {
                                if isLocked {
                                    Label("已锁定条目", systemImage: "lock.fill")
                                        .foregroundStyle(AppColors.warmOrange)
                                    Text(e.group?.name ?? "—")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                } else {
                                    Text(e.title.isEmpty ? "(无标题)" : e.title)
                                    Text(e.group?.name ?? "—")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupSection: some View {
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
    }

    @ViewBuilder
    private var tagSection: some View {
        Section("标签管理") {
            if allTags.isEmpty {
                Text("还没有标签，在编辑记录时可以新建")
                    .foregroundStyle(AppColors.textSecondary)
            }
            ForEach(allTags) { tag in
                HStack {
                    Circle()
                        .fill(Color(hex: tag.colorHex))
                        .frame(width: 10, height: 10)
                    Text(tag.name)
                    Spacer()
                    Text("\(tag.entries.count)")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        if tag.entries.isEmpty {
                            context.delete(tag)
                            try? context.save()
                        } else {
                            deletingTag = tag
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editingTag = tag
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        Section("设置") {
            NavigationLink {
                SettingsView()
            } label: {
                Label("App 设置", systemImage: "gearshape")
            }
        }
    }

    private func isAccessible(_ e: Entry) -> Bool {
        let entryLocked = e.isLocked && !lockSession.isEntryUnlocked(e.id)
        let groupLocked = (e.group?.isLocked ?? false) && !lockSession.isGroupUnlocked(e.group?.id ?? UUID())
        return !entryLocked && !groupLocked
    }

    private struct SearchKey: Equatable {
        let query: String
        let unlocked: Set<UUID>
    }

    private func handleSearchResultTap(_ entry: Entry) {
        Task { @MainActor in
            if (entry.group?.isLocked ?? false) && !lockSession.isGroupUnlocked(entry.group?.id ?? UUID()) {
                guard await lockSession.unlockGroup(entry.group!.id) else { return }
            }
            if entry.isLocked && !lockSession.isEntryUnlocked(entry.id) {
                guard await lockSession.unlockEntry(entry.id) else { return }
            }
            searchNavEntry = entry
        }
    }
}
