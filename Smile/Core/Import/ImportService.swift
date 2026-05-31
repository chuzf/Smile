import Foundation
import SwiftData
import ZIPFoundation

enum ImportService {

    struct ImportResult: Equatable {
        let newGroups: Int
        let newEntries: Int
        let updatedEntries: Int
        let skippedEntries: Int
        let newTags: Int
    }

    enum ImportError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "不支持该备份版本（v\(v)），请更新 App 后重试"
            case .missingFile(let name):
                return "备份文件损坏：缺少 \(name)"
            }
        }
    }

    private static let supportedVersion = 1

    @MainActor
    static func importBackup(
        from zipURL: URL,
        context: ModelContext,
        mediaStore: MediaStore
    ) throws -> ImportResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        try unzip(zipURL, to: staging)

        let manifest = try readJSON(ExportService.ExportManifest.self,
                                    filename: "manifest.json", in: staging)
        guard manifest.version <= supportedVersion else {
            throw ImportError.unsupportedVersion(manifest.version)
        }

        let groupDTOs = try readJSON([ExportService.GroupDTO].self,
                                     filename: "groups.json", in: staging)
        let entryDTOs = try readJSON([ExportService.EntryDTO].self,
                                     filename: "entries.json", in: staging)
        let tagDTOs   = try readJSON([ExportService.TagDTO].self,
                                     filename: "tags.json", in: staging)

        let existingGroups  = try context.fetch(FetchDescriptor<Group>())
        let existingEntries = try context.fetch(FetchDescriptor<Entry>())
        let existingTags    = try context.fetch(FetchDescriptor<Tag>())

        let (groupMap, newGroupCount) = buildGroupMap(
            dtos: groupDTOs, existing: existingGroups, context: context)
        let (tagMap, newTagCount) = buildTagMap(
            dtos: tagDTOs, existing: existingTags, context: context)

        let existingByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
        let mediaDir = staging.appendingPathComponent("media")
        var newCount = 0, updatedCount = 0, skippedCount = 0

        for dto in entryDTOs {
            if let existing = existingByID[dto.id] {
                if dto.updatedAt > existing.updatedAt {
                    updateEntry(existing, from: dto,
                                groupMap: groupMap, tagMap: tagMap, context: context)
                    replaceMedia(entryID: dto.id, from: mediaDir, mediaStore: mediaStore)
                    updatedCount += 1
                } else {
                    skippedCount += 1
                }
            } else {
                insertEntry(from: dto, groupMap: groupMap,
                            tagMap: tagMap, context: context)
                copyMedia(entryID: dto.id, from: mediaDir, mediaStore: mediaStore)
                newCount += 1
            }
        }

        try context.save()

        return ImportResult(
            newGroups: newGroupCount,
            newEntries: newCount,
            updatedEntries: updatedCount,
            skippedEntries: skippedCount,
            newTags: newTagCount
        )
    }

    // MARK: - Private: zip + JSON helpers

    private static func unzip(_ zipURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.unzipItem(at: zipURL, to: destination)
        // NSFileCoordinator(.forUploading) wraps contents in a top-level subdirectory;
        // if that is the only item, promote its children up one level.
        let items = try fm.contentsOfDirectory(at: destination,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: .skipsHiddenFiles)
        if items.count == 1,
           let isDir = try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
           isDir == true {
            let wrapper = items[0]
            let children = try fm.contentsOfDirectory(at: wrapper,
                                                      includingPropertiesForKeys: nil,
                                                      options: .skipsHiddenFiles)
            for child in children {
                try fm.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
            try fm.removeItem(at: wrapper)
        }
    }

    private static func readJSON<T: Decodable>(
        _ type: T.Type, filename: String, in directory: URL
    ) throws -> T {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.missingFile(filename)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    // MARK: - Stubs (implemented in later tasks)

    @MainActor
    static func buildGroupMap(
        dtos: [ExportService.GroupDTO],
        existing: [Group],
        context: ModelContext
    ) -> ([UUID: Group], Int) { ([:], 0) }

    @MainActor
    static func buildTagMap(
        dtos: [ExportService.TagDTO],
        existing: [Tag],
        context: ModelContext
    ) -> ([String: Tag], Int) { ([:], 0) }

    @MainActor
    static func insertEntry(
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {}

    @MainActor
    static func updateEntry(
        _ entry: Entry,
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {}

    static func copyMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {}
    static func replaceMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {}
}
