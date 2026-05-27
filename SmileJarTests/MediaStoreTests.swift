import Testing
import Foundation
@testable import SmileJar

@Suite("MediaStore")
struct MediaStoreTests {
    func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmileJarTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func saveAndLoadData() throws {
        let store = MediaStore(rootURL: tempRoot())
        let entryID = UUID()
        let data = Data("hello".utf8)
        let path = try store.save(data: data, entryID: entryID, filename: "test.txt")

        #expect(path.contains(entryID.uuidString))
        let loaded = try store.loadData(relativePath: path)
        #expect(loaded == data)
    }

    @Test func deleteEntryDirectory() throws {
        let store = MediaStore(rootURL: tempRoot())
        let entryID = UUID()
        _ = try store.save(data: Data("x".utf8), entryID: entryID, filename: "a.txt")
        _ = try store.save(data: Data("y".utf8), entryID: entryID, filename: "b.txt")

        try store.deleteEntryDirectory(entryID: entryID)
        let dir = store.directoryURL(for: entryID)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func deleteSingleFile() throws {
        let store = MediaStore(rootURL: tempRoot())
        let entryID = UUID()
        let path = try store.save(data: Data("z".utf8), entryID: entryID, filename: "c.txt")
        try store.delete(relativePath: path)

        #expect((try? store.loadData(relativePath: path)) == nil)
    }
}
