import SwiftUI
import SwiftData
import UIKit
import ImageIO

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
    let onSaved: ((UUID, UUID) -> Void)?

    init(editingEntryID: PersistentIdentifier? = nil,
         initialGroupID: PersistentIdentifier? = nil,
         onSaved: ((UUID, UUID) -> Void)? = nil) {
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
    @State private var showShareReadError = false
    @State private var showSaveError = false
    @State private var dictationService = DictationService()
    @State private var dictationError: DictationService.DictationError?
    @State private var recordingPulse = false
    @State private var showShareChoice = false
    /// 「新建记录」等待保存期间，挡住收图询问的重复弹出
    @State private var isStartingNewEntryFromShare = false
    /// 弹窗标题用的张数；点按钮后 incomingPhotoURLs 会立刻变 nil，避免标题闪成「收到 0 张照片」
    @State private var shareChoiceCount = 0
    /// 防止重复 onAppear 让 shareCenter 的打开编辑器计数多加
    @State private var isRegisteredWithShareCenter = false
    /// 已开始关闭（dismiss 已调用）；此后不再接收分享照片、不再自动保存、不再写入照片
    @State private var isClosing = false
    /// 已排队或正在进行的 insertPhotos 调用数；编码期间 model 还没更新，编辑器看起来仍是空白
    @State private var pendingPhotoInserts = 0
    /// 最近一次排队的插入；新的插入等它结束才开始，保证同一时刻只解码一张全分辨率图片
    @State private var insertChain: Task<Void, Never>?
    @State private var isFormatting = false
    @State private var formattingTask: Task<Void, Never>?
    @State private var formattingPreview: FormattingPreview?
    @State private var formattingErrorMessage: String?
    /// 预览 sheet 关闭后才显示的错误
    @State private var pendingFormattingError: String?
    @State private var showAISetupAlert = false
    @State private var showAISettings = false
    @State private var focusedSegmentID: UUID?
    /// 自动保存是否已写过库；放弃时据此撤销
    @State private var hasAutosaved = false
    /// 编辑已有记录时，打开那一刻的内容；放弃时用它撤销自动保存写进去的改动
    @State private var originalEntryState: OriginalEntryState?

    private struct OriginalEntryState {
        let title: String
        let bodyText: String
        let updatedAt: Date
        let tagIDs: Set<PersistentIdentifier>
    }

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
            if isFormatting {
                formattingOverlay
            }
        }
        .onAppear {
            if !isRegisteredWithShareCenter {
                isRegisteredWithShareCenter = true
                shareCenter.editorDidAppear()
            }
            initialize()
            presentSharePromptsIfNeeded()
            if editingEntryID == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if case .text(let id, _, _) = model.segments.first {
                        focusedSegmentID = id
                    }
                }
            }
        }
        .onDisappear {
            formattingTask?.cancel()
            if dictationService.isActive {
                dictationService.stop()
                // finalizeDictation keeps any partial text already written — intentional,
                // so the user doesn't lose words they already spoke before dismissing.
                model.finalizeDictation()
            }
            if !isClosing {
                // 下滑关闭（仅在没有未保存修改时允许）不经过 close()/discardAndClose()：停止正在写入的照片，并清理没有记录引用的草稿照片
                isClosing = true
                discardUnsavedDraftMedia()
            }
            model.reset()
            thumbnails.removeAll()
            if isRegisteredWithShareCenter {
                isRegisteredWithShareCenter = false
                shareCenter.editorDidDisappear()
            }
        }
        .shareHandling(self)
        .formattingHandling(self)
        // 有未保存的修改时不能直接下滑关闭，和返回按钮一样询问保存还是放弃
        .interactiveDismissDisabled(model.isDirty)
        .onSheetDismissAttempt { handleBack() }
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
                Task { await insertPhotos(images.map(PhotoSource.image)) }
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
        case .text(let id, let content, let alignment):
            let hasTitle = id == firstTextSegmentID
            NoteTextView(
                segmentID: id,
                text: content,
                hasTitle: hasTitle,
                alignment: alignment,
                minHeight: 72,
                focusedSegmentID: $focusedSegmentID,
                onChange: { model.updateText($0, for: id) }
            )
            .padding(.horizontal, 21)
            .padding(.vertical, 4)
            .overlay(alignment: alignment == .center ? .top : .topLeading) {
                if hasTitle && content.isEmpty {
                    Text("标题")
                        .font(Font(NoteTextView.titleFont))
                        .foregroundStyle(AppColors.textSecondary.opacity(0.5))
                        .padding(.horizontal, 21)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: content) { _, _ in model.scheduleAutoSave() }
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
        HStack(spacing: 14) {
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
            Button { startFormatting() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text("整理")
                }
                .font(.system(size: 13))
                .foregroundStyle(AppColors.warmOrange)
            }
            .disabled(dictationService.isActive || isFormatting || pendingPhotoInserts > 0 || !model.canFormat)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - AI 整理

    private var formattingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.warmOrange)
                Text("整理中…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Button("取消") { cancelFormatting() }
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.warmOrange)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func startFormatting() {
        guard !isFormatting else { return }
        let store = AIConfigStore()
        let config = store.load()
        guard let apiKey = store.loadAPIKey(), config.isComplete(apiKey: apiKey) else {
            showAISetupAlert = true
            return
        }
        let client: LLMClient
        do {
            client = try LLMClientFactory.make(config: config, apiKey: apiKey)
        } catch {
            formattingErrorMessage = (error as? LLMError ?? .notConfigured).userMessage
            return
        }
        let service = TextFormattingService(client: client, style: config.style, customPrompt: config.customPrompt)
        focusedSegmentID = nil
        isFormatting = true
        formattingTask = Task { @MainActor in
            // 先收起键盘，等输入法未确认的文字提交进 model 后再取快照
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let snapshot = model.formattingSnapshot() else {
                isFormatting = false
                formattingTask = nil
                return
            }
            do {
                let result = try await service.format(snapshot.input)
                guard !Task.isCancelled else { return }
                formattingPreview = FormattingPreview(snapshot: snapshot, result: snapshot.adjustingIndent(result))
            } catch let error as FormattingError {
                if !Task.isCancelled { formattingErrorMessage = error.userMessage }
            } catch {
                // CancellationError：用户已取消，不提示
                if !Task.isCancelled && !(error is CancellationError) {
                    formattingErrorMessage = LLMError.network(error.localizedDescription).userMessage
                }
            }
            // 取消时 cancelFormatting() 已复位，这里不能覆盖新一轮的状态
            if !Task.isCancelled {
                isFormatting = false
                formattingTask = nil
            }
        }
    }

    private func cancelFormatting() {
        formattingTask?.cancel()
        formattingTask = nil
        isFormatting = false
    }

    fileprivate func applyFormattingPreview(_ preview: FormattingPreview) {
        if !model.applyFormatting(preview.result, to: preview.snapshot) {
            // sheet 完全退场后（onDismiss）再弹，避免和其它弹窗抢着呈现
            pendingFormattingError = "内容已变化，未能替换，请重新整理。"
        }
        formattingPreview = nil
    }

    // MARK: - Helpers

    /// 承载标题的文字段：第一行是标题（与 extractTitle() 一致）
    private var firstTextSegmentID: UUID? {
        for seg in model.segments {
            if case .text(let id, _, _) = seg { return id }
        }
        return nil
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
        // 照片还在后台编码时不能保存，否则保存出的记录会缺这些照片
        model.selectedGroupID != nil && model.hasContent && pendingPhotoInserts == 0
    }

    // MARK: - Lifecycle

    private func initialize() {
        if let editID = editingEntryID {
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            if let entry = try? context.fetch(descriptor).first {
                model.load(from: entry)
                entryDraftID = entry.id
                originalEntryState = OriginalEntryState(title: entry.title, bodyText: entry.bodyText,
                                                        updatedAt: entry.updatedAt,
                                                        tagIDs: Set(entry.tags.map(\.persistentModelID)))
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

    /// 放弃编辑并关闭：取消待触发的自动保存、撤销已自动保存的内容，清理未落库新记录的草稿照片
    private func discardAndClose() {
        isClosing = true
        model.cancelAutoSave()
        revertAutosave()
        discardUnsavedDraftMedia()
        dismiss()
    }

    /// 新记录：删掉自动保存建出的记录；已有记录：恢复成打开编辑器时的内容
    private func revertAutosave() {
        guard hasAutosaved else { return }
        if let editID = editingEntryID {
            guard let original = originalEntryState else { return }
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.persistentModelID == editID })
            descriptor.fetchLimit = 1
            guard let entry = try? context.fetch(descriptor).first else { return }
            entry.title = original.title
            entry.bodyText = original.bodyText
            entry.updatedAt = original.updatedAt
            let allTags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
            entry.tags = allTags.filter { original.tagIDs.contains($0.persistentModelID) }
        } else {
            let draftID = entryDraftID
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == draftID })
            descriptor.fetchLimit = 1
            guard let entry = try? context.fetch(descriptor).first else { return }
            context.delete(entry)
        }
        try? context.save()
        hasAutosaved = false
    }

    private func handleComplete() { Task { await save() } }

    /// 返回 true 表示已保存并关闭编辑器；缺少分组或写库失败时返回 false（并弹出保存失败提示）
    @MainActor
    @discardableResult
    private func save() async -> Bool {
        // 未保存弹窗里的「保存」不经过 canSave，等正在编码的照片插入完再保存
        while pendingPhotoInserts > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
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
        var removedPaths: [String] = []
        for existing in entry.attachments where !modelDraftIDs.contains(existing.persistentModelID) {
            removedPaths.append(existing.relativePath)
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
        // 记录已不再引用，删掉编辑时移除的附件文件
        let mediaStore = MediaStore.production()
        for path in removedPaths { try? mediaStore.delete(relativePath: path) }
        onSaved?(group.id, entry.id)
        model.isDirty = false
        hasAutosaved = false
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

    /// 要插入的照片来源：相册选择器给的是已解码的 UIImage；分享进来的是磁盘上的原图文件
    private enum PhotoSource: Sendable {
        case image(UIImage)
        /// 由本编辑器拥有，处理完（或编辑器关闭）后删除
        case file(URL)
    }

    /// 排队插入照片：所有插入串行执行（相册、分享多批之间也是），同一时刻只有一张图片在解码/编码。
    /// 入队时就计入 `pendingPhotoInserts`，`canSave` / `startNewEntryFromShare` 会等排队中的插入完成。
    /// `extraReadFailures`：分享中心校验阶段已发现的无法读取的文件数，与本次读取失败一起提示。
    @MainActor
    private func insertPhotos(_ sources: [PhotoSource], extraReadFailures: Int = 0) async {
        pendingPhotoInserts += 1
        // 入队时（视图一定还在）取好 center 与插入位置：排队等待期间视图可能已消失、光标也可能移动
        let center = shareCenter
        let anchor = focusedSegmentID
        let previous = insertChain
        let task = Task { @MainActor in
            await previous?.value
            await performInsertPhotos(sources, extraReadFailures: extraReadFailures,
                                      center: center, anchor: anchor)
        }
        insertChain = task
        await task.value
    }

    /// 逐张在后台编码为 JPEG 0.9 并落盘，全部完成后按顺序一次性插入。
    /// `.file` 每次只解码一张全分辨率原图，避免多张大图同时驻留内存。
    /// 读取/编码 `.file` 失败计为读取失败（「照片读取失败」）；落盘失败为「照片插入失败」，两者只提示一个。
    @MainActor
    private func performInsertPhotos(_ sources: [PhotoSource], extraReadFailures: Int,
                                     center: ShareInboxCenter, anchor: UUID?) async {
        let fileURLs = sources.compactMap { source -> URL? in
            if case .file(let url) = source { return url } else { return nil }
        }
        var drafts: [DraftAttachment] = []
        let mediaStore = MediaStore.production()
        var hadSaveFailure = false
        var readFailures = extraReadFailures
        defer {
            pendingPhotoInserts -= 1
            // 分享的源文件无论成功、失败还是中途关闭都要删掉，并结束交接（只此一处）
            if !fileURLs.isEmpty { center.finishHandOff(of: fileURLs) }
        }
        for source in sources {
            guard !isClosing else { break }
            // 解码、JPEG 编码与缩略图生成较重，放到后台线程；落盘和状态修改留在主线程
            let encoded = await Task.detached(priority: .userInitiated) {
                autoreleasepool { () -> (data: Data, thumbnail: UIImage?)? in
                    switch source {
                    case .image(let image):
                        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                        let thumb = ThumbnailGenerator.makePhotoThumbnail(from: data).flatMap { UIImage(data: $0) }
                        return (data, thumb)
                    case .file(let url):
                        defer { ShareInboxCenter.deleteHandedOffFile(url) }
                        // 与相册选择器一致：全分辨率 UIImage → JPEG 0.9，方向随 EXIF 保留。
                        // 内层 autoreleasepool 让解码出的位图尽早释放
                        let data = autoreleasepool {
                            UIImage(contentsOfFile: url.path)?.jpegData(compressionQuality: 0.9)
                        }
                        guard let data else { return nil }
                        // 缩略图直接从原文件用 ImageIO 生成，不再把刚编码的 JPEG 整张解码一遍
                        return (data, Self.fileThumbnail(at: url))
                    }
                }
            }.value
            guard !isClosing else { break }
            guard let encoded else {
                if case .file = source { readFailures += 1 } else { hadSaveFailure = true }
                continue
            }
            let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
            guard let relPath = try? mediaStore.save(data: encoded.data, entryID: entryDraftID, filename: filename) else { hadSaveFailure = true; continue }
            var draft = DraftAttachment(kind: .photo, relativePath: relPath)
            draft.persistedID = nil
            if let thumb = encoded.thumbnail {
                thumbnails[draft.id] = thumb
            }
            drafts.append(draft)
        }
        if isClosing {
            // 编辑器已在关闭：本次写入但未进 model 的文件会成为孤儿，删掉（未处理的源文件由 defer 删除）
            for draft in drafts { try? mediaStore.delete(relativePath: draft.relativePath) }
            return
        }
        // 同一轮里设置两个 alert 只会显示一个：存储问题优先
        if hadSaveFailure {
            showInsertPhotoError = true
        } else if readFailures > 0 {
            showShareReadError = true
        }
        guard !drafts.isEmpty else { return }
        model.insertPhotos(drafts, afterSegmentID: anchor)
        model.isDirty = true
    }

    /// 与 ThumbnailGenerator 的结果一致：长边 400pt × 3x，按 EXIF 方向摆正；只解码缩小后的图
    nonisolated private static func fileThumbnail(at url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 是否有其它 sheet / 全屏 / alert 正在呈现；此时弹收图询问会被系统吞掉
    private var isPresentingOther: Bool {
        showPhotoPicker || showCamera || showVoiceRecorder || showTagPicker ||
        showUnsavedAlert || showInsertPhotoError || showShareReadError || showSaveError || dictationError != nil ||
        isFormatting || formattingPreview != nil || formattingErrorMessage != nil || pendingFormattingError != nil || showAISetupAlert || showAISettings
    }

    private func presentSharePromptsIfNeeded() {
        // 已关闭/正在关闭的编辑器（onDisappear 后 model 被 reset，看起来是空白的）不能接收照片
        guard isRegisteredWithShareCenter, !isClosing,
              !isPresentingOther, !showShareChoice, !isStartingNewEntryFromShare else { return }
        if shareCenter.hasUnreportedReadFailure {
            shareCenter.clearReadFailure()
            showShareReadError = true
            return
        }
        guard let incoming = shareCenter.incomingPhotoURLs else { return }
        // 全新、空白、未改动、也没有照片正在编码的编辑器（包括 RootView 为分享新开的编辑器）：不用问，直接插入。
        // 第一批还在编码时（pendingPhotoInserts > 0）又来一批，走询问而不是合并
        if editingEntryID == nil && pendingPhotoInserts == 0
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
            await insertPhotos(incoming.urls.map(PhotoSource.file), extraReadFailures: incoming.failures)
        }
    }

    /// incomingPhotoURLs 保留在 shareCenter 中，本编辑器关闭后由 RootView 用它新建记录
    @MainActor
    private func startNewEntryFromShare() async {
        isStartingNewEntryFromShare = true
        defer { isStartingNewEntryFromShare = false }
        // 等收图询问框退场完，避免保存失败提示在它消失过程中被设置而被吞掉
        try? await Task.sleep(for: .milliseconds(350))
        // 正在编码的照片插入完再判断，否则 canSave 为 false 会被误当作「没有内容」
        while pendingPhotoInserts > 0 && !isClosing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !isClosing else { return }
        if !model.hasContent {
            // 没有任何内容（没有可丢的东西）：直接关闭
            discardAndClose()
        } else {
            // 保存失败（含未选分组）时不做别的：保存失败提示关闭后 isPresentingOther 变回 false，
            // 照片仍在 shareCenter 中，会自动重新弹出收图询问
            await save()
        }
    }

    /// 放弃一条从未落库的新记录时，删除它已经写到 MediaStore 的草稿照片。
    /// 编辑已有记录时只删本次新加、还没落库的附件文件。
    private func discardUnsavedDraftMedia() {
        guard editingEntryID == nil else {
            let mediaStore = MediaStore.production()
            for draft in model.allAttachments where draft.persistedID == nil {
                try? mediaStore.delete(relativePath: draft.relativePath)
            }
            return
        }
        let draftID = entryDraftID
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == draftID })
        descriptor.fetchLimit = 1
        // 查询失败时保守处理，不删文件
        guard let count = try? context.fetchCount(descriptor), count == 0 else { return }
        try? MediaStore.production().deleteEntryDirectory(entryID: draftID)
    }

    private func removePhoto(_ draft: DraftAttachment) {
        deleteFileIfUnsaved(draft)
        thumbnails.removeValue(forKey: draft.id)
        model.removePhoto(id: draft.id)
        model.isDirty = true
    }

    private func removeVoice(_ draft: DraftAttachment) {
        deleteFileIfUnsaved(draft)
        model.voiceAttachments.removeAll { $0.id == draft.id }
        model.isDirty = true
    }

    /// 本次新加、还没落库的附件，移除时直接删文件；已落库的附件还被记录引用，
    /// 留到保存成功后再删（见 save()），放弃编辑时记录里的照片仍完好
    private func deleteFileIfUnsaved(_ draft: DraftAttachment) {
        guard draft.persistedID == nil else { return }
        try? MediaStore.production().delete(relativePath: draft.relativePath)
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
        // 写库失败时改动仍留在 context 里，同样需要放弃时撤销
        hasAutosaved = true
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

// MARK: - 分享照片相关的监听与弹窗（拆出 body，避免修饰符链过长导致类型检查超时）

private extension View {
    func shareHandling(_ editor: iOSNoteEditorView) -> some View {
        editor.applyShareHandling(to: self)
    }
}

extension iOSNoteEditorView {
    fileprivate func applyShareHandling<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: shareCenter.incomingPhotoURLs != nil) { _, hasIncoming in
                if hasIncoming { presentSharePromptsIfNeeded() }
            }
            .onChange(of: shareCenter.hasUnreportedReadFailure) { _, hasFailure in
                if hasFailure { presentSharePromptsIfNeeded() }
            }
            .onChange(of: isPresentingOther) { _, busy in
                // 其它弹窗/弹层关闭后再补弹收图询问；稍等让上一个呈现的退场动画结束
                guard !busy else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    presentSharePromptsIfNeeded()
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
            .alert("照片读取失败", isPresented: $showShareReadError) {
                Button("好的", role: .cancel) { }
            } message: {
                Text("有分享的照片无法读取，请重新分享。")
            }
    }
}

// MARK: - AI 整理相关的弹窗与 sheet（拆出 body，避免修饰符链过长导致类型检查超时）

private extension View {
    func formattingHandling(_ editor: iOSNoteEditorView) -> some View {
        editor.applyFormattingHandling(to: self)
    }
}

extension iOSNoteEditorView {
    fileprivate func applyFormattingHandling<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $formattingPreview, onDismiss: {
                if let message = pendingFormattingError {
                    pendingFormattingError = nil
                    formattingErrorMessage = message
                }
            }) { preview in
                FormattingPreviewSheet(preview: preview) {
                    applyFormattingPreview(preview)
                } onCancel: {
                    formattingPreview = nil
                }
            }
            .sheet(isPresented: $showAISettings) {
                NavigationStack {
                    AISettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showAISettings = false }
                            }
                        }
                }
            }
            .alert("尚未配置 AI 整理", isPresented: $showAISetupAlert) {
                Button("去设置") { showAISettings = true }
                Button("取消", role: .cancel) { }
            } message: {
                Text("请先填写服务商、模型和 API Key。")
            }
            .alert("整理失败", isPresented: Binding(
                get: { formattingErrorMessage != nil },
                set: { if !$0 { formattingErrorMessage = nil } }
            )) {
                Button("好的", role: .cancel) { formattingErrorMessage = nil }
            } message: {
                Text(formattingErrorMessage ?? "")
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
