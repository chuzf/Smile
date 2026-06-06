import Foundation
import SwiftData
import CryptoKit
import CommonCrypto

enum ExportService {

    struct ExportManifest: Codable {
        let version: Int
        let exportedAt: Date
        let groupCount: Int
        let entryCount: Int
    }

    // MARK: - Encrypted file format
    // Layout: magic(8) + salt(16) + AES-GCM.combined(nonce 12 + ciphertext + tag 16)
    static let encryptedFileMagic = Data("SMILJAR1".utf8)

    // MARK: - Export

    /// 生成备份文件，返回临时文件 URL。
    /// password 非空时生成 .smilejar 加密文件，否则生成普通 .zip。
    @MainActor
    static func exportAll(context: ModelContext, mediaStore: MediaStore, password: String? = nil) throws -> URL {
        let groups = try context.fetch(FetchDescriptor<Group>())
        let entries = try context.fetch(FetchDescriptor<Entry>())
        let tags = try context.fetch(FetchDescriptor<Tag>())

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let manifest = ExportManifest(
            version: 1, exportedAt: .now,
            groupCount: groups.count, entryCount: entries.count
        )
        try encoder.encode(manifest)
            .write(to: staging.appendingPathComponent("manifest.json"))

        try encoder.encode(groups.map(GroupDTO.init))
            .write(to: staging.appendingPathComponent("groups.json"))
        try encoder.encode(entries.map(EntryDTO.init))
            .write(to: staging.appendingPathComponent("entries.json"))
        try encoder.encode(tags.map(TagDTO.init))
            .write(to: staging.appendingPathComponent("tags.json"))

        let mediaDir = staging.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        for entry in entries {
            let src = mediaStore.directoryURL(for: entry.id)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = mediaDir.appendingPathComponent(entry.id.uuidString)
                try FileManager.default.copyItem(at: src, to: dst)
            }
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: .now)

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-backup-\(dateStr).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try zipDirectory(staging, to: zipURL)
        try? FileManager.default.removeItem(at: staging)

        let pwd = password?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !pwd.isEmpty else { return zipURL }

        let smilejarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smilejar-backup-\(dateStr).smilejar")
        if FileManager.default.fileExists(atPath: smilejarURL.path) {
            try FileManager.default.removeItem(at: smilejarURL)
        }
        try encryptFile(at: zipURL, password: pwd, to: smilejarURL)
        try? FileManager.default.removeItem(at: zipURL)
        return smilejarURL
    }

    // MARK: - Encryption / Decryption

    static func isEncryptedBackup(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let bytes = try? handle.read(upToCount: encryptedFileMagic.count) else { return false }
        try? handle.close()
        return bytes == encryptedFileMagic
    }

    static func decryptBackup(url: URL, password: String) throws -> URL {
        let data = try Data(contentsOf: url)
        let headerSize = encryptedFileMagic.count + 16
        // Minimum: header + AES-GCM nonce(12) + tag(16)
        guard data.count > headerSize + 28 else { throw CryptoError.invalidFormat }
        guard data.prefix(encryptedFileMagic.count) == encryptedFileMagic else {
            throw CryptoError.invalidFormat
        }
        let salt = data[encryptedFileMagic.count ..< headerSize]
        let combined = data[headerSize...]
        let key = deriveKey(from: password, salt: Data(salt))
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let zipData = try AES.GCM.open(box, using: key)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".zip")
            try zipData.write(to: tempURL)
            return tempURL
        } catch {
            throw CryptoError.wrongPassword
        }
    }

    enum CryptoError: LocalizedError {
        case invalidFormat
        case wrongPassword
        case saltGenerationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat:      return "备份文件格式不正确"
            case .wrongPassword:      return "密码错误，本次导入已取消"
            case .saltGenerationFailed: return "加密失败：无法生成随机盐值"
            }
        }
    }

    private static func encryptFile(at zipURL: URL, password: String, to outputURL: URL) throws {
        let zipData = try Data(contentsOf: zipURL)
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw CryptoError.saltGenerationFailed
        }
        let salt = Data(saltBytes)
        let key = deriveKey(from: password, salt: salt)
        let sealedBox = try AES.GCM.seal(zipData, using: key)
        guard let combined = sealedBox.combined else { throw CryptoError.saltGenerationFailed }
        var output = encryptedFileMagic
        output.append(salt)
        output.append(combined)
        try output.write(to: outputURL)
    }

    // PBKDF2-SHA256, 200k iterations → 256-bit AES key
    private static func deriveKey(from password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(repeating: 0, count: 32)
        derivedKey.withUnsafeMutableBytes { dkBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pwBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.baseAddress, passwordData.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        200_000,
                        dkBytes.baseAddress, 32
                    )
                }
            }
        }
        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Zip helper

    static func zipDirectory(_ src: URL, to dst: URL) throws {
        let coord = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coord.coordinate(readingItemAt: src, options: [.forUploading], error: &coordError) { tempZip in
            do {
                try FileManager.default.moveItem(at: tempZip, to: dst)
            } catch {
                thrown = error
            }
        }
        if let e = coordError { throw e }
        if let e = thrown { throw e }
    }

    // MARK: - DTOs

    struct GroupDTO: Codable {
        let id: UUID
        let name: String
        let iconSymbol: String
        let colorHex: String
        let isBuiltIn: Bool
        let sortOrder: Int
        let createdAt: Date
        let isLocked: Bool
        init(_ g: Group) {
            id = g.id; name = g.name; iconSymbol = g.iconSymbol
            colorHex = g.colorHex; isBuiltIn = g.isBuiltIn; sortOrder = g.sortOrder
            createdAt = g.createdAt; isLocked = g.isLocked
        }
    }

    struct EntryDTO: Codable {
        let id: UUID
        let title: String
        let titleSource: String
        let bodyText: String
        let createdAt: Date
        let updatedAt: Date
        let groupID: UUID?
        let attachments: [AttachmentDTO]
        let tagNames: [String]
        let isLocked: Bool
        init(_ e: Entry) {
            id = e.id; title = e.title; titleSource = e.titleSourceRaw
            bodyText = e.bodyText; createdAt = e.createdAt; updatedAt = e.updatedAt
            groupID = e.group?.id
            attachments = e.attachments.sorted { $0.sortOrder < $1.sortOrder }.map(AttachmentDTO.init)
            tagNames = e.tags.map(\.name)
            isLocked = e.isLocked
        }
    }

    struct AttachmentDTO: Codable {
        let kind: String
        let relativePath: String
        let thumbnailPath: String?
        let transcript: String?
        let durationSeconds: Double?
        let sortOrder: Int
        init(_ a: MediaAttachment) {
            kind = a.kindRaw; relativePath = a.relativePath; thumbnailPath = a.thumbnailPath
            transcript = a.transcript; durationSeconds = a.durationSeconds; sortOrder = a.sortOrder
        }
    }

    struct TagDTO: Codable {
        let name: String
        let colorHex: String
        let createdAt: Date
        init(_ t: Tag) { name = t.name; colorHex = t.colorHex; createdAt = t.createdAt }
    }
}
