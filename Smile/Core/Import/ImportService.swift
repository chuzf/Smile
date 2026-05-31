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

    // MARK: - Group mapping

    @MainActor
    static func buildGroupMap(
        dtos: [ExportService.GroupDTO],
        existing: [Group],
        context: ModelContext
    ) -> ([UUID: Group], Int) {
        let builtInByName = Dictionary(
            existing.filter(\.isBuiltIn).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        let customByID = Dictionary(
            existing.filter { !$0.isBuiltIn }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        var map: [UUID: Group] = [:]
        var newCount = 0

        for dto in dtos {
            if dto.isBuiltIn {
                if let match = builtInByName[dto.name] {
                    map[dto.id] = match
                } else {
                    let g = Group(id: dto.id, name: dto.name,
                                  iconSymbol: dto.iconSymbol, colorHex: dto.colorHex,
                                  isBuiltIn: true, sortOrder: dto.sortOrder,
                                  createdAt: dto.createdAt)
                    context.insert(g)
                    map[dto.id] = g
                    newCount += 1
                }
            } else {
                if let match = customByID[dto.id] {
                    map[dto.id] = match
                } else {
                    let g = Group(id: dto.id, name: dto.name,
                                  iconSymbol: dto.iconSymbol, colorHex: dto.colorHex,
                                  isBuiltIn: false, sortOrder: dto.sortOrder,
                                  createdAt: dto.createdAt)
                    context.insert(g)
                    map[dto.id] = g
                    newCount += 1
                }
            }
        }
        return (map, newCount)
    }

    // MARK: - Stubs (implemented in later tasks)

    @MainActor
    static func buildTagMap(
        dtos: [ExportService.TagDTO],
        existing: [Tag],
        context: ModelContext
    ) -> ([String: Tag], Int) {
        var map: [String: Tag] = Dictionary(
            existing.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        var newCount = 0

        for dto in dtos where map[dto.name] == nil {
            let t = Tag(name: dto.name, colorHex: dto.colorHex, createdAt: dto.createdAt)
            context.insert(t)
            map[dto.name] = t
            newCount += 1
        }
        return (map, newCount)
    }

    @MainActor
    static func insertEntry(
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {
        let group: Group? = dto.groupID.flatMap { groupMap[$0] }
        let entry = Entry(
            id: dto.id,
            title: dto.title,
            titleSource: TitleSource(rawValue: dto.titleSource) ?? .auto,
            bodyText: dto.bodyText,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            group: group
        )
        context.insert(entry)
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                durationSeconds: attDTO.durationSeconds,
                transcript: attDTO.transcript,
                sortOrder: attDTO.sortOrder,
                entry: entry
            )
            context.insert(att)
        }
    }

    @MainActor
    static func updateEntry(
        _ entry: Entry,
        from dto: ExportService.EntryDTO,
        groupMap: [UUID: Group],
        tagMap: [String: Tag],
        context: ModelContext
    ) {
        entry.title = dto.title
        entry.titleSourceRaw = dto.titleSource
        entry.bodyText = dto.bodyText
        entry.updatedAt = dto.updatedAt
        entry.group = dto.groupID.flatMap { groupMap[$0] }
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        let oldAtts = entry.attachments
        for att in oldAtts { context.delete(att) }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                durationSeconds: attDTO.durationSeconds,
                transcript: attDTO.transcript,
                sortOrder: attDTO.sortOrder,
                entry: entry
            )
            context.insert(att)
        }
    }

    static func copyMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = mediaStore.directoryURL(for: entryID)
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }
        try? FileManager.default.createDirectory(at: mediaStore.rootURL, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    static func replaceMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) {
        let dst = mediaStore.directoryURL(for: entryID)
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.createDirectory(at: mediaStore.rootURL, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
