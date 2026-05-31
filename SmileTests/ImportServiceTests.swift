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
}
