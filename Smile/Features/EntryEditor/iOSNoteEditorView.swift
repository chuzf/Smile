import SwiftUI
import SwiftData
import UIKit

struct iOSNoteEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ShareInboxCenter.self) private var shareCenter

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == true },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var builtinGroups: [Group]

    @Query(filter: #Predicate<Group> { $0.isBuiltIn == false },
           sort: [SortDescriptor(\Group.sortOrder)])
    private var customGroups: [Group]

    let editingEntryID: PersistentIdentifier?
    let initialGroupID: PersistentIdentifier?
    /// 从相册分享进来的照片，打开后自动插入
    let initialImages: [UIImage]
    /// 分享照片中解码失败的数量，> 0 时提示
    let initialImageFailures: Int
    /// 初始照片插入完成后回调，供调用方释放手里持有的大图
    let onInitialImagesConsumed: (() -> Void)?
    let onSaved: ((UUID, UUID) -> Void)?

    init(editingEntryID: PersistentIdentifier? = nil,
         initialGroupID: PersistentIdentifier? = nil,
         initialImages: [UIImage] = [],
         initialImageFailures: Int = 0,
         onInitialImagesConsumed: (() -> Void)? = nil,
         onSaved: ((UUID, UUID) -> Void)? = nil) {
        self.editingEntryID = editingEntryID
        self.initialGroupID = initialGroupID
        self.initialImages = initialImages
        self.initialImageFailures = initialImageFailures
        self.onInitialImagesConsumed = onInitialImagesConsumed
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
    @State private var dictationService = DictationService()
    @State private var dictationError: DictationService.DictationError?
    @State private var recordingPulse = false
    @State private var showShareChoice = false
    /// 弹窗标题用的张数；点按钮后 incomingImages 会立刻变 nil，避免标题闪成「收到 0 张照片」
    @State private var shareChoiceCount = 0
    /// 防止重复 onAppear 让 shareCenter 的打开编辑器计数多加
    @State private var isRegisteredWithShareCenter = false
    /// initialImages 只插入一次（onAppear 可能重复触发）
    @State private var didConsumeInitialImages = false
    /// 已开始关闭（dismiss 已调用）；此后不再接收分享照片、不再自动保存、不再写入照片
    @State private var isClosing = false
    /// 正在进行中的 insertPhotos 调用数；编码期间 model 还没更新，编辑器看起来仍是空白
    @State private var pendingPhotoInserts = 0
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
                if dictationService.isActive {
                    dictationStatusBar
                }
                Divider()
                toolbarRow
            }
        }
        .onAppear {
            if !isRegisteredWithShareCenter {
                isRegisteredWithShareCenter = true
                shareCenter.editorDidAppear()
            }
            initialize()
            if !didConsumeInitialImages, !initialImages.isEmpty {
                didConsumeInitialImages = true
                let images = initialImages
                let failures = initialImageFailures
                Task {
                    await insertPhotos(images)
                    if failures > 0 && !isClosing { showInsertPhotoError = true }
                    onInitialImagesConsumed?()
                }
            }
            presentShareChoiceIfNeeded()
            if editingEntryID == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if case .text(let id, _, _) = model.segments.first {
                        focusedSegmentID = id
                    }
                }
            }
        }
        .onDisappear {
            if dictationService.isActive {
                dictationService.stop()
                // finalizeDictation keeps any partial text already written — intentional,
                // so the user doesn't lose words they already spoke before dismissing.
                model.finalizeDictation()
            }
            model.reset()
            thumbnails.removeAll()
            if isRegisteredWithShareCenter {
                isRegisteredWithShareCenter = false
                shareCenter.editorDidDisappear()
            }
        }
        .onChange(of: shareCenter.incomingImages != nil) { _, hasIncoming in
            if hasIncoming { presentShareChoiceIfNeeded() }
        }
        .onChange(of: isPresentingOther) { _, busy in
            // 其它弹窗/弹层关闭后再补弹收图询问；稍等让上一个呈现的退场动画结束
            guard !busy else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                presentShareChoiceIfNeeded()
            }
        }
        .onChange(of: allGroups.count) { _, _ in
            // 冷启动时内置分组可能晚于编辑器出现才 seed 完成
            if model.selectedGroupID == nil {
                model.selectDefaultGroup(from: allGroups, initialGroupID: initialGroupID)
            }
        }
        .alert("收到 \(shareChoiceCount) 张照片", isPresented: $showShareChoice) {
            Button("插入当前记录") { insertSharedPhotos() }
            Button("新建记录") { Task { await startNewEntryFromShare() } }
            Button("取消", role: .cancel) { shareCenter.discardIncoming() }
        } message: {
            Text("加入正在编辑的这条记录，还是新建一条记录？")
        }
        .onChange(of: model.autoSaveSignal) { _, signal in
            guard signal > 0 else { return }
            Task { await performLightAutosave() }
        }
        .onChange(of: dictationService.error) { _, newError in
            guard let newError else { return }
            model.finalizeDictation()
            dictationError = newError
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
            Button("放弃", role: .destructive) { discardAndClose() }
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
        .alert("语音识别不可用", isPresented: Binding(
            get: { dictationError != nil },
            set: { if !$0 { dictationError = nil } }
        )) {
            if case .microphoneDenied? = dictationError,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Button("去设置") { UIApplication.shared.open(url); dictationError = nil }
            } else if case .speechRecognitionDenied? = dictationError,
                      let url = URL(string: UIApplication.openSettingsURLString) {
                Button("去设置") { UIApplication.shared.open(url); dictationError = nil }
            }
            Button("好的", role: .cancel) { dictationError = nil }
        } message: {
            Text(dictationError?.localizedDescription ?? "")
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
            ZStack(alignment: .topLeading) {
                // Invisible mirror Text drives the container height so the TextEditor
                // expands to show all content instead of clipping inside the ScrollView.
                // TextEditor's UITextView has ~5pt horizontal and ~8pt vertical internal inset.
                Text(model.textContent(for: id).isEmpty ? " " : model.textContent(for: id))
                    .font(.system(size: 16, weight: .regular))
                    .padding(.horizontal, 21)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                TextEditor(text: textBinding(for: id))
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .scrollDisabled(true)
                    .focused($focusedSegmentID, equals: id)
                    .multilineTextAlignment(alignment)
                    .onChange(of: model.textContent(for: id)) { _, _ in model.scheduleAutoSave() }
            }
            .frame(minHeight: 80)
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
    private var dictationStatusBar: some View {
        HStack(spacing: 8) {
            // 闪烁红点 —— 明确的“正在录音”信号（Guideline 2.5.14）
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(recordingPulse ? 1.0 : 0.3)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: recordingPulse)
            Text("● 正在录音 · 听写中")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
            Spacer()
            Text("点击麦克风停止")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.10))
        .onAppear { recordingPulse = true }
    }

    @ViewBuilder
    private var toolbarRow: some View {
        HStack(spacing: 18) {
            Button { showPhotoPicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                    Text("相册")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive)
            Button { showCamera = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera")
                    Text("拍摄")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive)
            Button { handleDictationTap() } label: {
                if dictationService.isActive {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                        Circle()
                            .stroke(Color.red.opacity(0.3), lineWidth: 4)
                            .frame(width: 36, height: 36)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "mic")
                        Text("听写")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.warmOrange)
                }
            }
            Button { showVoiceRecorder = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "mic.badge.plus")
                    Text("语音")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive)
            Button { showTagPicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                    Text("标签")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive)
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

    private func handleDictationTap() {
        if dictationService.isActive {
            dictationService.stop()
            model.finalizeDictation()
        } else {
            let targetID: UUID?
            if let focused = focusedSegmentID {
                targetID = focused
            } else {
                targetID = model.segments.compactMap {
                    if case .text(let id, _, _) = $0 { return id } else { return nil }
                }.last
            }
            guard let targetID else { return }
            model.dictationTargetSegmentID = targetID
            model.dictationBaseText = model.textContent(for: targetID)

            Task {
                do {
                    try await dictationService.start(
                        onPartial: { partial in model.updateDictation(partial) },
                        onFinal: { final in model.commitDictation(final) }
                    )
                } catch let e as DictationService.DictationError {
                    model.cancelDictation()
                    dictationError = e
                } catch {
                    model.cancelDictation()
                }
            }
        }
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
        if model.isDirty {
            showUnsavedAlert = true
        } else {
            discardAndClose()
        }
    }

    /// 本视图所有关闭都走这里：先标记 isClosing，挡住之后到达的分享照片 / 自动保存 / 照片写入
    private func close() {
        isClosing = true
        dismiss()
    }

    /// 放弃编辑并关闭：取消待触发的自动保存，清理未落库新记录的草稿照片
    private func discardAndClose() {
        isClosing = true
        model.cancelAutoSave()
        discardUnsavedDraftMedia()
        dismiss()
    }

    private func handleComplete() { Task { await save() } }

    /// 返回 true 表示已保存并关闭编辑器；缺少分组或写库失败时返回 false（并弹出保存失败提示）
    @MainActor
    @discardableResult
    private func save() async -> Bool {
        guard let groupID = model.selectedGroupID,
              let group = allGroups.first(where: { $0.persistentModelID == groupID }) else {
            showSaveError = true
            return false
        }

        model.isSaving = true
        defer { model.isSaving = false }

        let title = model.extractTitle()
        let body = iOSNoteEditorModel.encodeBodySegments(model.buildBodySegments())

        let entry: Entry
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                existing.title = title.isEmpty ? Self.dateFallback(date: existing.createdAt, groupName: group.name) : title
                existing.titleSource = .manual
                existing.bodyText = body
                existing.group = group
                existing.updatedAt = .now
                entry = existing
            } else {
                let new = Entry(
                    id: entryDraftID,
                    title: title.isEmpty ? Self.dateFallback(date: model.createdAt, groupName: group.name) : title,
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
                title: title.isEmpty ? Self.dateFallback(date: model.createdAt, groupName: group.name) : title,
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
            return false
        }
        onSaved?(group.id, entry.id)
        model.isDirty = false
        close()
        return true
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
        pendingPhotoInserts += 1
        defer { pendingPhotoInserts -= 1 }
        for image in images {
            guard !isClosing else { break }
            // JPEG 编码与缩略图生成较重，放到后台线程；落盘和状态修改留在主线程
            let encoded = await Task.detached(priority: .userInitiated) {
                autoreleasepool { () -> (data: Data, thumbnail: UIImage?)? in
                    guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                    let thumb = ThumbnailGenerator.makePhotoThumbnail(from: data).flatMap { UIImage(data: $0) }
                    return (data, thumb)
                }
            }.value
            guard !isClosing else { break }
            guard let encoded else { hadFailure = true; continue }
            let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
            guard let relPath = try? mediaStore.save(data: encoded.data, entryID: entryDraftID, filename: filename) else { hadFailure = true; continue }
            var draft = DraftAttachment(kind: .photo, relativePath: relPath)
            draft.persistedID = nil
            if let thumb = encoded.thumbnail {
                thumbnails[draft.id] = thumb
            }
            drafts.append(draft)
        }
        if isClosing {
            // 编辑器已在关闭：本次写入但未进 model 的文件会成为孤儿，删掉
            for draft in drafts { try? mediaStore.delete(relativePath: draft.relativePath) }
            return
        }
        if hadFailure { showInsertPhotoError = true }
        guard !drafts.isEmpty else { return }
        model.insertPhotos(drafts, afterSegmentID: anchor)
        model.isDirty = true
    }

    /// 是否有其它 sheet / 全屏 / alert 正在呈现；此时弹收图询问会被系统吞掉
    private var isPresentingOther: Bool {
        showPhotoPicker || showCamera || showVoiceRecorder || showTagPicker ||
        showUnsavedAlert || showInsertPhotoError || showSaveError || dictationError != nil
    }

    private func presentShareChoiceIfNeeded() {
        // 已关闭/正在关闭的编辑器（onDisappear 后 model 被 reset，看起来是空白的）不能接收照片
        guard isRegisteredWithShareCenter, !isClosing,
              let incoming = shareCenter.incomingImages,
              !isPresentingOther, !showShareChoice else { return }
        // 全新、空白、未改动、且不是从分享打开、也没有照片正在编码的编辑器：不用问，直接插入
        if editingEntryID == nil && initialImages.isEmpty && pendingPhotoInserts == 0
            && !model.hasContent && !model.isDirty {
            insertSharedPhotos()
            return
        }
        shareChoiceCount = incoming.count
        showShareChoice = true
    }

    private func insertSharedPhotos() {
        let incoming = shareCenter.takeIncoming()
        Task {
            await insertPhotos(incoming.images)
            if incoming.failures > 0 { showInsertPhotoError = true }
        }
    }

    /// incomingImages 保留在 shareCenter 中，本编辑器关闭后由 RootView 用它新建记录
    @MainActor
    private func startNewEntryFromShare() async {
        // 等收图询问框退场完，避免保存失败提示在它消失过程中被设置而被吞掉
        try? await Task.sleep(for: .milliseconds(350))
        if canSave {
            // 保存失败时不做别的：保存失败提示关闭后 isPresentingOther 变回 false，
            // 照片仍在 shareCenter 中，会自动重新弹出收图询问
            await save()
        } else {
            discardAndClose()
        }
    }

    /// 放弃一条从未落库的新记录时，删除它已经写到 MediaStore 的草稿照片。
    /// 编辑已有记录、或自动保存已建出 Entry 时不动文件。
    private func discardUnsavedDraftMedia() {
        guard editingEntryID == nil else { return }
        let draftID = entryDraftID
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == draftID })
        descriptor.fetchLimit = 1
        // 查询失败时保守处理，不删文件
        guard let count = try? context.fetchCount(descriptor), count == 0 else { return }
        try? MediaStore.production().deleteEntryDirectory(entryID: draftID)
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
        guard !isClosing,
              let groupID = model.selectedGroupID,
              let group = allGroups.first(where: { $0.persistentModelID == groupID }),
              model.hasContent else { return }

        let title = model.extractTitle()
        let body = iOSNoteEditorModel.encodeBodySegments(model.buildBodySegments())
        let fallbackTitle = Self.dateFallback(date: model.createdAt, groupName: group.name)

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

    private static func dateFallback(date: Date, groupName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: date)) · \(groupName)"
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
    .environment(ShareInboxCenter(inbox: nil))
}
