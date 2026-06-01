import SwiftUI
import SwiftData

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
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

    @State private var selectedTagIDs: Set<PersistentIdentifier> = []
    @State private var searchText = ""
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var showTimeFilter = false

    private var fillRatio: Double {
        min(1.0, Double(entries.count) / 50.0)
    }

    private var filteredEntries: [Entry] {
        var list = entries
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchText
            list = list.filter { entry in
                entry.title.localizedStandardContains(q) ||
                iOSNoteEditorModel.plainText(from: entry.bodyText).localizedStandardContains(q) ||
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
                    JarView(
                        fillRatio: fillRatio,
                        mainColor: Color(hex: group.colorHex),
                        symbolName: group.iconSymbol
                    )
                    .frame(width: 130, height: 160)
                    .padding(.top, 16)

                    Text("\(entries.count) 颗")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textSecondary)

                    PrimaryButton(title: entries.isEmpty ? "还没有可以取出的微笑" : "随机看一颗") {
                        if !entries.isEmpty {
                            randomEntry = entries.randomElement()
                        }
                    }
                    .disabled(entries.isEmpty)
                    .opacity(entries.isEmpty ? 0.5 : 1)

                    if entries.isEmpty {
                        EmptyStateView(icon: "tray",
                                       message: "这个罐子还是空的\n回主屏点 ＋ 添加第一条记录")
                    } else {
                        // 搜索 + 时间筛选
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
                            onTap: { selectedEntry = $0 },
                            highlightedEntryID: highlightedEntryID
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
    }
}
