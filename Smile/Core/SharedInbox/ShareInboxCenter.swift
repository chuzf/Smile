import UIKit
import ImageIO
import Observation

/// 主 App 内协调「从相册分享进来的照片」：
/// - 从 SharedInbox 取出最早、本进程内尚未处理过的 batch，在后台降采样解码为 `incomingImages`
/// - 记录当前打开的编辑器数量，供 RootView 决定是新开编辑器还是交给已打开的编辑器弹窗
@Observable
@MainActor
final class ShareInboxCenter {
    private let inbox: SharedInbox?

    private(set) var openEditorCount = 0
    /// 已解码、等待交给编辑器的一批照片
    private(set) var incomingImages: [UIImage]?
    /// 当前 `incomingImages` 这批里解码失败的文件数；只在 `incomingImages != nil` 期间有意义，
    /// 由 `takeIncoming`/`discardIncoming` 一起清空。
    private(set) var incomingFailures = 0

    /// 本进程内已经处理过（成功拉取或全部解码失败）的 batch id，
    /// 避免 `remove` 失败时本进程内反复回到前台又重复导入同一个 batch。
    /// 有编辑器打开时整批照片都读取失败，等编辑器弹出「照片读取失败」后清除
    private(set) var hasUnreportedReadFailure = false

    private var handledBatchIDs: Set<UUID> = []
    private var isPulling = false

    enum PullResult: Equatable {
        /// 没有可用的新 batch（或已有待处理图片 / 正在拉取中）
        case nothing
        /// 解码成功，`incomingImages` 已设置
        case ready(count: Int)
        /// batch 存在但一张都解码不出来；batch 已被删除
        case allFailed(failures: Int)
    }

    init(inbox: SharedInbox? = SharedInbox.production()) {
        self.inbox = inbox
    }

    func editorDidAppear() { openEditorCount += 1 }
    func editorDidDisappear() { openEditorCount = max(0, openEditorCount - 1) }

    /// 没有待处理图片、且当前没有正在进行的拉取时，取最早的、本进程内未处理过的 batch，
    /// 到后台线程降采样解码，再回到主线程写入状态。
    /// 并发重复调用：第二个调用在第一个调用让出主线程之前就会看到 `isPulling == true`，直接返回 `.nothing`。
    @discardableResult
    func pullNextBatch() async -> PullResult {
        guard incomingImages == nil, !isPulling, let inbox else { return .nothing }
        guard let batch = inbox.pendingBatches().first(where: { !handledBatchIDs.contains($0.id) }) else {
            return .nothing
        }
        isPulling = true
        handledBatchIDs.insert(batch.id)
        defer { isPulling = false }

        // 解码前先把 batch 移出收件箱：解码 9 张大图是最可能 OOM 的一步，若在这里被系统杀掉，
        // batch 已不在收件箱中，不会变成每次启动都重新触发崩溃的「毒 batch」。
        // 分享进来的照片是拷贝（原图仍在相册里），崩溃时丢掉这一批可以接受。
        let claimedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareProcessing", isDirectory: true)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)
        let urls: [URL]
        do {
            try FileManager.default.createDirectory(at: claimedURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: claimedURL)
            try FileManager.default.moveItem(at: batch.url, to: claimedURL)
            urls = inbox.fileURLs(in: SharedInbox.Batch(id: batch.id, url: claimedURL, createdAt: batch.createdAt))
        } catch {
            // 移动失败时退回原地解码，handledBatchIDs 保证本进程内不会重复处理
            urls = inbox.fileURLs(in: batch)
        }
        let (images, failures) = await Task.detached {
            Self.decodeBatch(urls: urls)
        }.value
        try? FileManager.default.removeItem(at: claimedURL)
        inbox.remove(batch)

        guard !images.isEmpty else { return .allFailed(failures: failures) }
        incomingImages = images
        incomingFailures = failures
        return .ready(count: images.count)
    }

    func takeIncoming() -> (images: [UIImage], failures: Int) {
        let result = (images: incomingImages ?? [], failures: incomingFailures)
        incomingImages = nil
        incomingFailures = 0
        return result
    }

    func discardIncoming() {
        _ = takeIncoming()
    }

    /// 整批读取失败但有编辑器打开（RootView 的弹窗会被挡住）时调用，交给编辑器提示
    func deferReadFailureNotice() { hasUnreportedReadFailure = true }
    func clearReadFailure() { hasUnreportedReadFailure = false }

    func purgeStaleTemporaries() {
        inbox?.purgeStaleTemporaries()
    }

    nonisolated private static func decodeBatch(urls: [URL]) -> (images: [UIImage], failures: Int) {
        var images: [UIImage] = []
        var failures = 0
        for url in urls {
            if let image = downsampledImage(at: url) {
                images.append(image)
            } else {
                failures += 1
            }
        }
        return (images, failures)
    }

    /// 用 ImageIO 按 EXIF 方向把像素摆正，并限制长边最多 `maxPixel`，避免大图直接解码占用过多内存。
    /// `kCGImageSourceCreateThumbnailFromImageAlways` + `ThumbnailMaxPixelSize` 不会把小图放大。
    nonisolated static func downsampledImage(at url: URL, maxPixel: Int = 4096) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
