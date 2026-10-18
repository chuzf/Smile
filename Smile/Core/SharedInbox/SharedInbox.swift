import Foundation

/// 主 App 与分享扩展之间的照片收件箱，位于 App Group 共享容器 `ShareInbox/` 下。
/// 每次分享是一个 batch 目录：扩展先写入 `.tmp-<uuid>/`，写完后整体重命名为 `<uuid>/`，
/// 因此主 App 永远读不到写了一半的 batch。
/// 本文件同时编译进 Smile 与 SmileShare 两个 target，只能依赖 Foundation。
struct SharedInbox {
    static let appGroupID = "group.com.chuzhanfeng.smile"
    static let tempPrefix = ".tmp-"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// App Group 容器不可用（签名/entitlements 配置错误）时返回 nil
    static func production() -> SharedInbox? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        return SharedInbox(rootURL: container.appendingPathComponent("ShareInbox"))
    }

    struct Batch: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let createdAt: Date
    }

    /// 尚未提交的 batch（扩展写入中）
    struct PendingBatch {
        let id: UUID
        let url: URL

        /// 复制源文件；index 从 1 开始，决定排序
        func addFile(from source: URL, index: Int) throws {
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
            try FileManager.default.copyItem(at: source, to: url.appendingPathComponent(Self.filename(index: index, ext: ext)))
        }

        func addData(_ data: Data, ext: String, index: Int) throws {
            try data.write(to: url.appendingPathComponent(Self.filename(index: index, ext: ext)), options: .atomic)
        }

        static func filename(index: Int, ext: String) -> String {
            String(format: "%04d", index) + "." + ext
        }
    }

    func beginBatch() throws -> PendingBatch {
        let id = UUID()
        let url = rootURL.appendingPathComponent(Self.tempPrefix + id.uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PendingBatch(id: id, url: url)
    }

    @discardableResult
    func commit(_ pending: PendingBatch) throws -> Batch {
        let dest = rootURL.appendingPathComponent(pending.id.uuidString)
        try FileManager.default.moveItem(at: pending.url, to: dest)
        return Batch(id: pending.id, url: dest, createdAt: Self.creationDate(of: dest))
    }

    func discard(_ pending: PendingBatch) {
        try? FileManager.default.removeItem(at: pending.url)
    }

    /// 已提交的 batch，最早的在前。`.tmp-*` 目录因名字不是 UUID 被自然过滤。
    func pendingBatches() -> [Batch] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> Batch? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return Batch(id: id, url: url, createdAt: Self.creationDate(of: url))
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func fileURLs(in batch: Batch) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: batch.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(_ batch: Batch) {
        try? FileManager.default.removeItem(at: batch.url)
    }

    /// 清理扩展崩溃/被系统杀掉后遗留的临时目录
    func purgeStaleTemporaries(olderThan age: TimeInterval = 3600, now: Date = .now) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(Self.tempPrefix) {
            if now.timeIntervalSince(Self.creationDate(of: url)) > age {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func creationDate(of url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? .distantPast
    }
}
