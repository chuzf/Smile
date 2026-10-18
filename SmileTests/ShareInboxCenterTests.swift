import Testing
import Foundation
import UIKit
import ImageIO
@testable import Smile

@Suite("ShareInboxCenter")
@MainActor
struct ShareInboxCenterTests {
    func makeInbox() -> SharedInbox {
        SharedInbox(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxCenterTest_\(UUID().uuidString)"))
    }

    /// 每个测试独立的认领目录，避免与其它测试或 App 自身的 `tmp/ShareProcessing` 互相影响
    let processingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShareProcessingTest_\(UUID().uuidString)", isDirectory: true)

    func makeCenter(_ inbox: SharedInbox?) -> ShareInboxCenter {
        ShareInboxCenter(inbox: inbox, processingRoot: processingRoot)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 校验不解码像素，用 ImageIO 读出文件声明的宽度，验证顺序
    func pixelWidth(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
    }

    /// `format.scale = 1`：避免在模拟器 3x 屏幕下渲染出比指定尺寸大 3 倍的像素，
    /// 保证测试里的宽高断言对应的是实际像素尺寸。
    func pngData(width: Int = 8, height: Int = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 写入并提交一个 batch；`good` 张有效 PNG + `bad` 个无法解码的文件。
    /// `widths` 可为每张有效 PNG 指定不同宽度，用于验证顺序是否保留。
    @discardableResult
    func commitBatch(_ inbox: SharedInbox, good: Int, bad: Int = 0, widths: [Int]? = nil) throws -> SharedInbox.Batch {
        let pending = try inbox.beginBatch()
        var index = 1
        for i in 0..<good {
            let width = widths?[i] ?? 8
            try pending.addData(pngData(width: width, height: 8), ext: "png", index: index)
            index += 1
        }
        for _ in 0..<bad { try pending.addData(Data("not an image".utf8), ext: "jpg", index: index); index += 1 }
        return try inbox.commit(pending)
    }

    @Test func pullValidatesFilesAndRemovesBatch() async throws {
        let inbox = makeInbox()
        let batch = try commitBatch(inbox, good: 3)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 3))
        let urls = try #require(center.incomingPhotoURLs)
        #expect(urls.count == 3)
        #expect(urls.allSatisfy(exists))
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == batch.id.uuidString })
        #expect(inbox.pendingBatches().isEmpty)
        #expect(!exists(batch.url))
    }

    @Test func pullPreservesFileOrder() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 3, widths: [8, 9, 10])
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 3))
        #expect(center.incomingPhotoURLs?.map { pixelWidth($0) } == [8, 9, 10])
    }

    @Test func pullSkipsUndecodableFiles() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1, bad: 1)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        #expect(center.takeIncoming().failures == 1)
    }

    @Test func invalidFilesAreDeletedAndNotKept() async throws {
        let inbox = makeInbox()
        let batch = try commitBatch(inbox, good: 2, bad: 2)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 2))
        #expect(center.incomingFailures == 2)
        let dir = processingRoot.appendingPathComponent(batch.id.uuidString)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["0001.png", "0002.png"])
        #expect(center.incomingPhotoURLs?.map(\.lastPathComponent) == ["0001.png", "0002.png"])
    }

    @Test func pullWithAllFilesBrokenReturnsAllFailed() async throws {
        let inbox = makeInbox()
        let batch = try commitBatch(inbox, good: 0, bad: 2)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .allFailed(failures: 2))
        #expect(center.incomingPhotoURLs == nil)
        #expect(inbox.pendingBatches().isEmpty)
        #expect(!exists(processingRoot.appendingPathComponent(batch.id.uuidString)))
    }

    @Test func pullAfterAllFailedThenEmptyReturnsNothing() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 0, bad: 2)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .allFailed(failures: 2))
        #expect(await center.pullNextBatch() == .nothing)
    }

    @Test func pullDoesNotOverwriteExistingIncoming() async throws {
        let inbox = makeInbox()
        let first = try commitBatch(inbox, good: 1)
        let second = try commitBatch(inbox, good: 2)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: first.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: second.url.path)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        #expect(await center.pullNextBatch() == .nothing)
        #expect(center.incomingPhotoURLs?.count == 1)
        #expect(inbox.pendingBatches().map(\.id) == [second.id])
    }

    @Test func takeIncomingThenPullGetsNextBatch() async throws {
        let inbox = makeInbox()
        let first = try commitBatch(inbox, good: 1)
        let second = try commitBatch(inbox, good: 2)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)],
                                              ofItemAtPath: first.url.path)
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: second.url.path)
        let center = makeCenter(inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        _ = center.takeIncoming()
        #expect(await center.pullNextBatch() == .ready(count: 2))
    }

    @Test func pullWithEmptyInboxReturnsNothing() async {
        let center = makeCenter(makeInbox())
        #expect(await center.pullNextBatch() == .nothing)
        #expect(center.incomingPhotoURLs == nil)
    }

    @Test func pullWithoutInboxReturnsNothing() async {
        let center = makeCenter(nil)
        #expect(await center.pullNextBatch() == .nothing)
    }

    @Test func concurrentPullsYieldExactlyOneReadyAndOneNothing() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1)
        try commitBatch(inbox, good: 1)
        let center = makeCenter(inbox)

        async let a = center.pullNextBatch()
        async let b = center.pullNextBatch()
        let (ra, rb) = await (a, b)
        let results = [ra, rb]

        #expect(results.filter { $0 == .ready(count: 1) }.count == 1)
        #expect(results.filter { $0 == .nothing }.count == 1)
    }

    @Test func takeIncomingHandsOverExistingFilesAndClearsState() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 2, bad: 1)
        let center = makeCenter(inbox)
        _ = await center.pullNextBatch()

        let taken = center.takeIncoming()

        #expect(taken.urls.count == 2)
        #expect(taken.urls.allSatisfy(exists))
        #expect(taken.failures == 1)
        #expect(center.incomingPhotoURLs == nil)
        #expect(center.incomingFailures == 0)
    }

    @Test func deleteHandedOffFileRemovesDirectoryWhenEmpty() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 2)
        let center = makeCenter(inbox)
        _ = await center.pullNextBatch()
        let urls = center.takeIncoming().urls
        let dir = try #require(urls.first?.deletingLastPathComponent())

        ShareInboxCenter.deleteHandedOffFile(urls[0])
        #expect(!exists(urls[0]))
        #expect(exists(dir))
        ShareInboxCenter.deleteHandedOffFile(urls[1])
        #expect(!exists(dir))
    }

    @Test func discardIncomingDeletesFilesAndClearsState() async throws {
        let inbox = makeInbox()
        let batch = try commitBatch(inbox, good: 2)
        let center = makeCenter(inbox)
        _ = await center.pullNextBatch()
        let urls = try #require(center.incomingPhotoURLs)

        center.discardIncoming()

        #expect(center.incomingPhotoURLs == nil)
        #expect(!urls.contains(where: exists))
        #expect(!exists(processingRoot.appendingPathComponent(batch.id.uuidString)))
    }

    @Test func purgeRemovesStaleProcessingDirButKeepsHeldOne() async throws {
        let inbox = makeInbox()
        let held = try commitBatch(inbox, good: 1)
        let center = makeCenter(inbox)
        #expect(await center.pullNextBatch() == .ready(count: 1))
        let heldDir = processingRoot.appendingPathComponent(held.id.uuidString)

        let stale = processingRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try pngData().write(to: stale.appendingPathComponent("0001.png"))
        let recent = processingRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: heldDir.path)

        center.purgeStaleTemporaries()

        #expect(!exists(stale))
        #expect(exists(recent))
        #expect(exists(heldDir))
        #expect(center.incomingPhotoURLs?.allSatisfy(exists) == true)
    }

    @Test func purgeKeepsHandedOffDirUntilFinishHandOff() async throws {
        let inbox = makeInbox()
        let batch = try commitBatch(inbox, good: 2)
        let center = makeCenter(inbox)
        #expect(await center.pullNextBatch() == .ready(count: 2))
        let urls = center.takeIncoming().urls
        let dir = processingRoot.appendingPathComponent(batch.id.uuidString)
        let farFuture = Date(timeIntervalSinceNow: 10 * 86400)

        // 编辑器还在处理（例如 App 被挂起很久后回到前台）：不能删
        center.purgeStaleTemporaries(now: farFuture)
        #expect(urls.allSatisfy(exists))

        // 编辑器处理了第一张后交接结束（第二张因故没处理）：残留的会被删掉
        ShareInboxCenter.deleteHandedOffFile(urls[0])
        center.finishHandOff(of: urls)
        #expect(!exists(urls[1]))
        #expect(!exists(dir))

        // 交接结束后目录不再受保护：模拟残留目录（例如删除失败）会被清理
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        center.purgeStaleTemporaries(now: farFuture)
        #expect(!exists(dir))
    }

    @Test func readFailureNoticeCanBeDeferredAndCleared() {
        let center = makeCenter(nil)
        #expect(center.hasUnreportedReadFailure == false)
        center.deferReadFailureNotice()
        #expect(center.hasUnreportedReadFailure == true)
        center.clearReadFailure()
        #expect(center.hasUnreportedReadFailure == false)
    }

    @Test func editorCountTracksAppearAndNeverGoesNegative() {
        let center = makeCenter(nil)
        center.editorDidAppear()
        #expect(center.openEditorCount == 1)
        center.editorDidDisappear()
        center.editorDidDisappear()
        #expect(center.openEditorCount == 0)
    }
}
