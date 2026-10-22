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
        /// 记录已写入，但照片/语音等文件没能复制过来的条目数
        var mediaFailures: Int = 0

        var summary: String {
            var text = "新增 \(newEntries) 条记录（更新 \(updatedEntries) 条）、\(newGroups) 个分组、\(newTags) 个标签，跳过 \(skippedEntries) 条已有记录"
            if mediaFailures > 0 {
                text += "。有 \(mediaFailures) 条记录的照片或语音没能复制（可能是存储空间不足），可清理空间后重新导入"
            }
            return text
        }
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
        // Track which entries need media copied AFTER a successful DB save.
        var mediaToCopy: [(UUID, Bool)] = []   // (entryID, isNew)

        for dto in entryDTOs {
            if let existing = existingByID[dto.id] {
                if dto.updatedAt > existing.updatedAt {
                    updateEntry(existing, from: dto,
                                groupMap: groupMap, tagMap: tagMap, context: context)
                    mediaToCopy.append((dto.id, false))
                    updatedCount += 1
                } else {
                    skippedCount += 1
                }
            } else {
                insertEntry(from: dto, groupMap: groupMap,
                            tagMap: tagMap, context: context)
                mediaToCopy.append((dto.id, true))
                newCount += 1
            }
        }

        // Save DB first — if this throws, no media files are copied, preventing orphans.
        do {
            try context.save()
        } catch {
            // 撤掉本次插入/修改的对象，免得之后的自动保存把半成品写进库
            context.rollback()
            throw error
        }

        // Copy media only after a successful DB save.
        var mediaFailures = 0
        for (entryID, isNew) in mediaToCopy {
            do {
                if isNew {
                    try copyMedia(entryID: entryID, from: mediaDir, mediaStore: mediaStore)
                } else {
                    try replaceMedia(entryID: entryID, from: mediaDir, mediaStore: mediaStore)
                }
            } catch {
                mediaFailures += 1
            }
        }

        return ImportResult(
            newGroups: newGroupCount,
            newEntries: newCount,
            updatedEntries: updatedCount,
            skippedEntries: skippedCount,
            newTags: newTagCount,
            mediaFailures: mediaFailures
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
                    g.isLocked = dto.isLocked
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
                    g.isLocked = dto.isLocked
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
        entry.isLocked = dto.isLocked
        context.insert(entry)
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                thumbnailPath: attDTO.thumbnailPath,
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
        entry.isLocked = dto.isLocked
        entry.group = dto.groupID.flatMap { groupMap[$0] }
        entry.tags = dto.tagNames.compactMap { tagMap[$0] }

        let oldAtts = entry.attachments
        for att in oldAtts { context.delete(att) }

        for attDTO in dto.attachments {
            let att = MediaAttachment(
                kind: MediaKind(rawValue: attDTO.kind) ?? .photo,
                relativePath: attDTO.relativePath,
                thumbnailPath: attDTO.thumbnailPath,
                durationSeconds: attDTO.durationSeconds,
                transcript: attDTO.transcript,
                sortOrder: attDTO.sortOrder,
                entry: entry
            )
            context.insert(att)
        }
    }

    static func copyMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) throws {
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        // 目标处可能有上次导入失败的残留，一并替换
        try installMedia(from: src, to: mediaStore.directoryURL(for: entryID), mediaStore: mediaStore)
    }

    static func replaceMedia(entryID: UUID, from mediaDir: URL, mediaStore: MediaStore) throws {
        let dst = mediaStore.directoryURL(for: entryID)
        let src = mediaDir.appendingPathComponent(entryID.uuidString)
        guard FileManager.default.fileExists(atPath: src.path) else {
            // 备份里这条记录没有媒体，旧文件已无记录引用
            try? FileManager.default.removeItem(at: dst)
            return
        }
        try installMedia(from: src, to: dst, mediaStore: mediaStore)
    }

    /// 先完整复制到媒体根目录下的临时位置，成功后再替换目标；复制失败时旧文件保持不动
    private static func installMedia(from src: URL, to dst: URL, mediaStore: MediaStore) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaStore.rootURL, withIntermediateDirectories: true)
        let staged = mediaStore.rootURL.appendingPathComponent(".import-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: src, to: staged)
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: dst)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }
}
