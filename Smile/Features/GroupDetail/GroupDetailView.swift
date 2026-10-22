import SwiftUI
import SwiftData

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LockSessionManager.self) private var lockSession

    let group: Group
    let highlightEntryID: UUID?

    @Query private var entries: [Entry]
    @Query(sort: [SortDescriptor(\Tag.name)]) private var allTags: [Tag]

    init(group: Group, highlightEntryID: UUID? = nil) {
        self.group = group
        self.highlightEntryID = highlightEntryID
        let groupID = group.id
        _entries = Query(
            filter: #Predicate<Entry> { $0.group?.id == groupID },
            sort: [SortDescriptor(\Entry.createdAt, order: .reverse)]
        )
        _highlightedEntryID = State(initialValue: highlightEntryID)
    }

    @State private var highlightedEntryID: UUID?
    @State private var pendingHighlightID: UUID?
    @State private var showAddEntry = false
    @State private var randomEntry: Entry?
    @State private var selectedEntry: Entry?
    @State private var showUnlockBanner = true

    @State private var selectedTagIDs: Set<PersistentIdentifier> = []
    @State private var searchText = ""
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var showTimeFilter = false
    /// 引用类型：在 body 求值期间读写缓存不会触发「修改 state」
    @State private var plainTextCache = PlainTextCache()

    private var isGroupUnlocked: Bool {
        lockSession.isGroupUnlocked(group.id)
    }

    private var fillRatio: Double {
        min(1.0, Double(entries.count) / 50.0)
    }

    private func cachedPlainText(for entry: Entry) -> String {
        plainTextCache.text(for: entry)
    }

    private var filteredEntries: [Entry] {
        var list = entries
        let isFiltering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTagIDs.isEmpty
        if isFiltering {
            // 未解锁的加锁条目不参与搜索和标签筛选，免得靠「筛得出来」反推内容
            list = list.filter { !$0.isLocked || lockSession.isEntryUnlocked($0.id) }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText
            list = list.filter { entry in
                entry.title.localizedStandardContains(q) ||
                cachedPlainText(for: entry).localizedStandardContains(q) ||
                entry.attachments.contains { $0.transcript?.localizedStandardContains(q) ?? false } ||
                entry.tags.contains { $0.name.localizedStandardContains(q) }
            }
        }
        if !selectedTagIDs.isEmpty {
            list = list.filter { entry in
                let entryTagIDs = Set(entry.tags.map { $0.persistentModelID })
                return !entryTagIDs.isDisjoint(with: selectedTagIDs)
            }
        }
        if let from = dateFrom {
            list = list.filter { $0.createdAt >= from }
        }
        if let to = dateTo {
            list = list.filter { $0.createdAt <= to }
        }
        return list
    }

    var body: some View {
        ZStack {
            AppColors.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if group.isLocked && isGroupUnlocked && showUnlockBanner {
                        UnlockBanner(onDismiss: { showUnlockBanner = false })
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    JarView(
                        fillRatio: fillRatio,
                        mainColor: Color(hex: group.colorHex),
                        symbolName: group.iconSymbol
                    )
                    .frame(width: 130, height: 160)
                    .padding(.top, group.isLocked && isGroupUnlocked && showUnlockBanner ? 0 : 16)

                    Text("\(entries.count) 颗")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textSecondary)

                    PrimaryButton(title: entries.isEmpty ? "还没有可以取出的微笑" : "随机看一颗") {
                        if !entries.isEmpty {
                            let unlockable = entries.filter {
                                !$0.isLocked || lockSession.isEntryUnlocked($0.id)
                            }
                            randomEntry = unlockable.isEmpty ? nil : unlockable.randomElement()
                        }
                    }
                    .disabled(entries.isEmpty)
                    .opacity(entries.isEmpty ? 0.5 : 1)

                    if entries.isEmpty {
                        EmptyStateView(icon: "tray",
                                       message: "这个罐子还是空的\n回主屏点 ＋ 添加第一条记录")
                    } else {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(AppColors.textSecondary)
                            TextField("搜索这个分组", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                            Button {
                                showTimeFilter = true
                            } label: {
                                Image(systemName: dateFrom != nil ? "calendar.badge.checkmark" : "calendar")
                                    .foregroundStyle(AppColors.warmOrange)
                            }
                        }
                        .padding(12)
                        .background(AppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 14)

                        if !allTags.isEmpty {
                            TagFilterBar(allTags: allTags, selectedTagIDs: $selectedTagIDs)
                        }

                        TimelineList(
                            entries: filteredEntries,
                            onTap: { handleEntryTap($0) },
                            highlightedEntryID: highlightedEntryID,
                            isEntryLocked: { entry in
                                entry.isLocked && !lockSession.isEntryUnlocked(entry.id)
                            },
                            isEntryUnlocked: { entry in
                                entry.isLocked && lockSession.isEntryUnlocked(entry.id)
                            }
                        )
                    }
                }
                .padding(.bottom, 30)
            }
            // 搜索后往下翻结果时收起键盘，不然键盘挡住半屏结果
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showAddEntry = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddEntry, onDismiss: {
            if let id = pendingHighlightID {
                highlightedEntryID = id
                pendingHighlightID = nil
            }
        }) {
            iOSNoteEditorView(
                initialGroupID: group.persistentModelID,
                onSaved: { _, entryID in pendingHighlightID = entryID }
            )
        }
        .sheet(item: $randomEntry) { entry in
            RandomRecallSheet(entry: entry, onNext: {
                let unlockable = entries.filter {
                    !$0.isLocked || lockSession.isEntryUnlocked($0.id)
                }
                randomEntry = unlockable.isEmpty ? nil : unlockable.randomElement()
            })
        }
        .sheet(isPresented: $showTimeFilter) {
            TimeFilterSheet(from: $dateFrom, to: $dateTo)
        }
        .navigationDestination(item: $selectedEntry) { entry in
            EntryDetailView(entry: entry)
        }
        .onChange(of: entries) { _, newEntries in
            if let sel = selectedEntry, !newEntries.contains(where: { $0.id == sel.id }) {
                selectedEntry = nil
            }
            let currentIDs = Set(newEntries.map { $0.id })
            plainTextCache.prune(keeping: currentIDs)
        }
        .onChange(of: group.isLocked) { _, _ in
            showUnlockBanner = true
        }
        .displaysLockedContent(group.isLocked)
        .onChange(of: allTags) { _, tags in
            // 标签被删后去掉残留的筛选，否则看不到也取消不了
            selectedTagIDs.formIntersection(tags.map(\.persistentModelID))
        }
        .onChange(of: lockSession.relockEpoch) { _, _ in
            // 全部重新上锁后，退出正在查看的加锁条目
            if selectedEntry?.isLocked == true { selectedEntry = nil }
            if randomEntry?.isLocked == true { randomEntry = nil }
        }
    }

    private func handleEntryTap(_ entry: Entry) {
        Task { @MainActor in
            if entry.isLocked && !lockSession.isEntryUnlocked(entry.id) {
                guard await lockSession.unlockEntry(entry.id) else { return }
            }
            selectedEntry = entry
        }
    }
}

// MARK: - Unlock Banner

private struct UnlockBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.warmOrange)

            VStack(alignment: .leading, spacing: 1) {
                Text("已解锁")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.warmOrange)
                Text("\(Int(LockSessionManager.unlockDuration / 60)) 分钟后自动重新锁定")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(6)
            }
        }
        .padding(12)
        .background(AppColors.warmOrange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.warmOrange.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private final class PlainTextCache {
    private var storage: [UUID: (updatedAt: Date, text: String)] = [:]

    func text(for entry: Entry) -> String {
        // 带上 updatedAt：条目被编辑后缓存自动失效
        if let hit = storage[entry.id], hit.updatedAt == entry.updatedAt { return hit.text }
        let text = iOSNoteEditorModel.plainText(from: entry.bodyText)
        storage[entry.id] = (entry.updatedAt, text)
        return text
    }

    func prune(keeping ids: Set<UUID>) {
        storage = storage.filter { ids.contains($0.key) }
    }
}
