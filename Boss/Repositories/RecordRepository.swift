import Foundation

// MARK: - RecordRepository (Record CRUD + 搜索，记录即文件)
final class RecordRepository {
    private let db = DatabaseManager.shared
    private let storage = FileStorageService.shared

    // MARK: - Create
    @discardableResult
    func createFileRecord(from sourceURL: URL, tags: [String] = [], visibility: Record.Visibility = .private) throws -> Record {
        let id = UUID().uuidString
        let meta = try storage.saveRecordFile(from: sourceURL, recordID: id)
        let fileType = Self.detectFileType(contentType: meta.contentType, filename: meta.filename)
        let preview = try makePreview(fileType: fileType, relativePath: meta.relativePath, fallback: meta.filename)
        let textPreview = try makeTextPreview(fileType: fileType, relativePath: meta.relativePath)

        let record = Record(
            id: id,
            visibility: visibility,
            preview: preview,
            content: .init(
                kind: .file,
                fileType: fileType,
                textPreview: textPreview,
                filePath: meta.relativePath,
                filename: meta.filename,
                contentType: meta.contentType,
                sizeBytes: meta.sizeBytes,
                sha256: meta.sha256
            ),
            tags: tags
        )
        try create(record)
        return record
    }

    @discardableResult
    func createTextRecord(
        text: String,
        filename: String = "text.txt",
        tags: [String] = [],
        visibility: Record.Visibility = .private
    ) throws -> Record {
        let data = text.data(using: .utf8) ?? Data()
        return try createDataRecord(data: data, filename: filename, tags: tags, visibility: visibility, textFallback: text)
    }

    @discardableResult
    func createDataRecord(
        data: Data,
        filename: String,
        tags: [String] = [],
        visibility: Record.Visibility = .private,
        textFallback: String? = nil
    ) throws -> Record {
        let id = UUID().uuidString
        let meta = try storage.saveRecordData(data, filename: filename, recordID: id)
        let fileType = Self.detectFileType(contentType: meta.contentType, filename: meta.filename)
        let decodedText = textFallback ?? String(data: data, encoding: .utf8)
        let textPreview = fileType.isTextLike
            ? Self.previewText(decodedText ?? "", limit: 2000)
            : ""
        let preview: String = {
            if fileType.isTextLike, let decodedText, !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.previewText(decodedText)
            }
            return meta.filename
        }()
        let kind: Record.ContentKind = (fileType == .text) ? .text : .file

        let record = Record(
            id: id,
            visibility: visibility,
            preview: preview,
            content: .init(
                kind: kind,
                fileType: fileType,
                textPreview: textPreview,
                filePath: meta.relativePath,
                filename: meta.filename,
                contentType: meta.contentType,
                sizeBytes: meta.sizeBytes,
                sha256: meta.sha256
            ),
            tags: tags
        )
        try create(record)
        return record
    }

    func create(_ record: Record) throws {
        try db.write(
            """
            INSERT INTO records (id, visibility, preview, kind, file_type, text_preview, file_path, filename, content_type, size_bytes, sha256, created_at, updated_at, is_pinned, is_archived)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(record.id),
                .text(record.visibility.rawValue),
                .text(record.preview),
                .text(record.content.kind.rawValue),
                .text(record.content.fileType.rawValue),
                .text(record.content.textPreview),
                .text(record.content.filePath),
                .text(record.content.filename),
                .text(record.content.contentType),
                .integer(record.content.sizeBytes),
                .text(record.content.sha256),
                .real(record.createdAt.timeIntervalSince1970),
                .real(record.updatedAt.timeIntervalSince1970),
                .integer(record.isPinned ? 1 : 0),
                .integer(record.isArchived ? 1 : 0),
            ]
        )
        try syncTags(recordID: record.id, tagIDs: record.tags)
    }

    // MARK: - Read
    func fetchAll(filter: RecordFilter = RecordFilter()) throws -> [Record] {
        if !filter.searchText.isEmpty {
            return try fullTextSearch(query: filter.searchText, filter: filter)
        }

        var conditions = ["1=1"]
        var bindings: [SQLValue] = []

        conditions.append(filter.showArchived ? "r.is_archived = 1" : "r.is_archived = 0")
        if filter.showOnlyPinned {
            conditions.append("r.is_pinned = 1")
        }
        if !filter.fileTypes.isEmpty {
            let placeholders = filter.fileTypes.map { _ in "?" }.joined(separator: ",")
            conditions.append("r.file_type IN (\(placeholders))")
            filter.fileTypes.forEach { bindings.append(.text($0.rawValue)) }
        }
        if let range = filter.dateRange {
            conditions.append("r.created_at BETWEEN ? AND ?")
            bindings += [.real(range.lowerBound.timeIntervalSince1970), .real(range.upperBound.timeIntervalSince1970)]
        }

        var sql = "SELECT r.* FROM records r WHERE \(conditions.joined(separator: " AND "))"
        if !filter.tagIDs.isEmpty {
            let placeholders = filter.tagIDs.map { _ in "?" }.joined(separator: ",")
            if filter.tagMatchAny {
                sql = """
                SELECT r.* FROM records r
                JOIN record_tags rt ON rt.record_id = r.id
                WHERE rt.tag_id IN (\(placeholders)) AND \(conditions.joined(separator: " AND "))
                GROUP BY r.id
                """
            } else {
                sql = """
                SELECT r.* FROM records r
                JOIN record_tags rt ON rt.record_id = r.id
                WHERE rt.tag_id IN (\(placeholders)) AND \(conditions.joined(separator: " AND "))
                GROUP BY r.id HAVING COUNT(DISTINCT rt.tag_id) = \(filter.tagIDs.count)
                """
            }
            bindings = filter.tagIDs.map { .text($0) } + bindings
        }

        sql += filter.showPinnedFirst
            ? " ORDER BY r.is_pinned DESC, r.updated_at DESC"
            : " ORDER BY r.updated_at DESC"

        let rows = try db.read(sql, bindings: bindings, map: mapRow)
        return try rows.map { var r = $0; r.tags = try fetchTagIDs(recordID: r.id); return r }
    }

    func fetchByID(_ id: String) throws -> Record? {
        let rows = try db.read("SELECT * FROM records WHERE id = ? LIMIT 1", bindings: [.text(id)], map: mapRow)
        guard var record = rows.first else { return nil }
        record.tags = try fetchTagIDs(recordID: id)
        return record
    }

    func loadTextContent(record: Record, maxBytes: Int = 2_000_000) throws -> String {
        try storage.loadText(relativePath: record.content.filePath, maxBytes: maxBytes)
    }

    // MARK: - Update
    func update(_ record: Record) throws {
        let now = Date().timeIntervalSince1970
        try db.write(
            """
            UPDATE records SET visibility=?, preview=?, kind=?, file_type=?, text_preview=?, file_path=?, filename=?, content_type=?, size_bytes=?, sha256=?, updated_at=?, is_pinned=?, is_archived=?
            WHERE id=?
            """,
            bindings: [
                .text(record.visibility.rawValue),
                .text(record.preview),
                .text(record.content.kind.rawValue),
                .text(record.content.fileType.rawValue),
                .text(record.content.textPreview),
                .text(record.content.filePath),
                .text(record.content.filename),
                .text(record.content.contentType),
                .integer(record.content.sizeBytes),
                .text(record.content.sha256),
                .real(now),
                .integer(record.isPinned ? 1 : 0),
                .integer(record.isArchived ? 1 : 0),
                .text(record.id),
            ]
        )
        try syncTags(recordID: record.id, tagIDs: record.tags)
    }

    func updateTextContent(recordID: String, text: String) throws -> Record? {
        guard var record = try fetchByID(recordID) else { return nil }
        let meta = try storage.saveRecordText(text, filename: record.content.filename, recordID: record.id)
        let originalKind = record.content.kind
        let originalType = record.content.fileType
        record.content.kind = originalKind == .text ? .text : .file
        record.content.fileType = originalType.isTextLike ? originalType : .text
        record.content.textPreview = Self.previewText(text, limit: 2000)
        record.content.filePath = meta.relativePath
        record.content.filename = meta.filename
        record.content.contentType = meta.contentType
        record.content.sizeBytes = meta.sizeBytes
        record.content.sha256 = meta.sha256
        record.preview = Self.previewText(text)
        record.updatedAt = Date()
        try update(record)
        return try fetchByID(recordID)
    }

    func replaceFile(recordID: String, sourceURL: URL) throws -> Record? {
        guard var record = try fetchByID(recordID) else { return nil }
        let meta = try storage.saveRecordFile(from: sourceURL, recordID: record.id)
        let fileType = Self.detectFileType(contentType: meta.contentType, filename: meta.filename)
        record.content.kind = .file
        record.content.fileType = fileType
        record.content.textPreview = try makeTextPreview(fileType: fileType, relativePath: meta.relativePath)
        record.content.filePath = meta.relativePath
        record.content.filename = meta.filename
        record.content.contentType = meta.contentType
        record.content.sizeBytes = meta.sizeBytes
        record.content.sha256 = meta.sha256
        record.preview = try makePreview(fileType: fileType, relativePath: meta.relativePath, fallback: meta.filename)
        record.updatedAt = Date()
        try update(record)
        return try fetchByID(recordID)
    }

    // MARK: - Delete
    func delete(id: String) throws {
        try db.write("DELETE FROM records WHERE id = ?", bindings: [.text(id)])
        try? storage.deleteRecordDirectory(recordID: id)
    }

    // MARK: - Full-Text Search
    private func fullTextSearch(query: String, filter: RecordFilter) throws -> [Record] {
        let ftsQuery = query.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
        var sql = """
        SELECT r.* FROM records r
        JOIN records_fts fts ON fts.id = r.id
        WHERE records_fts MATCH ?
        """
        var bindings: [SQLValue] = [.text(ftsQuery)]

        sql += filter.showArchived ? " AND r.is_archived = 1" : " AND r.is_archived = 0"
        if filter.showOnlyPinned {
            sql += " AND r.is_pinned = 1"
        }
        if !filter.fileTypes.isEmpty {
            let placeholders = filter.fileTypes.map { _ in "?" }.joined(separator: ",")
            sql += " AND r.file_type IN (\(placeholders))"
            filter.fileTypes.forEach { bindings.append(.text($0.rawValue)) }
        }
        sql += filter.showPinnedFirst
            ? " ORDER BY r.is_pinned DESC, rank"
            : " ORDER BY rank"

        let rows = try db.read(sql, bindings: bindings, map: mapRow)
        return try rows.map { var r = $0; r.tags = try fetchTagIDs(recordID: r.id); return r }
    }

    // MARK: - Tag Sync
    private func syncTags(recordID: String, tagIDs: [String]) throws {
        try db.write("DELETE FROM record_tags WHERE record_id = ?", bindings: [.text(recordID)])
        for tagID in tagIDs {
            try db.write(
                "INSERT OR IGNORE INTO record_tags (record_id, tag_id) VALUES (?, ?)",
                bindings: [.text(recordID), .text(tagID)]
            )
        }
    }

    private func fetchTagIDs(recordID: String) throws -> [String] {
        try db.read(
            "SELECT tag_id FROM record_tags WHERE record_id = ?",
            bindings: [.text(recordID)],
            map: { $0["tag_id"]?.stringValue }
        )
    }

    // MARK: - Row Mapper
    private func mapRow(_ row: [String: SQLValue]) -> Record? {
        guard
            let id = row["id"]?.stringValue,
            let visibilityRaw = row["visibility"]?.stringValue,
            let visibility = Record.Visibility(rawValue: visibilityRaw),
            let kindRaw = row["kind"]?.stringValue,
            let kind = Record.ContentKind(rawValue: kindRaw),
            let fileTypeRaw = row["file_type"]?.stringValue,
            let fileType = Record.FileType(rawValue: fileTypeRaw),
            let filePath = row["file_path"]?.stringValue,
            let filename = row["filename"]?.stringValue,
            let contentType = row["content_type"]?.stringValue,
            let sizeBytes = row["size_bytes"]?.intValue,
            let sha256 = row["sha256"]?.stringValue,
            let createdAt = row["created_at"]?.doubleValue,
            let updatedAt = row["updated_at"]?.doubleValue
        else { return nil }

        return Record(
            id: id,
            visibility: visibility,
            preview: row["preview"]?.stringValue ?? "",
            content: .init(
                kind: kind,
                fileType: fileType,
                textPreview: row["text_preview"]?.stringValue ?? "",
                filePath: filePath,
                filename: filename,
                contentType: contentType,
                sizeBytes: sizeBytes,
                sha256: sha256
            ),
            tags: [],
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isPinned: row["is_pinned"]?.intValue == 1,
            isArchived: row["is_archived"]?.intValue == 1
        )
    }

    // MARK: - Helpers
    private func makePreview(fileType: Record.FileType, relativePath: String, fallback: String) throws -> String {
        if fileType.isTextLike {
            let text = try storage.loadText(relativePath: relativePath, maxBytes: 200_000)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.previewText(text)
            }
        }
        return fallback
    }

    private func makeTextPreview(fileType: Record.FileType, relativePath: String) throws -> String {
        guard fileType.isTextLike else { return "" }
        let text = try storage.loadText(relativePath: relativePath, maxBytes: 500_000)
        return Self.previewText(text, limit: 2000)
    }

    static func previewText(_ text: String, limit: Int = 220) -> String {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let idx = normalized.index(normalized.startIndex, offsetBy: limit - 1)
        return String(normalized[..<idx]) + "…"
    }

    static func detectFileType(contentType: String, filename: String) -> Record.FileType {
        let ctype = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let suffix = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let dotSuffix = suffix.isEmpty ? "" : ".\(suffix)"

        if ctype.hasPrefix("image/") || [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg"].contains(dotSuffix) {
            return .image
        }
        if ctype.hasPrefix("video/") || [".mp4", ".mov", ".webm", ".mkv", ".avi"].contains(dotSuffix) {
            return .video
        }
        if ctype.hasPrefix("audio/") || [".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac"].contains(dotSuffix) {
            return .audio
        }
        if ["text/html", "application/xhtml+xml"].contains(ctype) || [".html", ".htm", ".xhtml"].contains(dotSuffix) {
            return .web
        }
        if [".log", ".out", ".err"].contains(dotSuffix) {
            return .log
        }
        if ["application/x-sqlite3", "application/vnd.sqlite3"].contains(ctype) || [".db", ".sqlite", ".sqlite3", ".db3"].contains(dotSuffix) {
            return .database
        }
        if [
            "application/zip", "application/x-zip-compressed", "application/x-tar", "application/gzip",
            "application/x-gzip", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar-compressed",
            "application/x-bzip2", "application/x-xz"
        ].contains(ctype) || [".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz", ".tbz2", ".xz", ".txz", ".7z", ".rar"].contains(dotSuffix) {
            return .archive
        }
        if [
            "application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet",
            "application/vnd.oasis.opendocument.presentation"
        ].contains(ctype) || [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".odt", ".ods", ".odp"].contains(dotSuffix) {
            return .document
        }
        if ctype.hasPrefix("text/") || [
            "application/json", "application/ld+json", "application/xml", "application/yaml", "application/x-yaml",
            "application/toml", "application/x-toml", "application/javascript", "application/x-javascript", "application/sql",
            "application/csv", "application/x-sh", "application/x-httpd-php"
        ].contains(ctype) || [
            ".txt", ".md", ".markdown", ".rst", ".json", ".jsonl", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
            ".csv", ".tsv", ".xml", ".html", ".htm", ".css", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".java",
            ".go", ".rs", ".c", ".h", ".cpp", ".hpp", ".cc", ".sql", ".sh", ".bash", ".zsh", ".ps1", ".rb", ".php", ".swift",
            ".kt", ".kts", ".dart", ".vue", ".svelte", ".env", ".log"
        ].contains(dotSuffix) {
            return .text
        }
        return .file
    }
}
