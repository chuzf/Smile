import Testing
import Foundation
import SwiftData
@testable import Smile

@Suite("ImportService")
struct ImportServiceTests {

    // MARK: - Manifest version check

    @MainActor
    @Test func unsupportedVersionThrows() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = ["version": 99, "groupCount": 0, "entryCount": 0,
                        "exportedAt": "2026-01-01T00:00:00Z"] as [String: Any]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("groups.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("entries.json"))
        try encoder.encode([String]()).write(to: staging.appendingPathComponent("tags.json"))

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-v99-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try ExportService.zipDirectory(staging, to: zipURL)

        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let store = MediaStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)"))

        #expect(throws: ImportService.ImportError.unsupportedVersion(99)) {
            try ImportService.importBackup(from: zipURL, context: ctx, mediaStore: store)
        }
    }

    // MARK: - buildGroupMap

    @MainActor
    @Test func builtInGroupRemappedByName() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        ModelContainerFactory.seedIfNeeded(context: ctx)
        let existing = try ctx.fetch(FetchDescriptor<Group>())
        let builtIn = existing.first(where: \.isBuiltIn)!

        // Simulate A's built-in group having a different UUID than B's
        let srcGroup = Group(id: UUID(), name: builtIn.name,
                             iconSymbol: builtIn.iconSymbol, colorHex: builtIn.colorHex,
                             isBuiltIn: true, sortOrder: builtIn.sortOrder)
        let dto = ExportService.GroupDTO(srcGroup)

        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: existing, context: ctx)

        #expect(map[dto.id]?.id == builtIn.id)  // maps to B's group, not A's UUID
        #expect(newCount == 0)
    }

    @MainActor
    @Test func existingCustomGroupSkipped() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let customGroup = Group(id: UUID(), name: "旅行", iconSymbol: "airplane",
                                colorHex: "#4A90E2", isBuiltIn: false, sortOrder: 5)
        ctx.insert(customGroup)
        try ctx.save()
        let existing = try ctx.fetch(FetchDescriptor<Group>())

        let dto = ExportService.GroupDTO(customGroup)  // same UUID
        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: existing, context: ctx)

        #expect(map[dto.id]?.id == customGroup.id)
        #expect(newCount == 0)
        let groups = try ctx.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 1)  // no duplicate inserted
    }

    @MainActor
    @Test func newCustomGroupInserted() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        // B has no groups
        let srcGroup = Group(id: UUID(), name: "旅行", iconSymbol: "airplane",
                             colorHex: "#4A90E2", isBuiltIn: false, sortOrder: 5)
        let dto = ExportService.GroupDTO(srcGroup)

        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: [], context: ctx)

        #expect(map[dto.id] != nil)
        #expect(newCount == 1)
        let groups = try ctx.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 1)
        #expect(groups[0].name == "旅行")
    }

    @MainActor
    @Test func unknownBuiltInGroupInserted() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        // B has no existing groups
        let srcGroup = Group(id: UUID(), name: "新内置分组", iconSymbol: "star",
                             colorHex: "#FF0000", isBuiltIn: true, sortOrder: 10)
        let dto = ExportService.GroupDTO(srcGroup)

        let (map, newCount) = ImportService.buildGroupMap(
            dtos: [dto], existing: [], context: ctx)

        #expect(map[dto.id] != nil)
        #expect(newCount == 1)
        let groups = try ctx.fetch(FetchDescriptor<Group>())
        #expect(groups.count == 1)
        #expect(groups[0].isBuiltIn == true)
    }

    // MARK: - buildTagMap

    @MainActor
    @Test func existingTagSkipped() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let existing = Smile.Tag(name: "开心", colorHex: "#FF0000")
        ctx.insert(existing)
        try ctx.save()

        let srcTag = Smile.Tag(name: "开心", colorHex: "#00FF00")  // same name, different color
        let dto = ExportService.TagDTO(srcTag)

        let (map, newCount) = ImportService.buildTagMap(
            dtos: [dto], existing: [existing], context: ctx)

        #expect(map["开心"] === existing)
        #expect(newCount == 0)
        let tags = try ctx.fetch(FetchDescriptor<Smile.Tag>())
        #expect(tags.count == 1)  // no duplicate
    }

    @MainActor
    @Test func newTagInserted() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext

        let srcTag = Smile.Tag(name: "感恩", colorHex: "#D8A3C4")
        let dto = ExportService.TagDTO(srcTag)

        let (map, newCount) = ImportService.buildTagMap(
            dtos: [dto], existing: [], context: ctx)

        #expect(map["感恩"] != nil)
        #expect(newCount == 1)
        let tags = try ctx.fetch(FetchDescriptor<Smile.Tag>())
        #expect(tags.count == 1)
        #expect(tags[0].colorHex == "#D8A3C4")
    }

    // MARK: - insertEntry / updateEntry

    @MainActor
    @Test func insertEntryCreatesRecord() throws {
        let srcContainer = try ModelContainerFactory.makeInMemory()
        let srcCtx = srcContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: srcCtx)
        let groups = try srcCtx.fetch(FetchDescriptor<Smile.Group>())
        let builtIn = groups.first(where: \.isBuiltIn)!
        let tag = Smile.Tag(name: "开心", colorHex: "#FF0")
        srcCtx.insert(tag)
        let entry = Entry(id: UUID(), title: "测试标题", titleSource: .manual,
                          bodyText: "内容", group: builtIn)
        entry.tags = [tag]
        srcCtx.insert(entry)
        try srcCtx.save()
        let dto = ExportService.EntryDTO(entry)

        let dstContainer = try ModelContainerFactory.makeInMemory()
        let dstCtx = dstContainer.mainContext
        ModelContainerFactory.seedIfNeeded(context: dstCtx)
        let dstGroups = try dstCtx.fetch(FetchDescriptor<Smile.Group>())
        let dstBuiltIn = dstGroups.first(where: { $0.name == builtIn.name })!
        let dstTag = Smile.Tag(name: "开心", colorHex: "#FF0")
        dstCtx.insert(dstTag)

        let groupMap: [UUID: Smile.Group] = [builtIn.id: dstBuiltIn]
        let tagMap: [String: Smile.Tag] = ["开心": dstTag]

        ImportService.insertEntry(from: dto, groupMap: groupMap,
                                  tagMap: tagMap, context: dstCtx)
        try dstCtx.save()

        let entries = try dstCtx.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 1)
        #expect(entries[0].id == entry.id)
        #expect(entries[0].title == "测试标题")
        #expect(entries[0].bodyText == "内容")
        #expect(entries[0].group?.id == dstBuiltIn.id)
        #expect(entries[0].tags.map(\.name).contains("开心"))
    }

    @MainActor
    @Test func updateEntryOverwritesWhenNewer() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)
        let entry = Entry(id: UUID(), title: "旧标题", bodyText: "旧内容",
                          updatedAt: oldDate)
        ctx.insert(entry)
        try ctx.save()

        // Build DTO from a source entry with newer updatedAt
        let srcContainer = try ModelContainerFactory.makeInMemory()
        let srcCtx = srcContainer.mainContext
        let srcEntry = Entry(id: entry.id, title: "新标题", bodyText: "新内容",
                             updatedAt: newDate)
        srcCtx.insert(srcEntry)
        try srcCtx.save()
        let dto = ExportService.EntryDTO(srcEntry)

        ImportService.updateEntry(entry, from: dto, groupMap: [:],
                                  tagMap: [:], context: ctx)

        #expect(entry.title == "新标题")
        #expect(entry.bodyText == "新内容")
        #expect(entry.updatedAt == newDate)
    }
}
