import Foundation
import ImageIO
import Observation

/// 主 App 内协调「从相册分享进来的照片」：
/// - 从 SharedInbox 取出最早、本进程内尚未处理过的 batch，移到 `tmp/ShareProcessing/<batchID>/`，
///   在后台做轻量校验（不解码像素），把有效文件的 URL 放进 `incomingPhotoURLs`。
///   全分辨率解码与 JPEG 编码由编辑器逐张完成，与 App 内相册选择器的结果一致。
/// - 记录当前打开的编辑器数量，供 RootView 决定是新开编辑器还是交给已打开的编辑器弹窗
@Observable
@MainActor
final class ShareInboxCenter {
    private let inbox: SharedInbox?
    /// 认领的 batch 存放处，默认 `tmp/ShareProcessing/`；测试注入独立目录
    private let processingRoot: URL

    private(set) var openEditorCount = 0
    /// 已校验、等待交给编辑器的一批照片文件（按分享顺序），位于 `processingRoot/<batchID>/` 下
    private(set) var incomingPhotoURLs: [URL]?
    /// 当前 `incomingPhotoURLs` 这批里无法读取的文件数；只在 `incomingPhotoURLs != nil` 期间有意义，
    /// 由 `takeIncoming`/`discardIncoming` 一起清空。
    private(set) var incomingFailures = 0

    /// 有编辑器打开时整批照片都读取失败，等编辑器弹出「照片读取失败」后清除
    private(set) var hasUnreportedReadFailure = false

    /// 本进程内已经处理过（成功拉取或全部读取失败）的 batch id，
    /// 避免 `remove` 失败时本进程内反复回到前台又重复导入同一个 batch。
    private var handledBatchIDs: Set<UUID> = []
    private var isPulling = false
    /// `incomingPhotoURLs` 所在的认领目录；`purgeStaleTemporaries` 不能删它
    private var incomingDirectory: URL?
    /// 已经 `takeIncoming` 交给编辑器、尚未 `finishHandOff` 的认领目录名（batch UUID；用名字而非路径比较，避免 /var 与 /private/var 等别名不一致）。
    /// 编辑器可能在插入途中被挂起很久，不能只靠修改时间判断是否遗留
    private var handedOffDirectories: Set<String> = []

    enum PullResult: Equatable {
        /// 没有可用的新 batch（或已有待处理照片 / 正在拉取中）
        case nothing
        /// 至少一个文件可读，`incomingPhotoURLs` 已设置
        case ready(count: Int)
        /// batch 存在但一个可读文件都没有；batch 已被删除
        case allFailed(failures: Int)
    }

    init(inbox: SharedInbox? = SharedInbox.production(),
         processingRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareProcessing", isDirectory: true)) {
        self.inbox = inbox
        self.processingRoot = processingRoot
    }

    func editorDidAppear() { openEditorCount += 1 }
    func editorDidDisappear() { openEditorCount = max(0, openEditorCount - 1) }

    /// 没有待处理照片、且当前没有正在进行的拉取时，取最早的、本进程内未处理过的 batch，
    /// 到后台线程校验文件，再回到主线程写入状态。
    /// 并发重复调用：第二个调用在第一个调用让出主线程之前就会看到 `isPulling == true`，直接返回 `.nothing`。
    @discardableResult
    func pullNextBatch() async -> PullResult {
        guard incomingPhotoURLs == nil, !isPulling, let inbox else { return .nothing }
        guard let batch = inbox.pendingBatches().first(where: { !handledBatchIDs.contains($0.id) }) else {
            return .nothing
        }
        isPulling = true
        handledBatchIDs.insert(batch.id)
        defer { isPulling = false }

        // 处理前先把 batch 移出收件箱：之后编辑器要逐张全分辨率解码 9 张大图，这是最可能 OOM 的阶段，
        // 若在这期间被系统杀掉，batch 已不在收件箱中，不会变成每次启动都重新触发崩溃的「毒 batch」。
        // 分享进来的照片是拷贝（原图仍在相册里），崩溃时丢掉这一批可以接受；
        // 遗留的认领目录由 `purgeStaleTemporaries` 清理。
        let claimedURL = processingRoot.appendingPathComponent(batch.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: processingRoot, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: claimedURL)
            try FileManager.default.moveItem(at: batch.url, to: claimedURL)
        } catch {
            // 移动失败时退回复制；仍失败则这批无法处理，删掉，handledBatchIDs 保证本进程内不会重复处理
            let count = inbox.fileURLs(in: batch).count
            do {
                try FileManager.default.copyItem(at: batch.url, to: claimedURL)
                inbox.remove(batch)
            } catch {
                try? FileManager.default.removeItem(at: claimedURL)
                inbox.remove(batch)
                return .allFailed(failures: max(count, 1))
            }
        }
        // 重命名会保留 batch 原来的时间；刷新修改时间，`purgeStaleTemporaries` 按它判断是否遗留
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: claimedURL.path)

        let urls = inbox.fileURLs(in: SharedInbox.Batch(id: batch.id, url: claimedURL, createdAt: batch.createdAt))
        let (valid, failures) = await Task.detached {
            Self.validateFiles(urls)
        }.value

        guard !valid.isEmpty else {
            try? FileManager.default.removeItem(at: claimedURL)
            return .allFailed(failures: failures)
        }
        incomingPhotoURLs = valid
        incomingFailures = failures
        incomingDirectory = claimedURL
        return .ready(count: valid.count)
    }

    /// 取走照片文件与失败计数并清空状态。调用方从此拥有这些文件，
    /// 处理完（或放弃）后必须调用且只调用一次 `finishHandOff(of:)`。
    func takeIncoming() -> (urls: [URL], failures: Int) {
        let result = (urls: incomingPhotoURLs ?? [], failures: incomingFailures)
        if let dir = incomingDirectory, !result.urls.isEmpty {
            handedOffDirectories.insert(dir.lastPathComponent)
        }
        incomingPhotoURLs = nil
        incomingFailures = 0
        incomingDirectory = nil
        return result
    }

    /// 放弃当前这批：删除文件及其认领目录
    func discardIncoming() {
        let dir = incomingDirectory
        let taken = takeIncoming()
        finishHandOff(of: taken.urls)
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 交接结束：删除仍残留的文件（目录空了一并删除），并让 `purgeStaleTemporaries` 不再保护这些目录
    func finishHandOff(of urls: [URL]) {
        for url in urls { Self.deleteHandedOffFile(url) }
        for dir in Set(urls.map { $0.deletingLastPathComponent().lastPathComponent }) {
            handedOffDirectories.remove(dir)
        }
    }

    /// 删除一个已交接的照片文件；所在认领目录空了就一起删掉
    nonisolated static func deleteHandedOffFile(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        if let rest = try? fm.contentsOfDirectory(atPath: dir.path), rest.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    /// 整批读取失败但有编辑器打开（RootView 的弹窗会被挡住）时调用，交给编辑器提示
    func deferReadFailureNotice() { hasUnreportedReadFailure = true }
    func clearReadFailure() { hasUnreportedReadFailure = false }

    /// 清理扩展遗留的 `.tmp-*`，以及插入过程中崩溃遗留的、超过 `age` 未改动的认领目录
    /// （当前持有的那批、以及已交给编辑器还在处理中的除外）
    func purgeStaleTemporaries(olderThan age: TimeInterval = 3600, now: Date = .now) {
        inbox?.purgeStaleTemporaries(olderThan: age, now: now)
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: processingRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var protected = handedOffDirectories
        if let held = incomingDirectory?.lastPathComponent { protected.insert(held) }
        for dir in dirs where !protected.contains(dir.lastPathComponent) {
            // 读不到时间时不删，避免误删正在使用的目录
            guard let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            if now.timeIntervalSince(modified) > age {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 只读文件头与属性、不解码像素：能建出 image source、至少一帧、且首帧宽高为正才算有效。
    /// 无效文件当场删除并计数。
    nonisolated private static func validateFiles(_ urls: [URL]) -> (valid: [URL], failures: Int) {
        var valid: [URL] = []
        var failures = 0
        for url in urls {
            if isReadableImage(url) {
                valid.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
                failures += 1
            }
        }
        return (valid, failures)
    }

    nonisolated private static func isReadableImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return false }
        return width > 0 && height > 0
    }
}
