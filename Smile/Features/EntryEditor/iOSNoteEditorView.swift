import SwiftUI
import SwiftData
import UIKit

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
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var entryDraftID = UUID()
    @State private var showVoiceRecorder = false
    @State private var showTagPicker = false
    @State private var showUnsavedAlert = false
    @State private var showInsertPhotoError = false
    @State private var showSaveError = false
    @FocusState private var focusedSegmentID: UUID?

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if case .text(let id, _, _) = model.segments.first {
                        focusedSegmentID = id
                    }
                }
            }
        }
        .onDisappear { model.reset(); thumbnails.removeAll() }
        .onChange(of: model.autoSaveSignal) { _, signal in
            guard signal > 0 else { return }
            Task { await performLightAutosave() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceTranscribed)) { note in
            guard let draftID = note.userInfo?["draftID"] as? UUID,
                  let transcript = note.userInfo?["transcript"] as? String else { return }
            if let idx = model.voiceAttachments.firstIndex(where: { $0.id == draftID }) {
                model.voiceAttachments[idx].transcript = transcript
                model.isDirty = true
            }
        }
        .sheet(isPresented: $showVoiceRecorder) {
            VoiceRecorderView(entryDraftID: entryDraftID) { draft in model.voiceAttachments.append(draft) }
        }
        .sheet(isPresented: $showTagPicker) { TagPickerSheet(selected: $model.selectedTags) }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerView { images in
                showPhotoPicker = false
                Task { await insertPhotos(images) }
            } onCancel: {
                showPhotoPicker = false
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraFlow { img in
                showCamera = false
                Task { await insertPhoto(img) }
            } onCancel: {
                showCamera = false
            }
        }
        .alert("未保存的修改", isPresented: $showUnsavedAlert) {
            Button("放弃", role: .destructive) { dismiss() }
            Button("保存") { Task { await save() } }
            Button("继续编辑", role: .cancel) { }
        } message: { Text("有未保存的修改，确定放弃吗？") }
        .alert("照片插入失败", isPresented: $showInsertPhotoError) {
            Button("好", role: .cancel) { }
        } message: {
            Text("部分照片无法保存，请检查存储空间是否充足。")
        }
        .alert("保存失败", isPresented: $showSaveError) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("记录保存失败，请检查存储空间是否充足后重试。")
        }
    }

    @ViewBuilder
    private var editorScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.segments) { segment in
                    segmentView(segment)
                }
                voiceAttachmentsList
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: EditorSegment) -> some View {
        switch segment {
        case .text(let id, _, let alignment):
            TextEditor(text: textBinding(for: id))
                .scrollContentBackground(.hidden)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(minHeight: 80)
                .focused($focusedSegmentID, equals: id)
                .multilineTextAlignment(alignment)
                .onChange(of: model.textContent(for: id)) { _, _ in model.scheduleAutoSave() }
                .overlay(alignment: .topTrailing) {
                    if focusedSegmentID == id {
                        HStack(spacing: 2) {
                            alignButton(icon: "text.alignleft",   align: .leading, current: alignment, segmentID: id)
                            alignButton(icon: "text.aligncenter", align: .center,  current: alignment, segmentID: id)
                        }
                        .padding(4)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .padding(.trailing, 16)
                        .padding(.top, 4)
                    }
                }
        case .photo(let draft):
            MediaAttachmentRow(
                draft: draft,
                thumbnail: thumbnails[draft.id],
                onDelete: { removePhoto(draft) }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var voiceAttachmentsList: some View {
        if !model.voiceAttachments.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.voiceAttachments) { draft in
                    MediaAttachmentRow(
                        draft: draft,
                        thumbnail: nil,
                        onDelete: { removeVoice(draft) }
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var toolbarRow: some View {
        HStack(spacing: 18) {
            Button { showPhotoPicker = true } label: {
                Label("相册", systemImage: "photo.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.warmOrange)
            }
            Button { showCamera = true } label: {
                Label("拍摄", systemImage: "camera")
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

    // MARK: - Helpers

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.textContent(for: id) },
            set: { model.updateText($0, for: id) }
        )
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: model.createdAt)
    }

    private var canSave: Bool {
        model.selectedGroupID != nil && model.hasContent
    }

    // MARK: - Lifecycle

    private func initialize() {
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            if let entry = try? context.fetch(descriptor).first {
                model.load(from: entry)
                entryDraftID = entry.id
                Task { await loadExistingThumbnails() }
            } else {
                model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
            }
        } else {
            model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
        }
    }

    @MainActor
    private func loadExistingThumbnails() async {
        let mediaStore = MediaStore.production()
        for draft in model.photoDrafts {
            guard thumbnails[draft.id] == nil,
                  let data = try? mediaStore.loadData(relativePath: draft.relativePath) else { continue }
            if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data),
               let img = UIImage(data: thumbData) {
                thumbnails[draft.id] = img
            } else if let img = UIImage(data: data) {
                thumbnails[draft.id] = img
            }
        }
    }

    private func handleBack() {
        if model.isDirty { showUnsavedAlert = true } else { dismiss() }
    }

    private func handleComplete() { Task { await save() } }

    @MainActor
    private func save() async {
        guard let groupID = model.selectedGroupID,
              let group = allGroups.first(where: { $0.persistentModelID == groupID }) else { return }

        model.isSaving = true
        defer { model.isSaving = false }

        let title = model.extractTitle()
        let body = iOSNoteEditorModel.encodeBodySegments(model.buildBodySegments())

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

        let allTags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        entry.tags = allTags.filter { model.selectedTags.contains($0.persistentModelID) }

        let allDrafts = model.allAttachments
        let modelDraftIDs = Set(allDrafts.compactMap { $0.persistedID })
        for existing in entry.attachments where !modelDraftIDs.contains(existing.persistentModelID) {
            context.delete(existing)
        }
        for (idx, draft) in allDrafts.enumerated() where draft.persistedID == nil {
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

        do {
            try context.save()
        } catch {
            showSaveError = true
            return
        }
        onSaved?(group.id, entry.id)
        model.isDirty = false
        dismiss()
    }

    @MainActor
    private func insertPhoto(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let mediaStore = MediaStore.production()
        let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
        guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else {
            showInsertPhotoError = true
            return
        }
        var draft = DraftAttachment(kind: .photo, relativePath: relPath)
        draft.persistedID = nil
        if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data),
           let img = UIImage(data: thumbData) {
            thumbnails[draft.id] = img
        }
        let anchorID = focusedSegmentID
        model.insertPhoto(draft, afterSegmentID: anchorID)
        model.isDirty = true
    }

    @MainActor
    private func insertPhotos(_ images: [UIImage]) async {
        let anchor = focusedSegmentID
        var drafts: [DraftAttachment] = []
        let mediaStore = MediaStore.production()
        var hadFailure = false
        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.9) else { hadFailure = true; continue }
            let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
            guard let relPath = try? mediaStore.save(data: data, entryID: entryDraftID, filename: filename) else { hadFailure = true; continue }
            var draft = DraftAttachment(kind: .photo, relativePath: relPath)
            draft.persistedID = nil
            if let thumbData = ThumbnailGenerator.makePhotoThumbnail(from: data),
               let img = UIImage(data: thumbData) {
                thumbnails[draft.id] = img
            }
            drafts.append(draft)
        }
        if hadFailure { showInsertPhotoError = true }
        guard !drafts.isEmpty else { return }
        model.insertPhotos(drafts, afterSegmentID: anchor)
        model.isDirty = true
    }

    private func removePhoto(_ draft: DraftAttachment) {
        let mediaStore = MediaStore.production()
        try? mediaStore.delete(relativePath: draft.relativePath)
        thumbnails.removeValue(forKey: draft.id)
        model.removePhoto(id: draft.id)
    }

    private func removeVoice(_ draft: DraftAttachment) {
        let mediaStore = MediaStore.production()
        try? mediaStore.delete(relativePath: draft.relativePath)
        model.voiceAttachments.removeAll { $0.id == draft.id }
    }

    /// Autosave path: persists text+body to an existing entry without dismissing.
    /// For new entries (editingEntryID == nil), checks if one was already created by a prior autosave.
    @MainActor
    private func performLightAutosave() async {
        guard let groupID = model.selectedGroupID,
              let group = allGroups.first(where: { $0.persistentModelID == groupID }),
              model.hasContent else { return }

        let title = model.extractTitle()
        let body = iOSNoteEditorModel.encodeBodySegments(model.buildBodySegments())
        let fallbackTitle = LocalTitleService.dateFallback(date: model.createdAt, groupName: group.name)

        let entry: Entry
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            guard let existing = try? context.fetch(descriptor).first else { return }
            existing.title = title.isEmpty ? fallbackTitle : title
            existing.bodyText = body
            existing.updatedAt = .now
            entry = existing
        } else {
            // For new entries, look up by entryDraftID (stable across the editing session).
            let draftID = entryDraftID
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == draftID })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                existing.title = title.isEmpty ? fallbackTitle : title
                existing.bodyText = body
                existing.updatedAt = .now
                entry = existing
            } else {
                let new = Entry(
                    id: entryDraftID,
                    title: title.isEmpty ? fallbackTitle : title,
                    titleSource: .manual,
                    bodyText: body,
                    createdAt: model.createdAt,
                    updatedAt: .now,
                    group: group
                )
                context.insert(new)
                entry = new
            }
        }

        let allTags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        entry.tags = allTags.filter { model.selectedTags.contains($0.persistentModelID) }
        try? context.save()
    }

    @ViewBuilder
    private func alignButton(icon: String, align: TextAlignment, current: TextAlignment, segmentID: UUID) -> some View {
        Button {
            model.updateAlignment(align, for: segmentID)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(current == align ? Color.white : AppColors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(current == align ? AppColors.warmOrange : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
