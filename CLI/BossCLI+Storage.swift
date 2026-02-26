import Foundation
import SQLite3
import UniformTypeIdentifiers
import CryptoKit

extension BossCLI {
    func ensureStorageDirectories() throws {
        let dirs = [
            storageURL,
            storageURL.appendingPathComponent("records", isDirectory: true),
            storageURL.appendingPathComponent("attachments", isDirectory: true),
            storageURL.appendingPathComponent("exports", isDirectory: true)
        ]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func prepareSchemaIfNeeded() throws {
        if try tableExists("records") {
            let hasFilePath = try recordsTableHasColumn("file_path")
            let hasFileType = try recordsTableHasColumn("file_type")
            if !hasFilePath || !hasFileType {
                try migrateLegacyRecordSchema()
                try bootstrapSchema()
                return
            }

            let requiredTables = ["tags", "record_tags", "tasks", "task_run_logs", "assistant_skills", "records_fts", "assistant_pending_confirms"]
            var hasAllRequired = true
            for table in requiredTables {
                if try !tableExists(table) {
                    hasAllRequired = false
                    break
                }
            }

            if hasAllRequired {
                return
            }
        }

        try bootstrapSchema()
    }

    func tableExists(_ name: String) throws -> Bool {
        let rows = try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            bindings: [.text(name)]
        )
        return !rows.isEmpty
    }

    func recordsTableHasColumn(_ column: String) throws -> Bool {
        let rows = try db.query("PRAGMA table_info(records)")
        for row in rows {
            if row["name"]?.stringValue == column {
                return true
            }
        }
        return false
    }

    func migrateLegacyRecordSchema() throws {
        let statements = [
            "DROP TRIGGER IF EXISTS records_ai;",
            "DROP TRIGGER IF EXISTS records_ad;",
            "DROP TRIGGER IF EXISTS records_au;",
            "DROP TABLE IF EXISTS records_fts;",
            "DROP TABLE IF EXISTS record_tags;",
            "DROP TABLE IF EXISTS records;"
        ]
        for statement in statements {
            try db.execute(statement)
        }
    }

    func bootstrapSchema() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS records (
                id          TEXT PRIMARY KEY,
                visibility  TEXT NOT NULL DEFAULT 'private',
                preview     TEXT NOT NULL DEFAULT '',
                kind        TEXT NOT NULL DEFAULT 'file',
                file_type   TEXT NOT NULL DEFAULT 'file',
                text_preview TEXT NOT NULL DEFAULT '',
                file_path   TEXT NOT NULL DEFAULT '',
                filename    TEXT NOT NULL DEFAULT '',
                content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
                size_bytes  INTEGER NOT NULL DEFAULT 0,
                sha256      TEXT NOT NULL DEFAULT '',
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL,
                is_pinned   INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS tags (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                parent_id   TEXT,
                color       TEXT NOT NULL DEFAULT '#007AFF',
                icon        TEXT NOT NULL DEFAULT 'tag',
                created_at  REAL NOT NULL,
                sort_order  INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (parent_id) REFERENCES tags(id) ON DELETE SET NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS record_tags (
                record_id   TEXT NOT NULL,
                tag_id      TEXT NOT NULL,
                PRIMARY KEY (record_id, tag_id),
                FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
                FOREIGN KEY (tag_id)    REFERENCES tags(id)    ON DELETE CASCADE
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id              TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                description     TEXT NOT NULL DEFAULT '',
                template_id     TEXT,
                trigger_json    TEXT NOT NULL DEFAULT '{}',
                action_json     TEXT NOT NULL DEFAULT '{}',
                is_enabled      INTEGER NOT NULL DEFAULT 1,
                last_run_at     REAL,
                next_run_at     REAL,
                created_at      REAL NOT NULL,
                output_tag_id   TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS task_run_logs (
                id          TEXT PRIMARY KEY,
                task_id     TEXT NOT NULL,
                started_at  REAL NOT NULL,
                finished_at REAL,
                status      TEXT NOT NULL DEFAULT 'running',
                output      TEXT NOT NULL DEFAULT '',
                error       TEXT,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS assistant_skills (
                id              TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                description     TEXT NOT NULL DEFAULT '',
                trigger_hint    TEXT NOT NULL DEFAULT '',
                action_json     TEXT NOT NULL DEFAULT '{}',
                is_enabled      INTEGER NOT NULL DEFAULT 1,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS assistant_pending_confirms (
                token       TEXT PRIMARY KEY,
                payload     TEXT NOT NULL,
                created_at  REAL NOT NULL,
                expires_at  REAL NOT NULL
            );
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(
                id UNINDEXED,
                preview,
                text_preview,
                filename,
                file_type,
                content='records',
                content_rowid='rowid'
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
                INSERT INTO records_fts(rowid, id, preview, text_preview, filename, file_type)
                VALUES (new.rowid, new.id, new.preview, new.text_preview, new.filename, new.file_type);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
                INSERT INTO records_fts(records_fts, rowid, id, preview, text_preview, filename, file_type)
                VALUES ('delete', old.rowid, old.id, old.preview, old.text_preview, old.filename, old.file_type);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS records_au AFTER UPDATE ON records BEGIN
                INSERT INTO records_fts(records_fts, rowid, id, preview, text_preview, filename, file_type)
                VALUES ('delete', old.rowid, old.id, old.preview, old.text_preview, old.filename, old.file_type);
                INSERT INTO records_fts(rowid, id, preview, text_preview, filename, file_type)
                VALUES (new.rowid, new.id, new.preview, new.text_preview, new.filename, new.file_type);
            END;
            """,
            "CREATE INDEX IF NOT EXISTS idx_records_updated_at ON records(updated_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_records_file_type ON records(file_type);",
            "CREATE INDEX IF NOT EXISTS idx_records_filename ON records(filename);",
            "CREATE INDEX IF NOT EXISTS idx_record_tags_tag_id ON record_tags(tag_id);",
            "CREATE INDEX IF NOT EXISTS idx_tasks_next_run ON tasks(next_run_at);",
            "CREATE INDEX IF NOT EXISTS idx_assistant_skills_enabled ON assistant_skills(is_enabled);",
            "CREATE INDEX IF NOT EXISTS idx_assistant_pending_expires_at ON assistant_pending_confirms(expires_at);"
        ]

        for statement in statements {
            try db.execute(statement)
        }
    }

    static func extractGlobalOptions(from rawArgs: [String]) -> (storagePath: String?, remaining: [String]) {
        var storagePath: String?
        var index = 0
        while index < rawArgs.count {
            let token = rawArgs[index]
            if token == "--storage" || token == "-s" {
                if index + 1 < rawArgs.count {
                    storagePath = rawArgs[index + 1]
                    index += 2
                } else {
                    break
                }
            } else {
                break
            }
        }
        return (storagePath, Array(rawArgs.dropFirst(index)))
    }

    static func resolveStoragePath(storageArg: String?) -> URL {
        let envStorage = ProcessInfo.processInfo.environment["BOSS_STORAGE_PATH"]
        let defaultsStorage = UserDefaults(suiteName: "com.boss.app")?.string(forKey: "storagePath")
        let path = storageArg ?? envStorage ?? defaultsStorage
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let fm = FileManager.default
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent("Boss", isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Boss", isDirectory: true)
    }

    func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let clean = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "file" : clean
    }

    func detectContentType(filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    func detectFileType(contentType: String, filename: String) -> String {
        let ctype = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let suffix = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let dotSuffix = suffix.isEmpty ? "" : ".\(suffix)"

        if ctype.hasPrefix("image/") || [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg"].contains(dotSuffix) {
            return "image"
        }
        if ctype.hasPrefix("video/") || [".mp4", ".mov", ".webm", ".mkv", ".avi"].contains(dotSuffix) {
            return "video"
        }
        if ctype.hasPrefix("audio/") || [".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac"].contains(dotSuffix) {
            return "audio"
        }
        if ["text/html", "application/xhtml+xml"].contains(ctype) || [".html", ".htm", ".xhtml"].contains(dotSuffix) {
            return "web"
        }
        if [".log", ".out", ".err"].contains(dotSuffix) {
            return "log"
        }
        if ["application/x-sqlite3", "application/vnd.sqlite3"].contains(ctype) || [".db", ".sqlite", ".sqlite3", ".db3"].contains(dotSuffix) {
            return "database"
        }
        if [
            "application/zip", "application/x-zip-compressed", "application/x-tar", "application/gzip",
            "application/x-gzip", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar-compressed",
            "application/x-bzip2", "application/x-xz"
        ].contains(ctype) || [".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz", ".tbz2", ".xz", ".txz", ".7z", ".rar"].contains(dotSuffix) {
            return "archive"
        }
        if [
            "application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet",
            "application/vnd.oasis.opendocument.presentation"
        ].contains(ctype) || [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".odt", ".ods", ".odp"].contains(dotSuffix) {
            return "document"
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
            return "text"
        }

        return "file"
    }

    func previewText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "…"
    }

    func shortText(_ text: String, limit: Int) -> String {
        previewText(text, limit: limit)
    }

    func readText(relativePath: String, maxBytes: Int) throws -> String {
        let url = storageURL.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
        return String(data: clipped, encoding: .utf8) ?? String(decoding: clipped, as: UTF8.self)
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func formatDate(_ timestamp: Double?) -> String {
        guard let timestamp else { return "-" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .standard)
    }

    func timestampFilename(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date())).txt"
    }

    func iso8601Now() -> String {
        iso8601(Date())
    }

    func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}
