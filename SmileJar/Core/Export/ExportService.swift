import Foundation
import SwiftData

enum ExportService {

    struct ExportManifest: Codable {
        let version: Int
        let exportedAt: Date
        let groupCount: Int
        let entryCount: Int
    }

    /// 生成 zip 包,返回临时文件 URL
    @MainActor
    static func exportAll(context: ModelContext, mediaStore: MediaStore) throws -> URL {
        let groups = try context.fetch(FetchDescriptor<Group>())
        let entries = try context.fetch(FetchDescriptor<Entry>())
        let tags = try context.fetch(FetchDescriptor<Tag>())

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let manifest = ExportManifest(
            version: 1, exportedAt: .now,
            groupCount: groups.count, entryCount: entries.count
        )
        try encoder.encode(manifest)
            .write(to: staging.appendingPathComponent("manifest.json"))

        try encoder.encode(groups.map(GroupDTO.init))
            .write(to: staging.appendingPathComponent("groups.json"))
        try encoder.encode(entries.map(EntryDTO.init))
            .write(to: staging.appendingPathComponent("entries.json"))
        try encoder.encode(tags.map(TagDTO.init))
            .write(to: staging.appendingPathComponent("tags.json"))

        let mediaDir = staging.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        for entry in entries {
            let src = mediaStore.directoryURL(for: entry.id)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = mediaDir.appendingPathComponent(entry.id.uuidString)
                try FileManager.default.copyItem(at: src, to: dst)
            }
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-backup-\(df.string(from: .now)).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try zipDirectory(staging, to: zipURL)
        try? FileManager.default.removeItem(at: staging)
        return zipURL
    }

    /// 用 FileManager 的 NSFileCoordinator + .forUploading 把目录压成 zip
    private static func zipDirectory(_ src: URL, to dst: URL) throws {
        let coord = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coord.coordinate(readingItemAt: src, options: [.forUploading], error: &coordError) { tempZip in
            do {
                try FileManager.default.moveItem(at: tempZip, to: dst)
            } catch {
                thrown = error
            }
        }
        if let e = coordError { throw e }
        if let e = thrown { throw e }
    }

    // MARK: DTOs

    struct GroupDTO: Codable {
        let id: UUID
        let name: String
        let iconSymbol: String
        let colorHex: String
        let isBuiltIn: Bool
        let sortOrder: Int
        let createdAt: Date
        init(_ g: Group) {
            id = g.id; name = g.name; iconSymbol = g.iconSymbol
            colorHex = g.colorHex; isBuiltIn = g.isBuiltIn; sortOrder = g.sortOrder
            createdAt = g.createdAt
        }
    }

    struct EntryDTO: Codable {
        let id: UUID
        let title: String
        let titleSource: String
        let bodyText: String
        let createdAt: Date
        let updatedAt: Date
        let groupID: UUID?
        let attachments: [AttachmentDTO]
        let tagNames: [String]
        init(_ e: Entry) {
            id = e.id; title = e.title; titleSource = e.titleSourceRaw
            bodyText = e.bodyText; createdAt = e.createdAt; updatedAt = e.updatedAt
            groupID = e.group?.id
            attachments = e.attachments.sorted { $0.sortOrder < $1.sortOrder }.map(AttachmentDTO.init)
            tagNames = e.tags.map(\.name)
        }
    }

    struct AttachmentDTO: Codable {
        let kind: String
        let relativePath: String
        let transcript: String?
        let durationSeconds: Double?
        let sortOrder: Int
        init(_ a: MediaAttachment) {
            kind = a.kindRaw; relativePath = a.relativePath; transcript = a.transcript
            durationSeconds = a.durationSeconds; sortOrder = a.sortOrder
        }
    }

    struct TagDTO: Codable {
        let name: String
        let colorHex: String
        let createdAt: Date
        init(_ t: Tag) { name = t.name; colorHex = t.colorHex; createdAt = t.createdAt }
    }
}
