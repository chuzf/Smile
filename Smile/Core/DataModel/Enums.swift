import Foundation

enum MediaKind: String, Codable, CaseIterable {
    case photo
    case video
    case voice
}

enum TitleSource: String, Codable {
    case auto
    case ai
    case manual
}
