import UIKit
import Observation

/// 主 App 内协调「从相册分享进来的照片」：
/// - 从 SharedInbox 取出最早的 batch 并解码为 `incomingImages`
/// - 记录当前打开的编辑器数量，供 RootView 决定是新开编辑器还是交给已打开的编辑器弹窗
@Observable
@MainActor
final class ShareInboxCenter {
    private let inbox: SharedInbox?

    private(set) var openEditorCount = 0
    /// 已解码、等待交给编辑器的一批照片
    private(set) var incomingImages: [UIImage]?
    private(set) var lastDecodeFailures = 0

    init(inbox: SharedInbox? = SharedInbox.production()) {
        self.inbox = inbox
    }

    func editorDidAppear() { openEditorCount += 1 }
    func editorDidDisappear() { openEditorCount = max(0, openEditorCount - 1) }

    /// 没有待处理图片时，取最早的 batch 解码并删除它。
    /// 返回是否得到了至少一张图片；全部解码失败时返回 false，失败数见 `lastDecodeFailures`。
    @discardableResult
    func pullNextBatch() -> Bool {
        guard incomingImages == nil, let inbox, let batch = inbox.pendingBatches().first else { return false }
        var images: [UIImage] = []
        var failures = 0
        for url in inbox.fileURLs(in: batch) {
            if let image = UIImage(contentsOfFile: url.path) {
                images.append(image)
            } else {
                failures += 1
            }
        }
        inbox.remove(batch)
        lastDecodeFailures = failures
        guard !images.isEmpty else { return false }
        incomingImages = images
        return true
    }

    func takeIncoming() -> (images: [UIImage], failures: Int) {
        let result = (images: incomingImages ?? [], failures: lastDecodeFailures)
        incomingImages = nil
        lastDecodeFailures = 0
        return result
    }

    func discardIncoming() {
        _ = takeIncoming()
    }

    func purgeStaleTemporaries() {
        inbox?.purgeStaleTemporaries()
    }
}
