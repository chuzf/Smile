import Foundation
import SwiftData

@Model
final class MediaAttachment {
    @Attribute(.unique) var id: UUID
    var kindRaw: String              // MediaKind.rawValue
    var relativePath: String
    var thumbnailPath: String?
    var durationSeconds: Double?
    var transcript: String?
    var sortOrder: Int
    var entry: Entry?

    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .photo }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        relativePath: String,
        thumbnailPath: String? = nil,
        durationSeconds: Double? = nil,
        transcript: String? = nil,
        sortOrder: Int = 0,
        entry: Entry? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.relativePath = relativePath
        self.thumbnailPath = thumbnailPath
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.sortOrder = sortOrder
        self.entry = entry
    }
}
