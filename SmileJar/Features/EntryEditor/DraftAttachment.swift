import SwiftData
import Foundation

/// 编辑器内的附件草稿(可能尚未入库)
struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var persistedID: PersistentIdentifier?
    var kind: MediaKind
    var relativePath: String
    var transcript: String?
    var durationSeconds: Double?

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
}
