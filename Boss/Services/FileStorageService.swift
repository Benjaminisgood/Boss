import Foundation
import UniformTypeIdentifiers
import CryptoKit

// MARK: - FileStorageService (本地文件存储，记录=单文件)
final class FileStorageService {
    struct StoredFileMeta {
        let relativePath: String
        let filename: String
        let contentType: String
        let sizeBytes: Int
        let sha256: String
    }

    static let shared = FileStorageService()

    private var recordsDir: URL {
        AppConfig.shared.dataPath.appendingPathComponent("records", isDirectory: true)
    }

    private init() {}

    // MARK: - Record File Save
    func saveRecordFile(from sourceURL: URL, recordID: String, preferredFilename: String? = nil) throws -> StoredFileMeta {
        let directory = try ensureRecordDirectory(recordID: recordID)
        let filename = sanitizeFilename(preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? sourceURL.lastPathComponent)
        let targetURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        return try buildMeta(for: targetURL, recordID: recordID, filename: filename)
    }

    func saveRecordText(_ text: String, filename: String = "text.txt", recordID: String) throws -> StoredFileMeta {
        let data = text.data(using: .utf8) ?? Data()
        return try saveRecordData(data, filename: filename, recordID: recordID)
    }

    func saveRecordData(_ data: Data, filename: String, recordID: String) throws -> StoredFileMeta {
        let directory = try ensureRecordDirectory(recordID: recordID)
        let safeFilename = sanitizeFilename(filename.nonEmpty ?? "text.txt")
        let targetURL = directory.appendingPathComponent(safeFilename)
        try data.write(to: targetURL, options: .atomic)
        return try buildMeta(for: targetURL, recordID: recordID, filename: safeFilename)
    }

    // MARK: - Read
    func load(relativePath: String) throws -> Data {
        let url = absoluteURL(for: relativePath)
        return try Data(contentsOf: url)
    }

    func loadText(relativePath: String, maxBytes: Int = 2_000_000) throws -> String {
        let data = try load(relativePath: relativePath)
        let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
        return String(data: clipped, encoding: .utf8) ?? String(decoding: clipped, as: UTF8.self)
    }

    func absoluteURL(for relativePath: String) -> URL {
        AppConfig.shared.dataPath.appendingPathComponent(relativePath)
    }

    // MARK: - Delete
    func delete(relativePath: String) throws {
        let url = absoluteURL(for: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteRecordDirectory(recordID: String) throws {
        let url = recordsDir.appendingPathComponent(recordID, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private
    private func ensureRecordDirectory(recordID: String) throws -> URL {
        let dir = recordsDir.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func buildMeta(for fileURL: URL, recordID: String, filename: String) throws -> StoredFileMeta {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let sizeBytes = values.fileSize ?? 0
        let contentType = values.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let data = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: data)
        let sha256 = hash.compactMap { String(format: "%02x", $0) }.joined()
        return StoredFileMeta(
            relativePath: "records/\(recordID)/\(filename)",
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: sha256
        )
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "file" : sanitized
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
