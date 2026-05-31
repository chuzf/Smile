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

        #expect(throws: ImportService.ImportError.self) {
            try ImportService.importBackup(from: zipURL, context: ctx, mediaStore: store)
        }
    }
}
