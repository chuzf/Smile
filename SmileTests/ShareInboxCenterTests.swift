import Testing
import Foundation
import UIKit
@testable import Smile

@Suite("ShareInboxCenter")
@MainActor
struct ShareInboxCenterTests {
    func makeInbox() -> SharedInbox {
        SharedInbox(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxCenterTest_\(UUID().uuidString)"))
    }

    func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// 写入并提交一个 batch；`good` 张有效 PNG + `bad` 个无法解码的文件
    @discardableResult
    func commitBatch(_ inbox: SharedInbox, good: Int, bad: Int = 0) throws -> SharedInbox.Batch {
        let pending = try inbox.beginBatch()
        var index = 1
        for _ in 0..<good { try pending.addData(pngData(), ext: "png", index: index); index += 1 }
        for _ in 0..<bad { try pending.addData(Data("not an image".utf8), ext: "jpg", index: index); index += 1 }
        return try inbox.commit(pending)
    }

    @Test func pullDecodesImagesAndRemovesBatch() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 3)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.incomingImages?.count == 3)
        #expect(center.lastDecodeFailures == 0)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullSkipsUndecodableFiles() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.incomingImages?.count == 1)
        #expect(center.lastDecodeFailures == 1)
    }

    @Test func pullWithAllFilesBrokenReturnsFalse() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 0, bad: 2)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages == nil)
        #expect(center.lastDecodeFailures == 2)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullDoesNotOverwriteExistingIncoming() throws {
        let inbox = makeInbox()
        let first = try commitBatch(inbox, good: 1)
        let second = try commitBatch(inbox, good: 2)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: first.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: second.url.path)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(center.pullNextBatch() == true)
        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages?.count == 1)
        #expect(inbox.pendingBatches().map(\.id) == [second.id])
    }

    @Test func pullWithEmptyInboxReturnsFalse() {
        let center = ShareInboxCenter(inbox: makeInbox())
        #expect(center.pullNextBatch() == false)
        #expect(center.incomingImages == nil)
    }

    @Test func pullWithoutInboxReturnsFalse() {
        let center = ShareInboxCenter(inbox: nil)
        #expect(center.pullNextBatch() == false)
    }

    @Test func takeIncomingReturnsAndClearsState() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 2, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)
        center.pullNextBatch()

        let taken = center.takeIncoming()

        #expect(taken.images.count == 2)
        #expect(taken.failures == 1)
        #expect(center.incomingImages == nil)
        #expect(center.lastDecodeFailures == 0)
    }

    @Test func discardIncomingClearsState() throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1)
        let center = ShareInboxCenter(inbox: inbox)
        center.pullNextBatch()

        center.discardIncoming()

        #expect(center.incomingImages == nil)
    }

    @Test func editorCountTracksAppearAndNeverGoesNegative() {
        let center = ShareInboxCenter(inbox: nil)
        center.editorDidAppear()
        #expect(center.openEditorCount == 1)
        center.editorDidDisappear()
        center.editorDidDisappear()
        #expect(center.openEditorCount == 0)
    }
}
