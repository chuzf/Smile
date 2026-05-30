import SwiftUI
import SwiftData

@Observable
final class EntryEditorModel {
    var title: String = ""
    var titleSource: TitleSource = .auto
    var bodyText: String = ""
    var selectedGroupID: PersistentIdentifier?
    var attachments: [DraftAttachment] = []
    var selectedTags: Set<PersistentIdentifier> = []
    var createdAt: Date = .now

    func selectDefaultGroup(from groups: [Group], initialGroupID: PersistentIdentifier? = nil) {
        guard selectedGroupID == nil else { return }
        selectedGroupID = initialGroupID
            ?? groups.first(where: { $0.isBuiltIn && $0.name == "微笑储蓄罐" })?.persistentModelID
    }

    /// 编辑模式时载入已有 Entry
    func load(from entry: Entry) {
        title = entry.title
        titleSource = entry.titleSource
        bodyText = entry.bodyText
        selectedGroupID = entry.group?.persistentModelID
        createdAt = entry.createdAt
        attachments = entry.attachments
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { DraftAttachment(persistedID: $0.persistentModelID,
                                   kind: $0.kind,
                                   relativePath: $0.relativePath,
                                   transcript: $0.transcript,
                                   durationSeconds: $0.durationSeconds) }
        selectedTags = Set(entry.tags.map { $0.persistentModelID })
    }
}

