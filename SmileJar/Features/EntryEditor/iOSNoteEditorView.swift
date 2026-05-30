import SwiftUI
import SwiftData
import PhotosUI

struct iOSNoteEditorView: View {
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
    let onSaved: ((UUID, UUID) -> Void)?

    init(editingEntryID: PersistentIdentifier? = nil, initialGroupID: PersistentIdentifier? = nil, onSaved: ((UUID, UUID) -> Void)? = nil) {
        self.editingEntryID = editingEntryID
        self.initialGroupID = initialGroupID
        self.onSaved = onSaved
    }

    @State private var model = iOSNoteEditorModel()
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var entryDraftID = UUID()
    @State private var showVoiceRecorder = false
    @State private var showTagPicker = false
    @State private var showUnsavedAlert = false
    @FocusState private var editorFocused: Bool

    private var allGroups: [Group] { builtinGroups + customGroups }

    var body: some View {
        ZStack {
            AppColors.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                iOSNoteEditorNavBar(
                    dateLabel: dateLabel,
                    isSaving: model.isSaving,
                    onBack: handleBack,
                    onComplete: handleComplete,
                    canComplete: canSave
                )
                Divider()
                GroupSelector(
                    selectedGroupID: $model.selectedGroupID,
                    builtinGroups: builtinGroups,
                    customGroups: customGroups
                )
                Divider()
                editorScrollView
                Divider()
                toolbarRow
            }
        }
        .onAppear {
            initialize()
            if editingEntryID == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editorFocused = true }
            }
        }
        .onDisappear { model.reset(); thumbnails.removeAll() }
        .onChange(of: photoPickerItems) { _, newItems in Task { await loadPickedItems(newItems) } }
        .sheet(isPresented: $showVoiceRecorder) {
            VoiceRecorderView(entryDraftID: entryDraftID) { draft in model.attachments.append(draft) }
        }
        .sheet(isPresented: $showTagPicker) { TagPickerSheet(selected: $model.selectedTags) }
        .alert("未保存的修改", isPresented: $showUnsavedAlert) {
            Button("放弃", role: .destructive) { dismiss() }
            Button("保存") { Task { await save() } }
            Button("继续编辑", role: .cancel) { }
        } message: { Text("有未保存的修改，确定放弃吗？") }
    }

    @ViewBuilder
    private var editorScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $model.editorText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(16)
                    .frame(minHeight: 260)
                    .focused($editorFocused)
                    .onChange(of: model.editorText) { _, _ in model.scheduleAutoSave() }
                attachmentsList
            }
        }
        .onTapGesture { editorFocused = true }
    }

    @ViewBuilder
    private var attachmentsList: some View {
        if !model.attachments.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.attachments) { draft in
                    MediaAttachmentRow(
                        draft: draft,
                        thumbnail: thumbnails[draft.id],
                        onDelete: { removeAttachment(draft) }
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var toolbarRow: some View {
        HStack(spacing: 18) {
            PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 9, matching: .images) {
                Label("照片", systemImage: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.warmOrange)
            }
            Button { showVoiceRecorder = true } label: {
                Label("语音", systemImage: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.warmOrange)
            }
            Button { showTagPicker = true } label: {
                Label("标签", systemImage: "number")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.warmOrange)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Private Methods

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: model.createdAt)
    }

    private var canSave: Bool {
        model.selectedGroupID != nil &&
        (!model.editorText.isEmpty || !model.attachments.isEmpty)
    }

    private func initialize() {
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            if let entry = try? context.fetch(descriptor).first {
                model.load(from: entry)
                entryDraftID = entry.id
            } else {
                model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
            }
        } else {
            model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
        }
    }

    private func handleBack() {
        if model.isDirty {
            showUnsavedAlert = true
        } else {
            dismiss()
        }
    }

    private func handleComplete() {
        Task {
            await save()
        }
    }

    @MainActor
    private func save() async {
        guard let groupID = model.selectedGroupID else {
            print("Save failed: no group selected")
            return
        }

        guard let group = allGroups.first(where: { $0.persistentModelID == groupID }) else {
            print("Save failed: group not found with ID \(groupID)")
            return
        }

        model.isSaving = true
        defer { model.isSaving = false }

        let (title, body) = model.extractTitleAndBody()

        // 创建或更新 Entry
        let entry: Entry
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                existing.title = title.isEmpty ? LocalTitleService.dateFallback(date: existing.createdAt, groupName: group.name) : title
                existing.titleSource = .manual
                existing.bodyText = body
                existing.group = group
                existing.updatedAt = .now
                entry = existing
            } else {
                let new = Entry(
                    id: entryDraftID,
                    title: title.isEmpty ? LocalTitleService.dateFallback(date: model.createdAt, groupName: group.name) : title,
                    titleSource: .manual,
                    bodyText: body,
                    createdAt: model.createdAt,
                    updatedAt: .now,
                    group: group
                )
                context.insert(new)
                entry = new
            }
        } else {
            let new = Entry(
                id: entryDraftID,
                title: title.isEmpty ? LocalTitleService.dateFallback(date: model.createdAt, groupName: group.name) : title,
                titleSource: .manual,
                bodyText: body,
                createdAt: model.createdAt,
                updatedAt: .now,
                group: group
            )
            context.insert(new)
            entry = new
        }

        // 处理标签
        let allTags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        entry.tags = allTags.filter { model.selectedTags.contains($0.persistentModelID) }

        // 处理附件
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

        try? context.save()
        onSaved?(group.id, entry.id)
        model.isDirty = false
        dismiss()
    }

    @MainActor
    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        defer { photoPickerItems.removeAll() }

        let mediaStore = MediaStore.production()
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let filename = "photo-\(UUID().uuidString.prefix(8)).heic"
            guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else { continue }

            var draft = DraftAttachment(kind: .photo, relativePath: relPath)

            if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data) {
                if let img = UIImage(data: thumbData) {
                    thumbnails[draft.id] = img
                }
            }

            draft.persistedID = nil
            model.attachments.append(draft)
        }
    }

    private func removeAttachment(_ draft: DraftAttachment) {
        let mediaStore = MediaStore.production()
        try? mediaStore.delete(relativePath: draft.relativePath)
        thumbnails.removeValue(forKey: draft.id)
        model.attachments.removeAll { $0.id == draft.id }
    }
}

// MARK: - MediaAttachmentRow

struct MediaAttachmentRow: View {
    let draft: DraftAttachment
    let thumbnail: UIImage?
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.cardSurface)
                    .aspectRatio(16/9, contentMode: .fit)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(8)
            }
        }
    }
}

#Preview {
    iOSNoteEditorView(
        editingEntryID: nil,
        initialGroupID: nil,
        onSaved: nil
    )
    .environment(\.modelContext, ModelContext(try! ModelContainer(for: Entry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))))
}
