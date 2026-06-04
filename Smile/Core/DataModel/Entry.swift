import Foundation
import SwiftData

@Model
final class Entry {
    @Attribute(.unique) var id: UUID
    var title: String
    var titleSourceRaw: String   // TitleSource.rawValue
    var bodyText: String
    var createdAt: Date
    var updatedAt: Date
    var group: Group?
    var isLocked: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \MediaAttachment.entry)
    var attachments: [MediaAttachment] = []

    @Relationship(inverse: \Tag.entries)
    var tags: [Tag] = []

    var titleSource: TitleSource {
        get { TitleSource(rawValue: titleSourceRaw) ?? .auto }
        set { titleSourceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        titleSource: TitleSource = .auto,
        bodyText: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        group: Group? = nil
    ) {
        self.id = id
        self.title = title
        self.titleSourceRaw = titleSource.rawValue
        self.bodyText = bodyText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.group = group
    }
}
