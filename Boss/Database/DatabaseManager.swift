import Foundation
import SQLite3

// MARK: - DatabaseManager (单例，管理 SQLite 连接)
final class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.boss.db", attributes: .concurrent)

    // 数据库文件路径
    var databaseURL: URL {
        AppConfig.shared.storagePath.appendingPathComponent("boss.sqlite")
    }

    private init() {}

    // MARK: - Open / Setup
    func setup() throws {
        if db != nil {
            close()
        }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = databaseURL.path
        guard sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw DBError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try enableWAL()
        try enableForeignKeys()
        try migrateRecordSchemaIfNeeded()
        try createTables()
    }

    func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    // MARK: - Execute Helpers

    /// 写操作（INSERT/UPDATE/DELETE），同步串行
    func write(_ sql: String, bindings: [SQLValue] = []) throws {
        try queue.sync(flags: .barrier) {
            try _execute(sql, bindings: bindings)
        }
    }

    /// 读操作，并发安全
    func read<T>(_ sql: String, bindings: [SQLValue] = [], map: ([String: SQLValue]) -> T?) throws -> [T] {
        try queue.sync {
            try _query(sql, bindings: bindings, map: map)
        }
    }

    // MARK: - Private

    private func enableWAL() throws {
        try _execute("PRAGMA journal_mode=WAL;")
    }

    private func enableForeignKeys() throws {
        try _execute("PRAGMA foreign_keys=ON;")
    }

    private func createTables() throws {
        let statements = [
            Schema.createRecords,
            Schema.createTags,
            Schema.createRecordTags,
            Schema.createAgentTasks,
            Schema.createAgentRunLogs,
            Schema.createFTS,
            Schema.createFTSTriggers,
            Schema.createIndexes
        ]
        for sql in statements {
            // 直接执行整个语句，因为触发器定义中包含多个分号
            try _execute(sql)
        }
    }

    private func migrateRecordSchemaIfNeeded() throws {
        // 非兼容重构：从旧“笔记字段”升级到“文件内容字段”时，直接重建记录相关表
        guard tableExists("records") else { return }
        let hasFilePath = recordsTableHasColumn("file_path")
        let hasLegacyContent = recordsTableHasColumn("content")
        if hasFilePath && !hasLegacyContent {
            return
        }

        let dropSQL = [
            "DROP TRIGGER IF EXISTS records_ai;",
            "DROP TRIGGER IF EXISTS records_ad;",
            "DROP TRIGGER IF EXISTS records_au;",
            "DROP TABLE IF EXISTS records_fts;",
            "DROP TABLE IF EXISTS record_tags;",
            "DROP TABLE IF EXISTS records;"
        ]
        for sql in dropSQL {
            try _execute(sql)
        }
    }

    private func tableExists(_ name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func recordsTableHasColumn(_ column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(records);", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == column {
                return true
            }
        }
        return false
    }

    private func _execute(_ sql: String, bindings: [SQLValue] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, values: bindings)
        // 处理可能返回结果行的语句（如PRAGMA）
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw DBError.stepFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
    }

    private func _query<T>(_ sql: String, bindings: [SQLValue], map: ([String: SQLValue]) -> T?) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, values: bindings)

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let colCount = sqlite3_column_count(stmt)
            var row: [String: SQLValue] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = columnValue(stmt: stmt, index: i)
            }
            if let obj = map(row) { results.append(obj) }
        }
        return results
    }

    private func bind(stmt: OpaquePointer?, values: [SQLValue]) throws {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .text(let s):    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .real(let d):    sqlite3_bind_double(stmt, idx, d)
            case .integer(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .null:           sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func columnValue(stmt: OpaquePointer?, index: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:    return .text(String(cString: sqlite3_column_text(stmt, index)))
        case SQLITE_FLOAT:   return .real(sqlite3_column_double(stmt, index))
        case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(stmt, index)))
        default:             return .null
        }
    }
}

// MARK: - Supporting Types

enum SQLValue {
    case text(String)
    case real(Double)
    case integer(Int)
    case null

    var stringValue: String? { if case .text(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .real(let d) = self { return d }; return nil }
    var intValue: Int? { if case .integer(let n) = self { return n }; return nil }
}

enum DBError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "DB open failed: \(msg)"
        case .prepareFailed(let msg, let sql): return "DB prepare failed: \(msg)\nSQL: \(sql)"
        case .stepFailed(let msg, let sql): return "DB step failed: \(msg)\nSQL: \(sql)"
        }
    }
}

// MARK: - SQLITE_TRANSIENT helper
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
