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
    var lastAutoSaveTime: Date = Date.distantPast
    // Incremented each time performAutoSave fires so the view can react and persist.
    private(set) var autoSaveSignal: Int = 0

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

    func insertPhoto(_ draft: DraftAttachment, afterSegmentID: UUID?) {
        guard let anchorID = afterSegmentID,
              let anchorIdx = segments.firstIndex(where: { $0.id == anchorID }) else {
            segments.append(.photo(draft))
            segments.append(.text(id: UUID(), content: "", alignment: .leading))
            return
        }
        segments.insert(.photo(draft), at: anchorIdx + 1)
        segments.insert(.text(id: UUID(), content: "", alignment: .leading), at: anchorIdx + 2)
    }

    func insertPhotos(_ drafts: [DraftAttachment], afterSegmentID: UUID?) {
        guard !drafts.isEmpty else { return }
        if let anchorID = afterSegmentID,
           let anchorIdx = segments.firstIndex(where: { $0.id == anchorID }) {
            var offset = 1
            for draft in drafts {
                segments.insert(.photo(draft), at: anchorIdx + offset)
                segments.insert(.text(id: UUID(), content: "", alignment: .leading), at: anchorIdx + offset + 1)
                offset += 2
            }
        } else {
            for draft in drafts {
                segments.append(.photo(draft))
                segments.append(.text(id: UUID(), content: "", alignment: .leading))
            }
        }
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

    @MainActor
    func performAutoSave() async {
        isSaving = true
        defer { isSaving = false }
        lastAutoSaveTime = Date()
        updatedAt = Date()
        isDirty = false
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

    private func collapseAdjacentTextSegments() {
        var result: [EditorSegment] = []
        for seg in segments {
            if case .text(_, let newContent, _) = seg,
               let last = result.last, case .text(let lastID, let lastContent, let lastAlignment) = last {
                // Deliberate: keep the earlier segment's alignment; mixing alignments on merge is not supported.
                result[result.count - 1] = .text(id: lastID, content: lastContent + newContent, alignment: lastAlignment)
            } else {
                result.append(seg)
            }
        }
        if result.isEmpty { result = [.text(id: UUID(), content: "", alignment: .leading)] }
        segments = result
    }
}
