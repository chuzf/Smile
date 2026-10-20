import SwiftUI
import SwiftData

// MARK: - BodySegment (persisted in entry.bodyText as JSON)

struct BodySegment {
    enum Kind: String, Codable { case text, photo }
    let kind: Kind
    var content: String?
    var path: String?
    var alignment: String?  // nil = leading, "center" = center
}

extension BodySegment: Codable {
    enum CodingKeys: String, CodingKey { case kind, content, path, alignment }
}

extension BodySegment {
    var textAlignment: TextAlignment {
        alignment == "center" ? .center : .leading
    }
    var frameAlignment: Alignment {
        alignment == "center" ? .center : .leading
    }
}

// MARK: - EditorSegment (in-memory editor state)

enum EditorSegment: Identifiable {
    case text(id: UUID, content: String, alignment: TextAlignment)
    case photo(DraftAttachment)

    var id: UUID {
        switch self {
        case .text(let id, _, _): return id
        case .photo(let d): return d.id
        }
    }
}

/// 文字块里的一个光标位置，offset 按 UTF-16 计（与 UITextView 的 NSRange 一致）
struct InsertionPoint: Equatable {
    var segmentID: UUID
    var offset: Int
}

// MARK: - iOSNoteEditorModel

@Observable final class iOSNoteEditorModel {
    var segments: [EditorSegment] = [.text(id: UUID(), content: "", alignment: .leading)]
    var voiceAttachments: [DraftAttachment] = []
    var selectedGroupID: PersistentIdentifier?
    var selectedTags: Set<PersistentIdentifier> = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isDirty: Bool = false
    var isSaving: Bool = false
    var dictationTargetSegmentID: UUID? = nil
    var dictationBaseText: String = ""
    var lastAutoSaveTime: Date = Date.distantPast
    // Incremented each time performAutoSave fires so the view can react and persist.
    private(set) var autoSaveSignal: Int = 0
    /// 最后一次光标所在位置，收起键盘后仍保留，相册、拍摄的照片插在这里。只在插入时读取，不触发界面刷新
    @ObservationIgnored var insertionPoint: InsertionPoint?

    private var autoSaveTask: Task<Void, Never>?

    public init() {}

    // MARK: Computed helpers

    var photoDrafts: [DraftAttachment] {
        segments.compactMap {
            if case .photo(let d) = $0 { return d } else { return nil }
        }
    }

    var allAttachments: [DraftAttachment] { photoDrafts + voiceAttachments }

    var hasContent: Bool {
        let hasText = segments.contains {
            if case .text(_, let c, _) = $0 { return !c.isEmpty } else { return false }
        }
        return hasText || !photoDrafts.isEmpty || !voiceAttachments.isEmpty
    }

    // MARK: Text segment access

    func textContent(for segmentID: UUID) -> String {
        for seg in segments {
            if case .text(let id, let content, _) = seg, id == segmentID { return content }
        }
        return ""
    }

    func updateText(_ content: String, for segmentID: UUID) {
        for i in segments.indices {
            if case .text(let id, _, let alignment) = segments[i], id == segmentID {
                segments[i] = .text(id: id, content: content, alignment: alignment)
                return
            }
        }
    }

    func updateAlignment(_ alignment: TextAlignment, for segmentID: UUID) {
        for i in segments.indices {
            if case .text(let id, let content, _) = segments[i], id == segmentID {
                segments[i] = .text(id: id, content: content, alignment: alignment)
                scheduleAutoSave()
                return
            }
        }
    }

    // MARK: Photo insertion / removal

    /// 在 `point` 处把文字块拆开插入照片；没有插入点或文字块已不存在时加在最后。
    /// 插入后插入点移到最后一张照片之后，连续插入的照片按先后顺序排列
    func insertPhotos(_ drafts: [DraftAttachment], at point: InsertionPoint?) {
        guard !drafts.isEmpty else { return }
        guard let point,
              let idx = segments.firstIndex(where: { $0.id == point.segmentID }),
              case .text(let id, let content, let alignment) = segments[idx] else {
            for draft in drafts {
                segments.append(.photo(draft))
                segments.append(.text(id: UUID(), content: "", alignment: .leading))
            }
            insertionPoint = nil
            return
        }
        let text = content as NSString
        var offset = min(max(point.offset, 0), text.length)
        // 第一行是标题，不能拆：光标在标题里时插在标题之后
        if idx == segments.firstIndex(where: { if case .text = $0 { return true } else { return false } }) {
            let titleEnd = text.range(of: "\n").location
            offset = max(offset, titleEnd == NSNotFound ? text.length : titleEnd)
        }
        var before = text.substring(to: offset)
        var after = text.substring(from: offset)
        // 光标在行首或行尾时去掉照片两侧的换行，否则照片上下会多出空行
        if before.hasSuffix("\n") { before.removeLast() }
        if after.hasPrefix("\n") { after.removeFirst() }

        var inserted: [EditorSegment] = [.text(id: id, content: before, alignment: alignment)]
        for (i, draft) in drafts.enumerated() {
            inserted.append(.photo(draft))
            if i < drafts.count - 1 {
                inserted.append(.text(id: UUID(), content: "", alignment: .leading))
            }
        }
        let afterID = UUID()
        inserted.append(.text(id: afterID, content: after, alignment: alignment))
        segments.replaceSubrange(idx...idx, with: inserted)
        insertionPoint = InsertionPoint(segmentID: afterID, offset: 0)
    }

    func removePhoto(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        segments.remove(at: idx)
        collapseAdjacentTextSegments()
    }

    // MARK: Title extraction (for saving)

    func extractTitle() -> String {
        for seg in segments {
            if case .text(_, let content, _) = seg {
                let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                return firstLine
            }
        }
        return ""
    }

    // MARK: Body segment building (for saving as JSON)

    func buildBodySegments() -> [BodySegment] {
        var result: [BodySegment] = []
        var titleLineConsumed = false
        for seg in segments {
            switch seg {
            case .text(_, let content, let alignment):
                let alignStr: String? = alignment == .center ? "center" : nil
                if !titleLineConsumed {
                    titleLineConsumed = true
                    let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let body = parts.count > 1 ? String(parts[1]) : ""
                    if !body.isEmpty {
                        result.append(BodySegment(kind: .text, content: body, path: nil, alignment: alignStr))
                    }
                } else if !content.isEmpty {
                    result.append(BodySegment(kind: .text, content: content, path: nil, alignment: alignStr))
                }
            case .photo(let draft):
                result.append(BodySegment(kind: .photo, content: nil, path: draft.relativePath, alignment: nil))
            }
        }
        return result
    }

    // MARK: Static encode/decode

    static func encodeBodySegments(_ segs: [BodySegment]) -> String {
        if segs.isEmpty { return "" }
        guard let data = try? JSONEncoder().encode(segs),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func decodeBodySegments(from bodyText: String) -> [BodySegment]? {
        guard bodyText.hasPrefix("["),
              let data = bodyText.data(using: .utf8),
              let segs = try? JSONDecoder().decode([BodySegment].self, from: data) else { return nil }
        return segs
    }

    static func plainText(from bodyText: String) -> String {
        if let segs = decodeBodySegments(from: bodyText) {
            return segs.compactMap { $0.content }.joined(separator: "\n")
        }
        return bodyText
    }

    // MARK: Load from Entry

    func load(from entry: Entry) {
        let sortedAttachments = entry.attachments.sorted { $0.sortOrder < $1.sortOrder }
        let voices = sortedAttachments.filter { $0.kind == .voice }

        if let bodySegs = Self.decodeBodySegments(from: entry.bodyText) {
            segments = buildEditorSegments(title: entry.title, bodySegs: bodySegs, allAttachments: sortedAttachments)
        } else {
            // Plain-text fallback for old entries
            let photos = sortedAttachments.filter { $0.kind == .photo }
            let firstText = entry.title + (entry.bodyText.isEmpty ? "" : "\n" + entry.bodyText)
            var built: [EditorSegment] = [.text(id: UUID(), content: firstText, alignment: .leading)]
            for p in photos {
                built.append(.photo(DraftAttachment(persistedID: p.persistentModelID, kind: p.kind, relativePath: p.relativePath, transcript: p.transcript, durationSeconds: p.durationSeconds)))
                built.append(.text(id: UUID(), content: "", alignment: .leading))
            }
            segments = built
        }

        voiceAttachments = voices.map {
            DraftAttachment(persistedID: $0.persistentModelID, kind: $0.kind, relativePath: $0.relativePath, transcript: $0.transcript, durationSeconds: $0.durationSeconds)
        }

        selectedGroupID = entry.group?.persistentModelID
        selectedTags = Set(entry.tags.map { $0.persistentModelID })
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        isDirty = false
        isSaving = false
        lastAutoSaveTime = Date.distantPast
        dictationTargetSegmentID = nil
        dictationBaseText = ""
        insertionPoint = nil
    }

    // MARK: Other

    func selectDefaultGroup(from groups: [Group], initialGroupID: PersistentIdentifier?) {
        if let id = initialGroupID, groups.contains(where: { $0.persistentModelID == id }) {
            selectedGroupID = id
            return
        }
        selectedGroupID = groups.first?.persistentModelID
    }

    func scheduleAutoSave() {
        isDirty = true
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { await performAutoSave() }
        }
    }

    /// 取消尚未触发的自动保存（放弃编辑时调用，避免关闭后再写库）
    func cancelAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    @MainActor
    func performAutoSave() async {
        isSaving = true
        defer { isSaving = false }
        lastAutoSaveTime = Date()
        updatedAt = Date()
        // 自动保存只防意外退出丢内容，不算用户保存：isDirty 保持不变，返回时仍询问保存还是放弃
        autoSaveSignal += 1   // signal view to call its real save path
    }

    func reset() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        segments = [.text(id: UUID(), content: "", alignment: .leading)]
        voiceAttachments = []
        selectedGroupID = nil
        selectedTags = []
        createdAt = Date()
        updatedAt = Date()
        isDirty = false
        isSaving = false
        lastAutoSaveTime = Date.distantPast
        autoSaveSignal = 0
        dictationTargetSegmentID = nil
        dictationBaseText = ""
        insertionPoint = nil
    }

    // MARK: Private

    private func buildEditorSegments(title: String, bodySegs: [BodySegment], allAttachments: [MediaAttachment]) -> [EditorSegment] {
        // Merge title with first body text segment (if it leads)
        let firstBodyIsText = bodySegs.first.map { $0.kind == .text } ?? false
        let leadingText = firstBodyIsText ? (bodySegs.first?.content ?? "") : ""
        let firstEditorText = title + (leadingText.isEmpty ? "" : "\n" + leadingText)

        let firstAlignment: TextAlignment = firstBodyIsText ? (bodySegs.first?.textAlignment ?? .leading) : .leading
        var built: [EditorSegment] = [.text(id: UUID(), content: firstEditorText, alignment: firstAlignment)]
        let remaining = firstBodyIsText ? Array(bodySegs.dropFirst()) : bodySegs

        for bodySeg in remaining {
            switch bodySeg.kind {
            case .text:
                built.append(.text(id: UUID(), content: bodySeg.content ?? "", alignment: bodySeg.textAlignment))
            case .photo:
                if let path = bodySeg.path {
                    let att = allAttachments.first { $0.relativePath == path }
                    let draft = DraftAttachment(persistedID: att?.persistentModelID, kind: .photo, relativePath: path, transcript: att?.transcript, durationSeconds: att?.durationSeconds)
                    built.append(.photo(draft))
                }
            }
        }

        // Always end with a text segment so user can type after last photo
        if case .photo = built.last {
            built.append(.text(id: UUID(), content: "", alignment: .leading))
        }

        return built
    }

    // MARK: Dictation

    func updateDictation(_ partial: String) {
        guard let targetID = dictationTargetSegmentID else { return }
        let separator = needsSeparator(for: dictationBaseText)
        updateText(dictationBaseText + separator + partial, for: targetID)
        isDirty = true
    }

    func commitDictation(_ final: String) {
        guard let targetID = dictationTargetSegmentID else { return }
        let separator = needsSeparator(for: dictationBaseText)
        updateText(dictationBaseText + separator + final, for: targetID)
        dictationTargetSegmentID = nil
        dictationBaseText = ""
        isDirty = true
    }

    func finalizeDictation() {
        dictationTargetSegmentID = nil
        dictationBaseText = ""
        isDirty = true
    }

    func cancelDictation() {
        if let targetID = dictationTargetSegmentID {
            updateText(dictationBaseText, for: targetID)
        }
        dictationTargetSegmentID = nil
        dictationBaseText = ""
    }

    private func needsSeparator(for base: String) -> String {
        guard !base.isEmpty,
              !base.hasSuffix(" "),
              !base.hasSuffix("\n") else { return "" }
        return " "
    }

    private func collapseAdjacentTextSegments() {
        var result: [EditorSegment] = []
        for seg in segments {
            if case .text(let newID, let newContent, _) = seg,
               let last = result.last, case .text(let lastID, let lastContent, let lastAlignment) = last {
                // Deliberate: keep the earlier segment's alignment; mixing alignments on merge is not supported.
                // 两段之间原来隔着照片，合并时另起一行；否则后段会接在前段末行，前段只有标题时正文会并进标题
                let needsNewline = !lastContent.isEmpty && !newContent.isEmpty
                    && !lastContent.hasSuffix("\n") && !newContent.hasPrefix("\n")
                let prefix = lastContent + (needsNewline ? "\n" : "")
                let merged = prefix + newContent
                // 插入点所在的块被并进前一块时跟着平移，不然下次插照片会跑到最后
                if let point = insertionPoint, point.segmentID == newID {
                    insertionPoint = InsertionPoint(segmentID: lastID, offset: prefix.utf16.count + point.offset)
                }
                result[result.count - 1] = .text(id: lastID, content: merged, alignment: lastAlignment)
            } else {
                result.append(seg)
            }
        }
        if result.isEmpty { result = [.text(id: UUID(), content: "", alignment: .leading)] }
        segments = result
    }
}
