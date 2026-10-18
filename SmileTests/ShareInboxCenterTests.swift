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

    @Test func pullDecodesImagesAndRemovesBatch() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 3)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .ready(count: 3))
        #expect(center.incomingImages?.count == 3)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullPreservesFileOrder() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 3, widths: [8, 9, 10])
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .ready(count: 3))
        #expect(center.incomingImages?.map { Int($0.size.width) } == [8, 9, 10])
    }

    @Test func pullSkipsUndecodableFiles() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        #expect(center.takeIncoming().failures == 1)
    }

    @Test func pullWithAllFilesBrokenReturnsAllFailed() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 0, bad: 2)
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .allFailed(failures: 2))
        #expect(center.incomingImages == nil)
        #expect(inbox.pendingBatches().isEmpty)
    }

    @Test func pullAfterAllFailedThenEmptyReturnsNothing() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 0, bad: 2)
        let center = ShareInboxCenter(inbox: inbox)

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
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        #expect(await center.pullNextBatch() == .nothing)
        #expect(center.incomingImages?.count == 1)
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
        let center = ShareInboxCenter(inbox: inbox)

        #expect(await center.pullNextBatch() == .ready(count: 1))
        _ = center.takeIncoming()
        #expect(await center.pullNextBatch() == .ready(count: 2))
    }

    @Test func pullWithEmptyInboxReturnsNothing() async {
        let center = ShareInboxCenter(inbox: makeInbox())
        #expect(await center.pullNextBatch() == .nothing)
        #expect(center.incomingImages == nil)
    }

    @Test func pullWithoutInboxReturnsNothing() async {
        let center = ShareInboxCenter(inbox: nil)
        #expect(await center.pullNextBatch() == .nothing)
    }

    @Test func concurrentPullsYieldExactlyOneReadyAndOneNothing() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1)
        try commitBatch(inbox, good: 1)
        let center = ShareInboxCenter(inbox: inbox)

        async let a = center.pullNextBatch()
        async let b = center.pullNextBatch()
        let (ra, rb) = await (a, b)
        let results = [ra, rb]

        #expect(results.filter { $0 == .ready(count: 1) }.count == 1)
        #expect(results.filter { $0 == .nothing }.count == 1)
    }

    @Test func takeIncomingReturnsAndClearsState() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 2, bad: 1)
        let center = ShareInboxCenter(inbox: inbox)
        _ = await center.pullNextBatch()

        let taken = center.takeIncoming()

        #expect(taken.images.count == 2)
        #expect(taken.failures == 1)
        #expect(center.incomingImages == nil)
        #expect(center.incomingFailures == 0)
    }

    @Test func discardIncomingClearsState() async throws {
        let inbox = makeInbox()
        try commitBatch(inbox, good: 1)
        let center = ShareInboxCenter(inbox: inbox)
        _ = await center.pullNextBatch()

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

    // MARK: - 降采样

    @Test func downsampledImageDoesNotUpscaleSmallImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try pngData(width: 8, height: 8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = ShareInboxCenter.downsampledImage(at: url)

        #expect(image?.size.width == 8)
        #expect(image?.size.height == 8)
    }

    @Test func downsampledImageCapsLongSideAtMaxPixel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let size = CGSize(width: 5000, height: 3000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(ShareInboxCenter.downsampledImage(at: url))

        let longSide = max(image.size.width, image.size.height)
        let shortSide = min(image.size.width, image.size.height)
        #expect(longSide == 4096)
        #expect(abs(shortSide - 3000.0 / 5000.0 * 4096.0) < 2)
    }
}
