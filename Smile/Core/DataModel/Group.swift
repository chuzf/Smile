import Foundation
import SwiftData

@Model
final class Group {
    @Attribute(.unique) var id: UUID
    var name: String
    var iconSymbol: String
    var colorHex: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var createdAt: Date
    var isLocked: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Entry.group)
    var entries: [Entry] = []

    var canDelete: Bool { !isBuiltIn && entries.isEmpty }

    init(
        id: UUID = UUID(),
        name: String,
        iconSymbol: String,
        colorHex: String,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
