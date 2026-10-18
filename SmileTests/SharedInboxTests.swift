import Testing
import Foundation
@testable import Smile

@Suite("SharedInbox")
struct SharedInboxTests {
    func makeInbox() -> SharedInbox {
        SharedInbox(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInboxTest_\(UUID().uuidString)"))
    }

    @Test func emptyRootHasNoBatches() {
        #expect(makeInbox().pendingBatches().isEmpty)
    }

    @Test func committedBatchIsListed() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("a".utf8), ext: "jpg", index: 1)
        let batch = try inbox.commit(pending)

        let batches = inbox.pendingBatches()
        #expect(batches.map(\.id) == [batch.id])
        #expect(inbox.fileURLs(in: batch).count == 1)
    }

    @Test func uncommittedBatchIsHidden() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("a".utf8), ext: "jpg", index: 1)

        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func discardRemovesTemporaryDirectory() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        inbox.discard(pending)

        #expect(!FileManager.default.fileExists(atPath: pending.url.path))
    }

    @Test func batchesSortedByCreationDate() throws {
        let inbox = makeInbox()
        let first = try inbox.commit(try inbox.beginBatch())
        let second = try inbox.commit(try inbox.beginBatch())
        // 人为把 second 设为更早创建
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: second.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: first.url.path)

        #expect(inbox.pendingBatches().map(\.id) == [second.id, first.id])
    }

    @Test func fileURLsSortedByIndex() throws {
        let inbox = makeInbox()
        let pending = try inbox.beginBatch()
        try pending.addData(Data("b".utf8), ext: "jpg", index: 2)
        try pending.addData(Data("c".utf8), ext: "png", index: 10)
        try pending.addData(Data("a".utf8), ext: "heic", index: 1)
        let batch = try inbox.commit(pending)

        #expect(inbox.fileURLs(in: batch).map(\.lastPathComponent) == ["0001.heic", "0002.jpg", "0010.png"])
    }

    @Test func addFileCopiesSourceWithLowercasedExtension() throws {
        let inbox = makeInbox()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src_\(UUID().uuidString).HEIC")
        try Data("img".utf8).write(to: src)
        let pending = try inbox.beginBatch()
        try pending.addFile(from: src, index: 1)
        let batch = try inbox.commit(pending)

        let files = inbox.fileURLs(in: batch)
        #expect(files.map(\.lastPathComponent) == ["0001.heic"])
        #expect(try Data(contentsOf: files[0]) == Data("img".utf8))
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func removeDeletesBatch() throws {
        let inbox = makeInbox()
        let batch = try inbox.commit(try inbox.beginBatch())
        inbox.remove(batch)

        #expect(inbox.pendingBatches().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: batch.url.path))
    }

    @Test func purgeRemovesOnlyStaleTemporaries() throws {
        let inbox = makeInbox()
        let staleTemp = try inbox.beginBatch()
        let committed = try inbox.commit(try inbox.beginBatch())

        inbox.purgeStaleTemporaries(olderThan: 3600, now: Date(timeIntervalSinceNow: 7200))

        #expect(!FileManager.default.fileExists(atPath: staleTemp.url.path))
        #expect(inbox.pendingBatches().map(\.id) == [committed.id])
    }

    @Test func purgeKeepsFreshTemporaries() throws {
        let inbox = makeInbox()
        let freshTemp = try inbox.beginBatch()

        inbox.purgeStaleTemporaries(olderThan: 3600, now: Date())

        #expect(FileManager.default.fileExists(atPath: freshTemp.url.path))
    }
}
