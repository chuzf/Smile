import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var name: String
    var colorHex: String
    var createdAt: Date
    var entries: [Entry] = []

    init(name: String, colorHex: String = "#D8A3C4", createdAt: Date = .now) {
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}
