import Foundation

struct MediaStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// 生产环境用 Documents/Media
    static func production() -> MediaStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return MediaStore(rootURL: docs.appendingPathComponent("Media"))
    }

    func directoryURL(for entryID: UUID) -> URL {
        rootURL.appendingPathComponent(entryID.uuidString)
    }

    /// 返回相对 rootURL 的路径
    @discardableResult
    func save(data: Data, entryID: UUID, filename: String) throws -> String {
        let dir = directoryURL(for: entryID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return "\(entryID.uuidString)/\(filename)"
    }

    enum MediaStoreError: Error {
        case invalidPath(String)
    }

    /// 相对路径对应的文件 URL；路径为空、含 ".."（可能越出媒体根目录）或指向根目录本身时返回 nil。
    /// 逐段自行检查，不依赖 URL.standardized——它在不同系统版本上对 ".." 的处理不一致
    func resolvedURL(relativePath: String) -> URL? {
        var url = rootURL
        var depth = 0
        for part in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            url.appendPathComponent(String(part))
            depth += 1
        }
        return depth > 0 ? url : nil
    }

    /// 仅用于读取：非法路径返回根目录（目录读不出数据，调用方按读取失败处理）。删除必须走 delete(relativePath:)
    func absoluteURL(relativePath: String) -> URL {
        resolvedURL(relativePath: relativePath) ?? rootURL
    }

    func loadData(relativePath: String) throws -> Data {
        try Data(contentsOf: absoluteURL(relativePath: relativePath))
    }

    func delete(relativePath: String) throws {
        guard let url = resolvedURL(relativePath: relativePath) else {
            throw MediaStoreError.invalidPath(relativePath)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteEntryDirectory(entryID: UUID) throws {
        let dir = directoryURL(for: entryID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
