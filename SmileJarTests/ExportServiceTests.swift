import Testing
import Foundation
import SwiftData
@testable import SmileJar

@Suite("ExportService")
struct ExportServiceTests {

    @MainActor
    @Test func emptyExportProducesZip() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let ctx = container.mainContext
        ModelContainerFactory.seedIfNeeded(context: ctx)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaTest_\(UUID().uuidString)")
        let store = MediaStore(rootURL: tempRoot)

        let zipURL = try ExportService.exportAll(context: ctx, mediaStore: store)
        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        #expect(size > 0)

        try? FileManager.default.removeItem(at: zipURL)
    }
}
