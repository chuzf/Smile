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
    @State private var plainTextCache: [UUID: String] = [:]

    private var isGroupUnlocked: Bool {
        lockSession.isGroupUnlocked(group.id)
    }

    private var fillRatio: Double {
        min(1.0, Double(entries.count) / 50.0)
    }

    private func cachedPlainText(for entry: Entry) -> String {
        if let cached = plainTextCache[entry.id] { return cached }
        let text = iOSNoteEditorModel.plainText(from: entry.bodyText)
        plainTextCache[entry.id] = text
        return text
    }

    private var filteredEntries: [Entry] {
        var list = entries
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
                            }
                        )
                    }
                }
                .padding(.bottom, 30)
            }
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
                randomEntry = entries.randomElement()
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
            plainTextCache = plainTextCache.filter { currentIDs.contains($0.key) }
        }
        .onChange(of: group.isLocked) { _, _ in
            showUnlockBanner = true
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
