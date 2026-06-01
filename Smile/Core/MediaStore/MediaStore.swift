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

    func absoluteURL(relativePath: String) -> URL {
        let url = rootURL.appendingPathComponent(relativePath).standardized
        // Reject path traversal attempts (e.g. "../") that escape the media root.
        guard url.path.hasPrefix(rootURL.standardized.path) else {
            return rootURL
        }
        return url
    }

    func loadData(relativePath: String) throws -> Data {
        try Data(contentsOf: absoluteURL(relativePath: relativePath))
    }

    func delete(relativePath: String) throws {
        let url = absoluteURL(relativePath: relativePath)
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
