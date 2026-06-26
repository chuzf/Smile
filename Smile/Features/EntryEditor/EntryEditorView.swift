import SwiftUI
import SwiftData
import PhotosUI

struct EntryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == true },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var builtinGroups: [Group]

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == false },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var customGroups: [Group]

    let editingEntryID: PersistentIdentifier?
    let initialGroupID: PersistentIdentifier?
    let onSaved: ((UUID, UUID) -> Void)?   // (groupID, entryID)
    @State private var model = EntryEditorModel()

    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var entryDraftID = UUID()
    @State private var showVoiceRecorder = false
    @State private var showTagPicker = false

    private var allGroups: [Group] { builtinGroups + customGroups }

    init(editingEntryID: PersistentIdentifier? = nil,
         initialGroupID: PersistentIdentifier? = nil,
         onSaved: ((UUID, UUID) -> Void)? = nil) {
        self.editingEntryID = editingEntryID
        self.initialGroupID = initialGroupID
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("标题", text: $model.title, axis: .vertical)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .onChange(of: model.title) { _, _ in
                                model.titleSource = .manual
                            }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(builtinGroups) { g in groupPill(g) }
                                if !customGroups.isEmpty {
                                    Rectangle()
                                        .fill(AppColors.textSecondary.opacity(0.25))
                                        .frame(width: 1, height: 18)
                                }
                                ForEach(customGroups) { g in groupPill(g) }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }

                        TextEditor(text: $model.bodyText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(AppColors.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topLeading) {
                                if model.bodyText.isEmpty {
                                    Text("此刻发生了什么……")
                                        .foregroundStyle(AppColors.textSecondary.opacity(0.5))
                                        .padding(16)
                                        .allowsHitTesting(false)
                                }
                            }

                        if !model.attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(model.attachments) { draft in
                                        MediaAttachmentChip(
                                            draft: draft,
                                            thumbnail: thumbnails[draft.id]
                                        ) {
                                            removeAttachment(draft)
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 18) {
                            PhotosPicker(
                                selection: $photoPickerItems,
                                maxSelectionCount: 9,
                                matching: .images
                            ) {
                                Label("照片", systemImage: "photo.on.rectangle")
                            }
                            Button {
                                showVoiceRecorder = true
                            } label: {
                                Label("语音", systemImage: "mic")
                            }
                            Button {
                                showTagPicker = true
                            } label: {
                                Label("标签", systemImage: "number")
                            }
                            Spacer()
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.warmOrange)
                        .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(dateLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { initialize() }
            .onChange(of: photoPickerItems) { _, newItems in
                Task { await loadPickedItems(newItems) }
            }
            .sheet(isPresented: $showVoiceRecorder) {
                VoiceRecorderView(entryDraftID: entryDraftID) { draft in
                    model.attachments.append(draft)
                }
            }
            .sheet(isPresented: $showTagPicker) {
                TagPickerSheet(selected: $model.selectedTags)
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceTranscribed)) { note in
                guard let info = note.userInfo,
                      let draftID = info["draftID"] as? UUID,
                      let transcript = info["transcript"] as? String,
                      let idx = model.attachments.firstIndex(where: { $0.id == draftID })
                else { return }
                model.attachments[idx].transcript = transcript
            }
        }
    }

    @ViewBuilder
    private func groupPill(_ g: Group) -> some View {
        let selected = model.selectedGroupID == g.persistentModelID
        Button { model.selectedGroupID = g.persistentModelID } label: {
            HStack(spacing: 4) {
                Image(systemName: g.iconSymbol)
                Text(g.name)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(
                selected ? Color(hex: g.colorHex) : Color(hex: g.colorHex).opacity(0.15)
            ))
            .foregroundStyle(selected ? Color.white : Color(hex: g.colorHex))
        }
        .buttonStyle(.plain)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: model.createdAt)
    }

    private var canSave: Bool {
        model.selectedGroupID != nil &&
        (!model.bodyText.isEmpty || !model.attachments.isEmpty || !model.title.isEmpty)
    }

    private func initialize() {
        if let editID = editingEntryID,
           let entry = try? context.fetch(FetchDescriptor<Entry>()).first(where: { $0.persistentModelID == editID }) {
            model.load(from: entry)
            entryDraftID = entry.id
        } else {
            model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
        }
    }

    @MainActor
    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        let mediaStore = MediaStore.production()
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let filename = "photo-\(UUID().uuidString.prefix(8)).heic"
            guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else { continue }

            var draft = DraftAttachment(kind: .photo, relativePath: relPath)

            if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data) {
                let thumbName = "thumb-\(UUID().uuidString.prefix(6)).jpg"
                _ = try? mediaStore.save(data: thumbData, entryID: entryDraftID, filename: thumbName)
                if let img = UIImage(data: thumbData) {
                    thumbnails[draft.id] = img
                }
            }

            draft.persistedID = nil
            model.attachments.append(draft)
        }
        photoPickerItems.removeAll()
    }

    private func removeAttachment(_ draft: DraftAttachment) {
        let mediaStore = MediaStore.production()
        try? mediaStore.delete(relativePath: draft.relativePath)
        thumbnails.removeValue(forKey: draft.id)
        model.attachments.removeAll { $0.id == draft.id }
    }

    private func save() {
        guard let groupID = model.selectedGroupID,
              let group = allGroups.first(where: { $0.persistentModelID == groupID })
        else { return }

        Task { @MainActor in
            // 1. 本地标题
            if model.titleSource != .manual {
                let combined = combinedTextForTitling()
                let quick = combined.isEmpty
                    ? Self.dateFallback(date: model.createdAt, groupName: group.name)
                    : Self.firstSentence(from: combined, maxChars: 20)
                if !quick.isEmpty { model.title = quick }
                model.titleSource = .auto
            }

            // 2. 入库 entry
            let entry: Entry
            if let editID = editingEntryID,
               let existing = try? context.fetch(FetchDescriptor<Entry>()).first(where: { $0.persistentModelID == editID }) {
                existing.title = model.title
                existing.titleSource = model.titleSource
                existing.bodyText = model.bodyText
                existing.group = group
                existing.updatedAt = .now
                entry = existing
            } else {
                let new = Entry(
                    title: model.title,
                    titleSource: model.titleSource,
                    bodyText: model.bodyText,
                    createdAt: model.createdAt,
                    updatedAt: .now,
                    group: group
                )
                new.id = entryDraftID
                context.insert(new)
                entry = new
            }

            // 3. 标签 reconcile
            let allTagsList = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
            entry.tags = allTagsList.filter { model.selectedTags.contains($0.persistentModelID) }

            // 4. 附件 reconcile
            let modelDraftIDs = Set(model.attachments.compactMap { $0.persistedID })
            for existing in entry.attachments where !modelDraftIDs.contains(existing.persistentModelID) {
                context.delete(existing)
            }
            for (idx, draft) in model.attachments.enumerated() where draft.persistedID == nil {
                let att = MediaAttachment(
                    kind: draft.kind,
                    relativePath: draft.relativePath,
                    durationSeconds: draft.durationSeconds,
                    transcript: draft.transcript,
                    sortOrder: idx,
                    entry: entry
                )
                context.insert(att)
            }
            for (idx, draft) in model.attachments.enumerated() {
                if let pid = draft.persistedID,
                   let existing = entry.attachments.first(where: { $0.persistentModelID == pid }) {
                    existing.sortOrder = idx
                    existing.transcript = draft.transcript
                }
            }

            try? context.save()
            onSaved?(group.id, entry.id)
            dismiss()
        }
    }

    private func combinedTextForTitling() -> String {
        var pieces: [String] = []
        if !model.bodyText.isEmpty { pieces.append(model.bodyText) }
        for att in model.attachments where att.kind == .voice {
            if let t = att.transcript, !t.isEmpty { pieces.append(t) }
        }
        return pieces.joined(separator: "\n")
    }

    private static func firstSentence(from text: String, maxChars: Int) -> String {
        let delimiters: Set<Character> = ["。", ".", "！", "!", "？", "?", "\n"]
        var sentence = ""
        for ch in text {
            if delimiters.contains(ch) { break }
            sentence.append(ch)
            if sentence.count >= maxChars { break }
        }
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    private static func dateFallback(date: Date, groupName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: date)) · \(groupName)"
    }
}
