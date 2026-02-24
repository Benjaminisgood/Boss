import Foundation
import SQLite3
import UniformTypeIdentifiers
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CLIError: LocalizedError {
    case invalidArguments(String)
    case sqliteOpenFailed(String)
    case sqlitePrepareFailed(String, sql: String)
    case sqliteStepFailed(String, sql: String)
    case notFound(String)
    case invalidData(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .sqliteOpenFailed(let message):
            return "数据库打开失败: \(message)"
        case .sqlitePrepareFailed(let message, let sql):
            return "数据库 prepare 失败: \(message)\nSQL: \(sql)"
        case .sqliteStepFailed(let message, let sql):
            return "数据库执行失败: \(message)\nSQL: \(sql)"
        case .notFound(let message):
            return message
        case .invalidData(let message):
            return message
        case .api(let message):
            return "API 调用失败: \(message)"
        }
    }
}

enum SQLBinding {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

enum SQLColumnValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        case .null: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        case .null: return nil
        }
    }
}

final class SQLiteDB {
    private let path: String

    init(path: String) {
        self.path = path
    }

    func execute(_ sql: String, bindings: [SQLBinding] = []) throws {
        try withConnection { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CLIError.sqlitePrepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)

            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw CLIError.sqliteStepFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
        }
    }

    func query(_ sql: String, bindings: [SQLBinding] = []) throws -> [[String: SQLColumnValue]] {
        try withConnection { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CLIError.sqlitePrepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)

            var rows: [[String: SQLColumnValue]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let columnCount = sqlite3_column_count(statement)
                var row: [String: SQLColumnValue] = [:]
                for index in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    let value: SQLColumnValue
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_TEXT:
                        value = .text(String(cString: sqlite3_column_text(statement, index)))
                    case SQLITE_INTEGER:
                        value = .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT:
                        value = .real(sqlite3_column_double(statement, index))
                    default:
                        value = .null
                    }
                    row[name] = value
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func withConnection<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CLIError.sqliteOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5000)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        return try body(db)
    }

    private func bind(_ values: [SQLBinding], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let sqliteIndex = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, sqliteIndex, text, -1, SQLITE_TRANSIENT)
            case .integer(let int):
                sqlite3_bind_int64(statement, sqliteIndex, int)
            case .real(let double):
                sqlite3_bind_double(statement, sqliteIndex, double)
            case .null:
                sqlite3_bind_null(statement, sqliteIndex)
            }
        }
    }
}

private enum AgentTrigger: Codable {
    case manual
    case cron(expression: String)
    case onRecordCreate(tagFilter: [String])
    case onRecordUpdate(tagFilter: [String])
}

private enum AgentAction: Codable {
    case createRecord(title: String, contentTemplate: String)
    case appendToRecord(recordID: String, contentTemplate: String)
    case shellCommand(command: String)
    case claudeAPI(systemPrompt: String, userPromptTemplate: String, model: String)
}

private enum LLMProvider: String {
    case claude
    case openai
    case aliyun
}

final class BossCLI {
    private let args: [String]
    private let appDefaults = UserDefaults(suiteName: "com.boss.app")
    private let storageURL: URL
    private let db: SQLiteDB

    init(arguments: [String]) {
        self.args = Array(arguments.dropFirst())

        let parsed = Self.extractGlobalOptions(from: self.args)
        let resolvedStorage = Self.resolveStoragePath(storageArg: parsed.storagePath)
        storageURL = resolvedStorage
        db = SQLiteDB(path: resolvedStorage.appendingPathComponent("boss.sqlite").path)
    }

    func run() async throws {
        try ensureStorageDirectories()
        try prepareSchemaIfNeeded()

        let parsed = Self.extractGlobalOptions(from: args)
        let commandArgs = parsed.remaining
        guard let command = commandArgs.first else {
            print(usage)
            return
        }

        switch command {
        case "help", "--help", "-h":
            print(usage)

        case "record":
            try await runRecord(args: Array(commandArgs.dropFirst()))

        case "agent":
            try await runAgent(args: Array(commandArgs.dropFirst()))

        case "assistant":
            try await runAssistant(args: Array(commandArgs.dropFirst()))

        case "list":
            try listRecords(includeArchived: false, onlyArchived: false, limit: 50)

        case "create":
            try createCompatRecord(args: Array(commandArgs.dropFirst()))

        case "delete":
            guard commandArgs.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss delete <record-id>")
            }
            try deleteRecord(id: commandArgs[1])

        case "tags":
            try listTags()

        default:
            throw CLIError.invalidArguments("Unknown command: \(command)\n\n\(usage)")
        }
    }

    private func runRecord(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(recordUsage)
        }

        switch sub {
        case "list":
            var includeArchived = false
            var onlyArchived = false
            var limit = 50
            var index = 1
            while index < args.count {
                let token = args[index]
                switch token {
                case "--all":
                    includeArchived = true
                case "--archived":
                    onlyArchived = true
                case "--limit":
                    guard index + 1 < args.count, let parsed = Int(args[index + 1]), parsed > 0 else {
                        throw CLIError.invalidArguments("--limit 需要正整数")
                    }
                    limit = parsed
                    index += 1
                default:
                    throw CLIError.invalidArguments("Unknown option: \(token)")
                }
                index += 1
            }
            try listRecords(includeArchived: includeArchived, onlyArchived: onlyArchived, limit: limit)

        case "create", "create-text":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss record create <filename> [text]")
            }
            let filename = args[1]
            let text = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : ""
            let id = try createTextRecord(filename: filename, text: text)
            print("Created record: \(id)")

        case "import":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss record import <file-path>")
            }
            let path = args[1]
            let id = try importFileRecord(filePath: path)
            print("Imported record: \(id)")

        case "show":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss record show <record-id>")
            }
            try showRecord(id: args[1])

        case "delete":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss record delete <record-id>")
            }
            try deleteRecord(id: args[1])

        default:
            throw CLIError.invalidArguments("Unknown record subcommand: \(sub)\n\n\(recordUsage)")
        }
    }

    private func runAgent(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(agentUsage)
        }

        switch sub {
        case "list":
            try listAgents()

        case "logs":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss agent logs <task-id> [--limit N]")
            }
            var limit = 30
            if args.count >= 4, args[2] == "--limit" {
                guard let parsed = Int(args[3]), parsed > 0 else {
                    throw CLIError.invalidArguments("--limit 需要正整数")
                }
                limit = parsed
            }
            try listAgentLogs(taskID: args[1], limit: limit)

        case "run":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss agent run <task-id>")
            }
            let result = try await runAgentTask(taskID: args[1])
            print(result)

        default:
            throw CLIError.invalidArguments("Unknown agent subcommand: \(sub)\n\n\(agentUsage)")
        }
    }

    private func runAssistant(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(assistantUsage)
        }

        switch sub {
        case "ask":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss assistant ask <request> [--source <source>] [--json]")
            }

            var source = "runtime"
            var outputJSON = false
            var requestTokens: [String] = []

            var index = 1
            while index < args.count {
                let token = args[index]
                if token == "--source" {
                    guard index + 1 < args.count else {
                        throw CLIError.invalidArguments("--source 需要一个值")
                    }
                    source = args[index + 1]
                    index += 2
                    continue
                }
                if token == "--json" {
                    outputJSON = true
                    index += 1
                    continue
                }
                requestTokens.append(token)
                index += 1
            }

            let request = requestTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else {
                throw CLIError.invalidArguments("assistant ask 需要自然语言请求")
            }

            let result = try await runAssistantKernel(request: request, source: source)
            try printAssistantResult(result, outputJSON: outputJSON)

        case "confirm":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss assistant confirm <token> [--source <source>] [--json]")
            }
            let token = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw CLIError.invalidArguments("assistant confirm 需要确认令牌")
            }

            var source = "runtime"
            var outputJSON = false
            var index = 2
            while index < args.count {
                let token = args[index]
                if token == "--source" {
                    guard index + 1 < args.count else {
                        throw CLIError.invalidArguments("--source 需要一个值")
                    }
                    source = args[index + 1]
                    index += 2
                    continue
                }
                if token == "--json" {
                    outputJSON = true
                    index += 1
                    continue
                }
                throw CLIError.invalidArguments("Unknown option: \(token)")
            }

            let result = try await runAssistantKernel(request: "#CONFIRM:\(token)", source: source)
            try printAssistantResult(result, outputJSON: outputJSON)

        default:
            throw CLIError.invalidArguments("Unknown assistant subcommand: \(sub)\n\n\(assistantUsage)")
        }
    }

    private func printAssistantResult(_ result: CLIAssistantResult, outputJSON: Bool) throws {
        if outputJSON {
            let payload: [String: Any] = [
                "request_id": result.requestID,
                "source": result.source,
                "request": result.request,
                "intent": result.intent,
                "planner_source": result.plannerSource,
                "planner_note": result.plannerNote ?? NSNull(),
                "tool_plan": result.toolPlan,
                "confirmation_required": result.confirmationRequired,
                "confirmation_token": result.confirmationToken ?? NSNull(),
                "confirmation_expires_at": result.confirmationExpiresAt?.timeIntervalSince1970 ?? NSNull(),
                "reply": result.reply,
                "actions": result.actions,
                "related_record_ids": result.relatedRecordIDs,
                "core_context_record_ids": result.coreContextRecordIDs,
                "core_memory_record_id": result.coreMemoryRecordID ?? NSNull(),
                "audit_record_id": result.auditRecordID ?? NSNull(),
                "started_at": result.startedAt.timeIntervalSince1970,
                "finished_at": result.finishedAt.timeIntervalSince1970,
                "succeeded": result.succeeded
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print(result.reply)
        print("intent: \(result.intent)")
        print("planner: \(result.plannerSource)")
        if let plannerNote = result.plannerNote, !plannerNote.isEmpty {
            print("planner note: \(plannerNote)")
        }
        if result.confirmationRequired {
            print("confirmation required: yes")
            if let token = result.confirmationToken {
                print("confirmation token: \(token)")
            }
            if let expiresAt = result.confirmationExpiresAt {
                print("confirmation expires: \(iso8601(expiresAt))")
            }
        }
        if let coreMemoryRecordID = result.coreMemoryRecordID {
            print("core memory: \(coreMemoryRecordID)")
        }
        if let auditRecordID = result.auditRecordID {
            print("audit log: \(auditRecordID)")
        }
        if !result.relatedRecordIDs.isEmpty {
            print("related records: \(result.relatedRecordIDs.joined(separator: ", "))")
        }
    }

    private func createCompatRecord(args: [String]) throws {
        guard !args.isEmpty else {
            throw CLIError.invalidArguments("Usage: boss create <title> [content]")
        }
        let title = args[0]
        let text = args.count > 1 ? args.dropFirst().joined(separator: " ") : ""
        let filename: String
        if title.contains(".") {
            filename = title
        } else {
            filename = "\(title).txt"
        }
        let id = try createTextRecord(filename: filename, text: text)
        print("Created record: \(id)")
    }

    private func listRecords(includeArchived: Bool, onlyArchived: Bool, limit: Int) throws {
        var sql = """
        SELECT id, filename, file_type, preview, created_at, updated_at, is_archived
        FROM records
        """
        if onlyArchived {
            sql += " WHERE is_archived = 1"
        } else if !includeArchived {
            sql += " WHERE is_archived = 0"
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"

        let rows = try db.query(sql, bindings: [.integer(Int64(limit))])
        print("Records (\(rows.count)):")
        print(String(repeating: "-", count: 72))

        for row in rows {
            let id = row["id"]?.stringValue ?? ""
            let filename = row["filename"]?.stringValue ?? ""
            let fileType = row["file_type"]?.stringValue ?? ""
            let archived = (row["is_archived"]?.intValue ?? 0) == 1 ? "[ARCHIVED] " : ""
            let updatedAt = formatDate(row["updated_at"]?.doubleValue)
            let preview = row["preview"]?.stringValue ?? ""

            print("\(archived)\(id)")
            print("  \(filename) [\(fileType)]")
            print("  updated: \(updatedAt)")
            if !preview.isEmpty {
                print("  preview: \(preview)")
            }
            print(String(repeating: "-", count: 72))
        }
    }

    private func showRecord(id: String) throws {
        let rows = try db.query("SELECT * FROM records WHERE id = ? LIMIT 1", bindings: [.text(id)])
        guard let row = rows.first else {
            throw CLIError.notFound("Record not found: \(id)")
        }

        print("ID: \(id)")
        print("Filename: \(row["filename"]?.stringValue ?? "")")
        print("Kind: \(row["kind"]?.stringValue ?? "")")
        print("File type: \(row["file_type"]?.stringValue ?? "")")
        print("Visibility: \(row["visibility"]?.stringValue ?? "")")
        print("Path: \(row["file_path"]?.stringValue ?? "")")
        print("Content type: \(row["content_type"]?.stringValue ?? "")")
        print("Size: \(row["size_bytes"]?.intValue ?? 0)")
        print("SHA256: \(row["sha256"]?.stringValue ?? "")")
        print("Created: \(formatDate(row["created_at"]?.doubleValue))")
        print("Updated: \(formatDate(row["updated_at"]?.doubleValue))")
        let fileType = row["file_type"]?.stringValue ?? ""
        if ["text", "web", "log"].contains(fileType) {
            let relativePath = row["file_path"]?.stringValue ?? ""
            let content = try readText(relativePath: relativePath, maxBytes: 2000)
            print("Content:\n\(content)")
        }
    }

    private func createTextRecord(filename: String, text: String, tags: [String] = []) throws -> String {
        let data = text.data(using: .utf8) ?? Data()
        return try createRecordFromData(data: data, filename: filename, textFallback: text, tags: tags)
    }

    private func importFileRecord(filePath: String, tags: [String] = []) throws -> String {
        let sourceURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.notFound("文件不存在: \(filePath)")
        }

        let data = try Data(contentsOf: sourceURL)
        return try createRecordFromData(
            data: data,
            filename: sourceURL.lastPathComponent,
            textFallback: String(data: data, encoding: .utf8),
            tags: tags
        )
    }

    private func createRecordFromData(data: Data, filename: String, textFallback: String?, tags: [String] = []) throws -> String {
        let id = UUID().uuidString
        let safeFilename = sanitizeFilename(filename)
        let relativePath = "records/\(id)/\(safeFilename)"
        let fileURL = storageURL.appendingPathComponent(relativePath)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)

        let contentType = detectContentType(filename: safeFilename)
        let fileType = detectFileType(contentType: contentType, filename: safeFilename)
        let textPreview: String
        if ["text", "web", "log"].contains(fileType) {
            textPreview = previewText(textFallback ?? String(decoding: data, as: UTF8.self), limit: 2000)
        } else {
            textPreview = ""
        }

        let preview: String
        let decodedText = textFallback ?? String(data: data, encoding: .utf8)
        if ["text", "web", "log"].contains(fileType), let decodedText {
            let normalized = previewText(decodedText, limit: 220)
            preview = normalized.isEmpty ? safeFilename : normalized
        } else {
            preview = safeFilename
        }

        let now = Date().timeIntervalSince1970
        let sha = sha256Hex(data)
        let kind = fileType == "text" ? "text" : "file"

        try db.execute(
            """
            INSERT INTO records (id, visibility, preview, kind, file_type, text_preview, file_path, filename, content_type, size_bytes, sha256, created_at, updated_at, is_pinned, is_archived)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
            """,
            bindings: [
                .text(id),
                .text("private"),
                .text(preview),
                .text(kind),
                .text(fileType),
                .text(textPreview),
                .text(relativePath),
                .text(safeFilename),
                .text(contentType),
                .integer(Int64(data.count)),
                .text(sha),
                .real(now),
                .real(now)
            ]
        )

        for tagID in tags where !tagID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try db.execute(
                "INSERT OR IGNORE INTO record_tags (record_id, tag_id) VALUES (?, ?)",
                bindings: [.text(id), .text(tagID)]
            )
        }

        return id
    }

    private func deleteRecord(id: String, printOutput: Bool = true) throws {
        let rows = try db.query("SELECT file_path FROM records WHERE id = ? LIMIT 1", bindings: [.text(id)])
        guard rows.first != nil else {
            throw CLIError.notFound("Record not found: \(id)")
        }

        try db.execute("DELETE FROM records WHERE id = ?", bindings: [.text(id)])

        let dir = storageURL.appendingPathComponent("records/\(id)")
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        if printOutput {
            print("Deleted record: \(id)")
        }
    }

    private func listTags() throws {
        let rows = try db.query("SELECT id, name, color, icon FROM tags ORDER BY name")
        print("Tags (\(rows.count)):")
        print(String(repeating: "-", count: 72))
        for row in rows {
            print("\(row["id"]?.stringValue ?? "") | \(row["name"]?.stringValue ?? "") | \(row["color"]?.stringValue ?? "") | \(row["icon"]?.stringValue ?? "")")
        }
    }

    private func listAgents() throws {
        let rows = try db.query(
            """
            SELECT id, name, is_enabled, trigger_json, action_json, next_run_at, last_run_at
            FROM agent_tasks
            ORDER BY created_at DESC
            """
        )

        let decoder = JSONDecoder()
        print("Agent Tasks (\(rows.count)):")
        print(String(repeating: "-", count: 92))
        for row in rows {
            let id = row["id"]?.stringValue ?? ""
            let name = row["name"]?.stringValue ?? ""
            let enabled = (row["is_enabled"]?.intValue ?? 0) == 1 ? "ON" : "OFF"
            let triggerRaw = row["trigger_json"]?.stringValue ?? "{}"
            let actionRaw = row["action_json"]?.stringValue ?? "{}"

            let triggerText: String
            if let data = triggerRaw.data(using: .utf8), let trigger = try? decoder.decode(AgentTrigger.self, from: data) {
                triggerText = describeTrigger(trigger)
            } else {
                triggerText = "unknown"
            }

            let actionText: String
            if let data = actionRaw.data(using: .utf8), let action = try? decoder.decode(AgentAction.self, from: data) {
                actionText = describeAction(action)
            } else {
                actionText = "unknown"
            }

            let nextRun = formatDate(row["next_run_at"]?.doubleValue)
            let lastRun = formatDate(row["last_run_at"]?.doubleValue)

            print("\(id) [\(enabled)]")
            print("  \(name)")
            print("  trigger: \(triggerText)")
            print("  action:  \(actionText)")
            print("  last: \(lastRun)  next: \(nextRun)")
            print(String(repeating: "-", count: 92))
        }
    }

    private func listAgentLogs(taskID: String, limit: Int) throws {
        let rows = try db.query(
            """
            SELECT started_at, finished_at, status, output, error
            FROM agent_run_logs
            WHERE task_id = ?
            ORDER BY started_at DESC
            LIMIT ?
            """,
            bindings: [.text(taskID), .integer(Int64(limit))]
        )

        print("Agent Logs (\(rows.count)) for \(taskID):")
        print(String(repeating: "-", count: 92))
        for row in rows {
            let started = formatDate(row["started_at"]?.doubleValue)
            let finished = formatDate(row["finished_at"]?.doubleValue)
            let status = row["status"]?.stringValue ?? ""
            let output = row["output"]?.stringValue ?? ""
            let error = row["error"]?.stringValue ?? ""
            print("[\(status)] \(started) -> \(finished)")
            if !output.isEmpty {
                print("  out: \(output.prefix(160))")
            }
            if !error.isEmpty {
                print("  err: \(error.prefix(160))")
            }
            print(String(repeating: "-", count: 92))
        }
    }

    private func runAgentTask(taskID: String) async throws -> String {
        let rows = try db.query(
            """
            SELECT id, name, trigger_json, action_json
            FROM agent_tasks
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(taskID)]
        )

        guard let row = rows.first,
              let id = row["id"]?.stringValue,
              let name = row["name"]?.stringValue,
              let triggerJSON = row["trigger_json"]?.stringValue,
              let actionJSON = row["action_json"]?.stringValue else {
            throw CLIError.notFound("Agent task not found: \(taskID)")
        }

        let decoder = JSONDecoder()
        guard let actionData = actionJSON.data(using: .utf8),
              let action = try? decoder.decode(AgentAction.self, from: actionData) else {
            throw CLIError.invalidData("无法解析任务动作: \(taskID)")
        }

        let trigger: AgentTrigger? = {
            guard let data = triggerJSON.data(using: .utf8) else { return nil }
            return try? decoder.decode(AgentTrigger.self, from: data)
        }()

        let logID = UUID().uuidString
        let startedAt = Date().timeIntervalSince1970
        try db.execute(
            """
            INSERT OR REPLACE INTO agent_run_logs (id, task_id, started_at, finished_at, status, output, error)
            VALUES (?, ?, ?, NULL, 'running', '', NULL)
            """,
            bindings: [.text(logID), .text(id), .real(startedAt)]
        )

        do {
            let output = try await executeAgentAction(action)
            let finishedAt = Date().timeIntervalSince1970
            try db.execute(
                """
                INSERT OR REPLACE INTO agent_run_logs (id, task_id, started_at, finished_at, status, output, error)
                VALUES (?, ?, ?, ?, 'success', ?, NULL)
                """,
                bindings: [.text(logID), .text(id), .real(startedAt), .real(finishedAt), .text(output)]
            )
            try updateTaskAfterRun(taskID: id, trigger: trigger)
            return "Task '\(name)' finished.\n\(output)"
        } catch {
            let finishedAt = Date().timeIntervalSince1970
            let message = error.localizedDescription
            try db.execute(
                """
                INSERT OR REPLACE INTO agent_run_logs (id, task_id, started_at, finished_at, status, output, error)
                VALUES (?, ?, ?, ?, 'failed', '', ?)
                """,
                bindings: [.text(logID), .text(id), .real(startedAt), .real(finishedAt), .text(message)]
            )
            try updateTaskAfterRun(taskID: id, trigger: trigger)
            throw error
        }
    }

    private struct CLIAssistantResult {
        let requestID: String
        let source: String
        let request: String
        let intent: String
        let plannerSource: String
        let plannerNote: String?
        let toolPlan: [String]
        let confirmationRequired: Bool
        let confirmationToken: String?
        let confirmationExpiresAt: Date?
        let reply: String
        let actions: [String]
        let relatedRecordIDs: [String]
        let coreContextRecordIDs: [String]
        let coreMemoryRecordID: String?
        let auditRecordID: String?
        let startedAt: Date
        let finishedAt: Date
        let succeeded: Bool
    }

    private struct CLIAssistantContextItem {
        let id: String
        let filename: String
        let snippet: String
        let updatedAt: Double
        let score: Int
    }

    private enum CLIAssistantIntent {
        case help
        case summarizeCore
        case search(String)
        case delete(String)
        case append(recordID: String, content: String)
        case replace(recordID: String, content: String)
        case unknown(String)

        var description: String {
            switch self {
            case .help: return "help"
            case .summarizeCore: return "summarizeCore"
            case .search(let query): return "search(\(query))"
            case .delete(let id): return "delete(\(id))"
            case .append(let id, _): return "append(\(id))"
            case .replace(let id, _): return "replace(\(id))"
            case .unknown(let text): return "unknown(\(text))"
            }
        }

        var requiresConfirmation: Bool {
            switch self {
            case .delete, .replace:
                return true
            default:
                return false
            }
        }

        var relatedRecordIDs: [String] {
            switch self {
            case .delete(let id):
                return [id]
            case .append(let id, _):
                return [id]
            case .replace(let id, _):
                return [id]
            default:
                return []
            }
        }
    }

    private struct CLIAssistantPlannedIntent {
        let intent: CLIAssistantIntent
        let plannerSource: String
        let plannerNote: String?
        let toolPlan: [String]
    }

    private struct CLIAssistantPendingIntent: Codable {
        let kind: String
        let query: String?
        let recordID: String?
        let content: String?
        let source: String
        let request: String
        let toolPlan: [String]
        let createdAt: Double
        let expiresAt: Double
    }

    private func runAssistantKernel(request: String, source: String) async throws -> CLIAssistantResult {
        let cleanedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID().uuidString
        let startedAt = Date()
        var actions: [String] = []
        var relatedRecordIDs: [String] = []
        var coreContextRecordIDs: [String] = []
        var coreMemoryRecordID: String?
        var auditRecordID: String?
        var intentDescription = "unknown"
        var plannerSource = "rule"
        var plannerNote: String?
        var toolPlan: [String] = []
        var confirmationRequired = false
        var confirmationToken: String?
        var confirmationExpiresAt: Date?
        var reply = ""
        var succeeded = false

        do {
            let coreTagID = try ensureTag(name: "Core", aliases: ["持久记忆", "core memory"], color: "#0A84FF", icon: "brain.head.profile")
            let auditTagID = try ensureTag(name: "AuditLog", aliases: ["audit", "audit log", "审计"], color: "#FF9F0A", icon: "doc.text.magnifyingglass")
            actions.append("tag.ensure:Core")
            actions.append("tag.ensure:AuditLog")

            let coreContext = try loadCoreContext(coreTagID: coreTagID, request: cleanedRequest, limit: 20)
            coreContextRecordIDs = coreContext.map { $0.id }
            actions.append("context.load:\(coreContext.count)")

            let confirmationAttempt = try consumePendingConfirmationIfProvided(request: cleanedRequest, source: source)
            if let token = confirmationAttempt.token, confirmationAttempt.intent == nil {
                intentDescription = "confirm.invalid(\(token))"
                plannerSource = "confirmation-token"
                plannerNote = "确认令牌无效、来源不匹配或已过期。"
                toolPlan = ["validate-confirmation-token"]
                reply = "确认令牌无效、来源不匹配或已过期。请重新发起删除/改写请求获取新的确认令牌。"
                actions.append("confirm.invalid:\(token)")
                succeeded = false
            } else {
                let confirmedIntent = confirmationAttempt.intent
                let intent: CLIAssistantIntent
                if let confirmedIntent {
                    intent = confirmedIntent
                    intentDescription = "\(confirmedIntent.description) [confirmed]"
                    plannerSource = "confirmation-token"
                    plannerNote = "已使用确认令牌执行高风险动作。"
                    toolPlan = defaultAssistantToolPlan(for: confirmedIntent)
                    if let token = confirmationAttempt.token {
                        actions.append("confirm.consume:\(token)")
                    }
                } else {
                    let planned = try await planAssistantIntent(cleanedRequest, coreContext: coreContext)
                    intent = planned.intent
                    intentDescription = planned.intent.description
                    plannerSource = planned.plannerSource
                    plannerNote = planned.plannerNote
                    toolPlan = planned.toolPlan
                    actions.append("plan:\(plannerSource)")
                }

                if intent.requiresConfirmation && confirmedIntent == nil {
                    let pending = try savePendingConfirmation(intent: intent, request: cleanedRequest, source: source, toolPlan: toolPlan)
                    confirmationRequired = true
                    confirmationToken = pending.token
                    confirmationExpiresAt = pending.expiresAt
                    relatedRecordIDs = intent.relatedRecordIDs
                    reply = buildAssistantConfirmationReply(intent: intent, token: pending.token, expiresAt: pending.expiresAt)
                    actions.append("confirm.required:\(pending.token)")
                    succeeded = true
                } else {
                    let output = try executeAssistantIntent(intent, request: cleanedRequest, coreContext: coreContext)
                    reply = output.reply
                    actions.append(contentsOf: output.actions)
                    relatedRecordIDs = output.relatedRecordIDs
                    succeeded = true
                }
            }

            let coreMemoryText = buildAssistantCoreMemoryText(
                requestID: requestID,
                source: source,
                request: cleanedRequest,
                intent: intentDescription,
                plannerSource: plannerSource,
                plannerNote: plannerNote,
                toolPlan: toolPlan,
                confirmationRequired: confirmationRequired,
                confirmationToken: confirmationToken,
                confirmationExpiresAt: confirmationExpiresAt,
                reply: reply,
                actions: actions,
                relatedRecordIDs: relatedRecordIDs,
                coreContextRecordIDs: coreContextRecordIDs
            )
            coreMemoryRecordID = try createTextRecord(
                filename: timestampFilename(prefix: "assistant-core"),
                text: coreMemoryText,
                tags: [coreTagID]
            )
            actions.append("memory.write:\(coreMemoryRecordID ?? "-")")

            let finishedAt = Date()
            let auditText = buildAssistantAuditText(
                requestID: requestID,
                source: source,
                request: cleanedRequest,
                intent: intentDescription,
                startedAt: startedAt,
                finishedAt: finishedAt,
                reply: reply,
                actions: actions,
                relatedRecordIDs: relatedRecordIDs,
                coreContextRecordIDs: coreContextRecordIDs,
                coreMemoryRecordID: coreMemoryRecordID,
                plannerSource: plannerSource,
                plannerNote: plannerNote,
                toolPlan: toolPlan,
                confirmationRequired: confirmationRequired,
                confirmationToken: confirmationToken,
                confirmationExpiresAt: confirmationExpiresAt
            )
            auditRecordID = try createTextRecord(
                filename: timestampFilename(prefix: "assistant-audit"),
                text: auditText,
                tags: [auditTagID]
            )
            actions.append("audit.write:\(auditRecordID ?? "-")")
        } catch {
            reply = "执行失败：\(error.localizedDescription)"
            actions.append("error:\(error.localizedDescription)")
            do {
                let auditTagID = try ensureTag(name: "AuditLog", aliases: ["audit", "audit log", "审计"], color: "#FF9F0A", icon: "doc.text.magnifyingglass")
                let failedAudit = buildAssistantAuditText(
                    requestID: requestID,
                    source: source,
                    request: cleanedRequest,
                    intent: intentDescription,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    reply: reply,
                    actions: actions,
                    relatedRecordIDs: relatedRecordIDs,
                    coreContextRecordIDs: coreContextRecordIDs,
                    coreMemoryRecordID: coreMemoryRecordID,
                    plannerSource: plannerSource,
                    plannerNote: plannerNote,
                    toolPlan: toolPlan,
                    confirmationRequired: confirmationRequired,
                    confirmationToken: confirmationToken,
                    confirmationExpiresAt: confirmationExpiresAt
                )
                auditRecordID = try? createTextRecord(
                    filename: timestampFilename(prefix: "assistant-audit-failed"),
                    text: failedAudit,
                    tags: [auditTagID]
                )
            } catch {
                // ignore audit failure
            }
        }

        return CLIAssistantResult(
            requestID: requestID,
            source: source,
            request: cleanedRequest,
            intent: intentDescription,
            plannerSource: plannerSource,
            plannerNote: plannerNote,
            toolPlan: toolPlan,
            confirmationRequired: confirmationRequired,
            confirmationToken: confirmationToken,
            confirmationExpiresAt: confirmationExpiresAt,
            reply: reply,
            actions: actions,
            relatedRecordIDs: relatedRecordIDs,
            coreContextRecordIDs: coreContextRecordIDs,
            coreMemoryRecordID: coreMemoryRecordID,
            auditRecordID: auditRecordID,
            startedAt: startedAt,
            finishedAt: Date(),
            succeeded: succeeded
        )
    }

    private struct CLIAssistantOutput {
        let reply: String
        let actions: [String]
        let relatedRecordIDs: [String]
    }

    private func defaultAssistantToolPlan(for intent: CLIAssistantIntent) -> [String] {
        switch intent {
        case .help:
            return ["explain-capabilities"]
        case .summarizeCore:
            return ["load-core-context", "summarize-core-context"]
        case .search:
            return ["search-records", "return-ranked-results"]
        case .delete:
            return ["load-target-record", "require-confirmation", "delete-record"]
        case .append:
            return ["load-target-record", "append-text", "update-preview"]
        case .replace:
            return ["load-target-record", "require-confirmation", "replace-text"]
        case .unknown:
            return ["fallback-search", "request-disambiguation"]
        }
    }

    private func planAssistantIntent(_ request: String, coreContext: [CLIAssistantContextItem]) async throws -> CLIAssistantPlannedIntent {
        var fallbackNote = "使用规则解析器（LLM 规划不可用或无结果）。"
        do {
            if let planned = try await planAssistantIntentWithLLM(request, coreContext: coreContext) {
                return planned
            }
        } catch {
            fallbackNote = "使用规则解析器（LLM 规划失败：\(error.localizedDescription)）"
        }

        let intent = parseAssistantIntent(request)
        return CLIAssistantPlannedIntent(
            intent: intent,
            plannerSource: "rule",
            plannerNote: fallbackNote,
            toolPlan: defaultAssistantToolPlan(for: intent)
        )
    }

    private func planAssistantIntentWithLLM(_ request: String, coreContext: [CLIAssistantContextItem]) async throws -> CLIAssistantPlannedIntent? {
        let modelIdentifier = normalizedAssistantPlannerModelIdentifier()
        let contextRows = coreContext.prefix(6).map { item in
            "[\(item.id)] \(item.filename): \(shortText(item.snippet, limit: 220))"
        }.joined(separator: "\n")

        let system = """
        你是 Boss 项目助理的 Planner。请把请求映射到内部动作意图，并且只输出 JSON。
        可用 intent: help, summarizeCore, search, delete, append, replace, unknown
        必须返回字段:
        - intent: string
        - query: string
        - record_id: string
        - content: string
        - tool_plan: string[] (按执行顺序给出简短步骤)
        - note: string
        如果信息不足，intent=unknown。
        """
        let userPrompt = """
        REQUEST:
        \(request)

        CORE_CONTEXT:
        \(contextRows.isEmpty ? "(none)" : contextRows)

        输出 JSON，不要附加 Markdown 代码块。
        """

        let raw = try await callLLM(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
        guard let payload = extractFirstJSONObject(from: raw),
              let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let rawIntent = (object["intent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query = (object["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = (object["record_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (object["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (object["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolPlan = (object["tool_plan"] as? [String] ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let intent: CLIAssistantIntent
        switch rawIntent {
        case "help":
            intent = .help
        case "summarizecore", "summarize_core":
            intent = .summarizeCore
        case "search":
            intent = .search(query.isEmpty ? extractSearchQuery(request) : query)
        case "delete":
            let resolvedID = recordID.isEmpty ? (extractRecordID(request) ?? "") : recordID
            guard !resolvedID.isEmpty else { return nil }
            intent = .delete(resolvedID.uppercased())
        case "append":
            let resolvedID = recordID.isEmpty ? (extractRecordID(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            guard !resolvedID.isEmpty, !resolvedContent.isEmpty else { return nil }
            intent = .append(recordID: resolvedID.uppercased(), content: resolvedContent)
        case "replace":
            let resolvedID = recordID.isEmpty ? (extractRecordID(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            guard !resolvedID.isEmpty, !resolvedContent.isEmpty else { return nil }
            intent = .replace(recordID: resolvedID.uppercased(), content: resolvedContent)
        case "unknown":
            intent = .unknown(request)
        default:
            return nil
        }

        return CLIAssistantPlannedIntent(
            intent: intent,
            plannerSource: "llm:\(modelIdentifier)",
            plannerNote: note.isEmpty ? nil : note,
            toolPlan: toolPlan.isEmpty ? defaultAssistantToolPlan(for: intent) : toolPlan
        )
    }

    private func normalizedAssistantPlannerModelIdentifier() -> String {
        let raw = appDefaults?.string(forKey: "claudeModel") ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "claude:claude-sonnet-4-6" }
        if value.contains(":") { return value }

        let lower = value.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return "openai:\(value)"
        }
        if lower.hasPrefix("qwen") {
            return "aliyun:\(value)"
        }
        return "claude:\(value)"
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        guard start <= end else { return nil }
        return String(text[start...end])
    }

    private func buildAssistantConfirmationReply(intent: CLIAssistantIntent, token: String, expiresAt: Date) -> String {
        let actionDescription: String
        switch intent {
        case .delete(let recordID):
            actionDescription = "删除记录 \(recordID)"
        case .replace(let recordID, _):
            actionDescription = "改写记录 \(recordID)"
        default:
            actionDescription = "执行高风险动作"
        }
        return """
        此操作需要二次确认：\(actionDescription)。
        请在 \(iso8601(expiresAt)) 前发送：#CONFIRM:\(token)
        或执行：boss assistant confirm \(token)
        """
    }

    private func extractAssistantConfirmationToken(_ text: String) -> String? {
        let pattern = "(?i)#confirm\\s*[:：]\\s*([A-Za-z0-9_-]{6,64})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[swiftRange]).uppercased()
    }

    private func generateAssistantConfirmationToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }

    private func consumePendingConfirmationIfProvided(request: String, source: String) throws -> (token: String?, intent: CLIAssistantIntent?) {
        guard let token = extractAssistantConfirmationToken(request) else {
            return (nil, nil)
        }
        try cleanupExpiredPendingConfirmations()

        let rows = try db.query(
            """
            SELECT payload, expires_at
            FROM assistant_pending_confirms
            WHERE token = ?
            LIMIT 1
            """,
            bindings: [.text(token)]
        )
        guard let row = rows.first,
              let payloadRaw = row["payload"]?.stringValue,
              let expiresAt = row["expires_at"]?.doubleValue
        else {
            return (token, nil)
        }

        if expiresAt <= Date().timeIntervalSince1970 {
            try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
            return (token, nil)
        }

        guard let payloadData = payloadRaw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CLIAssistantPendingIntent.self, from: payloadData)
        else {
            try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
            return (token, nil)
        }

        guard payload.source.isEmpty || payload.source == source else {
            return (token, nil)
        }

        try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
        return (token, assistantIntent(from: payload))
    }

    private func savePendingConfirmation(
        intent: CLIAssistantIntent,
        request: String,
        source: String,
        toolPlan: [String]
    ) throws -> (token: String, expiresAt: Date) {
        try cleanupExpiredPendingConfirmations()
        guard let payload = pendingPayload(from: intent, request: request, source: source, toolPlan: toolPlan) else {
            throw CLIError.invalidData("高风险动作确认数据构造失败")
        }
        let data = try JSONEncoder().encode(payload)
        guard let payloadString = String(data: data, encoding: .utf8) else {
            throw CLIError.invalidData("确认数据编码失败")
        }

        let token = generateAssistantConfirmationToken()
        let expiresAt = Date(timeIntervalSince1970: payload.expiresAt)
        try db.execute(
            """
            INSERT OR REPLACE INTO assistant_pending_confirms (token, payload, created_at, expires_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [.text(token), .text(payloadString), .real(payload.createdAt), .real(payload.expiresAt)]
        )
        return (token, expiresAt)
    }

    private func cleanupExpiredPendingConfirmations() throws {
        try db.execute(
            "DELETE FROM assistant_pending_confirms WHERE expires_at <= ?",
            bindings: [.real(Date().timeIntervalSince1970)]
        )
    }

    private func pendingPayload(
        from intent: CLIAssistantIntent,
        request: String,
        source: String,
        toolPlan: [String]
    ) -> CLIAssistantPendingIntent? {
        let now = Date().timeIntervalSince1970
        let expiresAt = now + 5 * 60
        switch intent {
        case .delete(let recordID):
            return CLIAssistantPendingIntent(
                kind: "delete",
                query: nil,
                recordID: recordID,
                content: nil,
                source: source,
                request: request,
                toolPlan: toolPlan,
                createdAt: now,
                expiresAt: expiresAt
            )
        case .replace(let recordID, let content):
            return CLIAssistantPendingIntent(
                kind: "replace",
                query: nil,
                recordID: recordID,
                content: content,
                source: source,
                request: request,
                toolPlan: toolPlan,
                createdAt: now,
                expiresAt: expiresAt
            )
        default:
            return nil
        }
    }

    private func assistantIntent(from payload: CLIAssistantPendingIntent) -> CLIAssistantIntent? {
        switch payload.kind.lowercased() {
        case "delete":
            guard let recordID = payload.recordID, !recordID.isEmpty else { return nil }
            return .delete(recordID)
        case "replace":
            guard let recordID = payload.recordID, !recordID.isEmpty, let content = payload.content, !content.isEmpty else {
                return nil
            }
            return .replace(recordID: recordID, content: content)
        default:
            return nil
        }
    }

    private func executeAssistantIntent(
        _ intent: CLIAssistantIntent,
        request: String,
        coreContext: [CLIAssistantContextItem]
    ) throws -> CLIAssistantOutput {
        switch intent {
        case .help:
            return CLIAssistantOutput(
                reply: """
                我支持这些操作：
                1. 搜索/检索：例如 “搜索 Swift 并发”
                2. 删除记录：例如 “删除记录 <record-id>”
                3. 追加文本：例如 “向 <record-id> 追加：<内容>”
                4. 改写文本：例如 “把 <record-id> 改写为：<内容>”
                5. 总结 Core：例如 “总结 Core 记忆”
                """,
                actions: ["assistant.help"],
                relatedRecordIDs: []
            )

        case .summarizeCore:
            if coreContext.isEmpty {
                return CLIAssistantOutput(
                    reply: "当前没有 Core 记忆内容可总结。",
                    actions: ["core.summarize:empty"],
                    relatedRecordIDs: []
                )
            }
            let rows = coreContext.prefix(8).map {
                "- [\($0.id)] \($0.filename): \(shortText($0.snippet, limit: 120))"
            }.joined(separator: "\n")
            return CLIAssistantOutput(
                reply: "Core 记忆回顾：\n\(rows)",
                actions: ["core.summarize:\(coreContext.count)"],
                relatedRecordIDs: coreContext.map { $0.id }
            )

        case .search(let query):
            let rows = try searchRecords(query: query, limit: 10)
            if rows.isEmpty {
                return CLIAssistantOutput(
                    reply: "没有检索到与“\(query)”相关的记录。",
                    actions: ["record.search:\(query):0"],
                    relatedRecordIDs: []
                )
            }
            let lines = rows.map {
                let id = $0["id"]?.stringValue ?? ""
                let filename = $0["filename"]?.stringValue ?? ""
                let preview = $0["preview"]?.stringValue ?? ""
                return "- [\(id)] \(filename): \(shortText(preview, limit: 90))"
            }.joined(separator: "\n")
            return CLIAssistantOutput(
                reply: "检索“\(query)”命中 \(rows.count) 条：\n\(lines)",
                actions: ["record.search:\(query):\(rows.count)"],
                relatedRecordIDs: rows.compactMap { $0["id"]?.stringValue }
            )

        case .delete(let recordID):
            try deleteRecord(id: recordID, printOutput: false)
            return CLIAssistantOutput(
                reply: "已删除记录：\(recordID)",
                actions: ["record.delete:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .append(let recordID, let content):
            let output = try appendToRecord(recordID: recordID, appendText: content)
            return CLIAssistantOutput(
                reply: output,
                actions: ["record.append:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .replace(let recordID, let content):
            let output = try replaceRecordText(recordID: recordID, text: content)
            return CLIAssistantOutput(
                reply: output,
                actions: ["record.replace:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .unknown(let query):
            let rows = try searchRecords(query: query, limit: 5)
            if rows.isEmpty {
                return CLIAssistantOutput(
                    reply: "我无法直接确认你的意图，且检索未命中。请提供明确动作（搜索/删除/追加/改写）和记录ID。",
                    actions: ["intent.unknown", "record.search.fallback:0"],
                    relatedRecordIDs: []
                )
            }
            let lines = rows.map {
                let id = $0["id"]?.stringValue ?? ""
                let filename = $0["filename"]?.stringValue ?? ""
                let preview = $0["preview"]?.stringValue ?? ""
                return "- [\(id)] \(filename): \(shortText(preview, limit: 90))"
            }.joined(separator: "\n")
            return CLIAssistantOutput(
                reply: "我先按检索理解你的需求，命中这些记录：\n\(lines)\n\n请继续给出动作（删除/追加/改写）与目标记录ID。",
                actions: ["intent.unknown", "record.search.fallback:\(rows.count)"],
                relatedRecordIDs: rows.compactMap { $0["id"]?.stringValue }
            )
        }
    }

    private func parseAssistantIntent(_ request: String) -> CLIAssistantIntent {
        let lower = request.lowercased()
        let recordID = extractRecordID(request)
        let payload = extractPayload(request)

        if lower.contains("help") || lower.contains("帮助") || lower.contains("你能做什么") {
            return .help
        }
        if lower.contains("总结") || lower.contains("回顾") || lower.contains("core memory") || lower.contains("持久记忆") {
            return .summarizeCore
        }
        if let recordID, lower.contains("删除") || lower.contains("delete") || lower.contains("移除") {
            return .delete(recordID)
        }
        if let recordID, !payload.isEmpty, (lower.contains("追加") || lower.contains("append") || lower.contains("补充")) {
            return .append(recordID: recordID, content: payload)
        }
        if let recordID, !payload.isEmpty, (lower.contains("改写") || lower.contains("replace") || lower.contains("rewrite") || lower.contains("编辑") || lower.contains("更新")) {
            return .replace(recordID: recordID, content: payload)
        }
        if lower.contains("搜索") || lower.contains("检索") || lower.contains("查找") || lower.contains("search") || lower.contains("find") {
            return .search(extractSearchQuery(request))
        }
        return .unknown(request)
    }

    private func ensureTag(name: String, aliases: [String], color: String, icon: String) throws -> String {
        let allRows = try db.query("SELECT id, name FROM tags")
        let names = Set(([name] + aliases).map { normalizeTagName($0) })
        if let existed = allRows.first(where: { row in
            let rowName = row["name"]?.stringValue ?? ""
            return names.contains(normalizeTagName(rowName))
        }), let existingID = existed["id"]?.stringValue, !existingID.isEmpty {
            return existingID
        }

        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try db.execute(
            """
            INSERT INTO tags (id, name, parent_id, color, icon, created_at, sort_order)
            VALUES (?, ?, NULL, ?, ?, ?, 0)
            """,
            bindings: [.text(id), .text(name), .text(color), .text(icon), .real(now)]
        )
        return id
    }

    private func loadCoreContext(coreTagID: String, request: String, limit: Int) throws -> [CLIAssistantContextItem] {
        let rows = try db.query(
            """
            SELECT r.id, r.filename, r.preview, r.file_type, r.file_path, r.updated_at
            FROM records r
            JOIN record_tags rt ON rt.record_id = r.id
            WHERE rt.tag_id = ? AND r.is_archived = 0
            ORDER BY r.updated_at DESC
            LIMIT 200
            """,
            bindings: [.text(coreTagID)]
        )
        let tokens = requestTokens(request)

        let items: [CLIAssistantContextItem] = rows.compactMap { row in
            let id = row["id"]?.stringValue ?? ""
            let filename = row["filename"]?.stringValue ?? ""
            let preview = row["preview"]?.stringValue ?? ""
            let fileType = row["file_type"]?.stringValue ?? ""
            let filePath = row["file_path"]?.stringValue ?? ""
            let updatedAt = row["updated_at"]?.doubleValue ?? 0

            let snippet: String
            if ["text", "web", "log"].contains(fileType) {
                snippet = (try? readText(relativePath: filePath, maxBytes: 120_000)) ?? preview
            } else {
                snippet = preview
            }

            return CLIAssistantContextItem(
                id: id,
                filename: filename,
                snippet: snippet,
                updatedAt: updatedAt,
                score: scoreText("\(filename) \(preview) \(snippet)", tokens: tokens)
            )
        }

        return items
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func searchRecords(query: String, limit: Int) throws -> [[String: SQLColumnValue]] {
        let ftsQuery = query.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
        return try db.query(
            """
            SELECT r.id, r.filename, r.preview
            FROM records r
            JOIN records_fts fts ON fts.id = r.id
            WHERE records_fts MATCH ? AND r.is_archived = 0
            ORDER BY rank
            LIMIT ?
            """,
            bindings: [.text(ftsQuery.isEmpty ? query : ftsQuery), .integer(Int64(limit))]
        )
    }

    private func replaceRecordText(recordID: String, text: String) throws -> String {
        let rows = try db.query(
            "SELECT file_path, file_type, filename FROM records WHERE id = ? LIMIT 1",
            bindings: [.text(recordID)]
        )
        guard let row = rows.first,
              let relativePath = row["file_path"]?.stringValue,
              let fileType = row["file_type"]?.stringValue,
              let filename = row["filename"]?.stringValue else {
            throw CLIError.notFound("Record not found: \(recordID)")
        }
        guard ["text", "web", "log"].contains(fileType) else {
            throw CLIError.invalidData("Record is not text-like: \(recordID)")
        }

        let data = text.data(using: .utf8) ?? Data()
        let fileURL = storageURL.appendingPathComponent(relativePath)
        try data.write(to: fileURL, options: .atomic)

        try db.execute(
            """
            UPDATE records SET preview = ?, text_preview = ?, size_bytes = ?, sha256 = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(previewText(text, limit: 220).isEmpty ? filename : previewText(text, limit: 220)),
                .text(previewText(text, limit: 2000)),
                .integer(Int64(data.count)),
                .text(sha256Hex(data)),
                .real(Date().timeIntervalSince1970),
                .text(recordID)
            ]
        )
        return "Replaced content of record: \(recordID)"
    }

    private func extractRecordID(_ text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange]).uppercased()
    }

    private func extractQuotedText(_ text: String) -> String? {
        let patterns = ["\"([^\"]+)\"", "“([^”]+)”", "「([^」]+)」"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func extractPayload(_ text: String) -> String {
        if let quoted = extractQuotedText(text) {
            return quoted
        }
        let separators = ["内容:", "content:", "text:", "为:", "->", "=>"]
        for separator in separators {
            if let range = text.range(of: separator, options: .caseInsensitive) {
                let rhs = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rhs.isEmpty { return rhs }
            }
        }
        if let colon = text.lastIndex(of: "：") ?? text.lastIndex(of: ":") {
            let rhs = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rhs.isEmpty { return rhs }
        }
        return ""
    }

    private func extractSearchQuery(_ text: String) -> String {
        if let quoted = extractQuotedText(text) {
            return quoted
        }
        let keywords = ["搜索", "检索", "查找", "search", "find"]
        var query = text
        for keyword in keywords {
            query = query.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
        }
        query = query.replacingOccurrences(of: "记录", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? text : query
    }

    private func requestTokens(_ text: String) -> [String] {
        let parts = text.lowercased().split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_")
        }
        let tokens = parts.map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return [text.lowercased()] }
        return Array(tokens.prefix(12))
    }

    private func scoreText(_ text: String, tokens: [String]) -> Int {
        let haystack = text.lowercased()
        return tokens.reduce(0) { partial, token in
            haystack.contains(token) ? partial + min(token.count, 8) : partial
        }
    }

    private func normalizeTagName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func buildAssistantCoreMemoryText(
        requestID: String,
        source: String,
        request: String,
        intent: String,
        plannerSource: String,
        plannerNote: String?,
        toolPlan: [String],
        confirmationRequired: Bool,
        confirmationToken: String?,
        confirmationExpiresAt: Date?,
        reply: String,
        actions: [String],
        relatedRecordIDs: [String],
        coreContextRecordIDs: [String]
    ) -> String {
        """
        # Core Memory Snapshot
        request_id: \(requestID)
        source: \(source)
        intent: \(intent)
        planner_source: \(plannerSource)
        planner_note: \(plannerNote ?? "-")
        confirmation_required: \(confirmationRequired ? "yes" : "no")
        confirmation_token: \(confirmationToken ?? "-")
        confirmation_expires_at: \(confirmationExpiresAt.map(iso8601) ?? "-")
        created_at: \(iso8601Now())

        ## Request
        \(request)

        ## Decision / Reply
        \(reply)

        ## Tool Plan
        \(toolPlan.isEmpty ? "- (none)" : toolPlan.map { "- \($0)" }.joined(separator: "\n"))

        ## Action Trace
        \(actions.isEmpty ? "- (none)" : actions.map { "- \($0)" }.joined(separator: "\n"))

        ## Related Records
        \(relatedRecordIDs.isEmpty ? "- (none)" : relatedRecordIDs.map { "- \($0)" }.joined(separator: "\n"))

        ## Core Context Used
        \(coreContextRecordIDs.isEmpty ? "- (none)" : coreContextRecordIDs.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func buildAssistantAuditText(
        requestID: String,
        source: String,
        request: String,
        intent: String,
        startedAt: Date,
        finishedAt: Date,
        reply: String,
        actions: [String],
        relatedRecordIDs: [String],
        coreContextRecordIDs: [String],
        coreMemoryRecordID: String?,
        plannerSource: String,
        plannerNote: String?,
        toolPlan: [String],
        confirmationRequired: Bool,
        confirmationToken: String?,
        confirmationExpiresAt: Date?
    ) -> String {
        """
        # Assistant Audit Log
        request_id: \(requestID)
        source: \(source)
        started_at: \(iso8601(startedAt))
        finished_at: \(iso8601(finishedAt))
        duration_ms: \(Int(finishedAt.timeIntervalSince(startedAt) * 1000))
        intent: \(intent)
        planner_source: \(plannerSource)
        planner_note: \(plannerNote ?? "-")
        confirmation_required: \(confirmationRequired ? "yes" : "no")
        confirmation_token: \(confirmationToken ?? "-")
        confirmation_expires_at: \(confirmationExpiresAt.map(iso8601) ?? "-")
        core_memory_record_id: \(coreMemoryRecordID ?? "-")

        ## Request
        \(request)

        ## Reply
        \(reply)

        ## Tool Plan
        \(toolPlan.isEmpty ? "- (none)" : toolPlan.map { "- \($0)" }.joined(separator: "\n"))

        ## Actions
        \(actions.isEmpty ? "- (none)" : actions.map { "- \($0)" }.joined(separator: "\n"))

        ## Related Records
        \(relatedRecordIDs.isEmpty ? "- (none)" : relatedRecordIDs.map { "- \($0)" }.joined(separator: "\n"))

        ## Core Context Records
        \(coreContextRecordIDs.isEmpty ? "- (none)" : coreContextRecordIDs.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func executeAgentAction(_ action: AgentAction) async throws -> String {
        switch action {
        case .shellCommand(let command):
            return try runShell(command)

        case .createRecord(let title, let contentTemplate):
            let filename = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "agent-log.txt"
                : sanitizeFilename("\(title).txt")
            let id = try createTextRecord(filename: filename, text: contentTemplate)
            return "Created record: \(id)"

        case .appendToRecord(let recordID, let contentTemplate):
            return try appendToRecord(recordID: recordID, appendText: contentTemplate)

        case .claudeAPI(let systemPrompt, let userPromptTemplate, let model):
            return try await callLLM(system: systemPrompt, userPrompt: userPromptTemplate, modelIdentifier: model)
        }
    }

    private func runShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw CLIError.invalidData("Shell command failed with code \(process.terminationStatus): \(output)")
        }
        return output
    }

    private func appendToRecord(recordID: String, appendText: String) throws -> String {
        let rows = try db.query(
            "SELECT file_path, file_type, filename FROM records WHERE id = ? LIMIT 1",
            bindings: [.text(recordID)]
        )
        guard let row = rows.first,
              let relativePath = row["file_path"]?.stringValue,
              let fileType = row["file_type"]?.stringValue,
              let filename = row["filename"]?.stringValue else {
            throw CLIError.notFound("Record not found: \(recordID)")
        }

        guard ["text", "web", "log"].contains(fileType) else {
            throw CLIError.invalidData("Record is not text-like: \(recordID)")
        }

        let fileURL = storageURL.appendingPathComponent(relativePath)
        let currentData = (try? Data(contentsOf: fileURL)) ?? Data()
        let currentText = String(data: currentData, encoding: .utf8) ?? String(decoding: currentData, as: UTF8.self)
        let separator = currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n---\n\n"
        let nextText = currentText + separator + appendText

        let nextData = nextText.data(using: .utf8) ?? Data()
        try nextData.write(to: fileURL, options: .atomic)

        let updatedAt = Date().timeIntervalSince1970
        let updatedPreview = previewText(nextText, limit: 220)
        let textPreview = previewText(nextText, limit: 2000)
        let sha = sha256Hex(nextData)

        try db.execute(
            """
            UPDATE records SET preview = ?, text_preview = ?, size_bytes = ?, sha256 = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(updatedPreview.isEmpty ? filename : updatedPreview),
                .text(textPreview),
                .integer(Int64(nextData.count)),
                .text(sha),
                .real(updatedAt),
                .text(recordID)
            ]
        )

        return "Appended to record: \(recordID)"
    }

    private func callLLM(system: String, userPrompt: String, modelIdentifier: String) async throws -> String {
        let resolved = parseModelIdentifier(modelIdentifier)
        switch resolved.provider {
        case .claude:
            return try await callClaude(system: system, userPrompt: userPrompt, model: resolved.model)
        case .openai:
            return try await callOpenAI(system: system, userPrompt: userPrompt, model: resolved.model)
        case .aliyun:
            return try await callAliyun(system: system, userPrompt: userPrompt, model: resolved.model)
        }
    }

    private func parseModelIdentifier(_ identifier: String) -> (provider: LLMProvider, model: String) {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return (.claude, "claude-sonnet-4-6")
        }

        if let index = value.firstIndex(of: ":"), index > value.startIndex, index < value.index(before: value.endIndex) {
            let providerRaw = String(value[..<index]).lowercased()
            let model = String(value[value.index(after: index)...])
            if let provider = LLMProvider(rawValue: providerRaw) {
                return (provider, model)
            }
        }

        let lower = value.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return (.openai, value)
        }
        if lower.hasPrefix("qwen") {
            return (.aliyun, value)
        }
        return (.claude, value)
    }

    private func callClaude(system: String, userPrompt: String, model: String) async throws -> String {
        guard let apiKey = apiKey(for: .claude), !apiKey.isEmpty else {
            throw CLIError.api("Missing Claude API key")
        }

        let data = try await sendJSONRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ],
            body: [
                "model": model,
                "system": system,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "max_tokens": 1000
            ]
        )

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw CLIError.api("Claude response invalid")
        }

        let texts = content.compactMap { $0["text"] as? String }
        guard !texts.isEmpty else {
            throw CLIError.api("Claude response missing text")
        }
        return texts.joined(separator: "\n")
    }

    private func callOpenAI(system: String, userPrompt: String, model: String) async throws -> String {
        guard let apiKey = apiKey(for: .openai), !apiKey.isEmpty else {
            throw CLIError.api("Missing OpenAI API key")
        }

        let data = try await sendJSONRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.3
            ]
        )

        return try parseOpenAICompatibleText(data)
    }

    private func callAliyun(system: String, userPrompt: String, model: String) async throws -> String {
        guard let apiKey = apiKey(for: .aliyun), !apiKey.isEmpty else {
            throw CLIError.api("Missing 阿里云 DashScope API key")
        }

        let data = try await sendJSONRequest(
            url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.3
            ]
        )

        return try parseOpenAICompatibleText(data)
    }

    private func sendJSONRequest(url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CLIError.api(bodyText)
        }
        return data
    }

    private func parseOpenAICompatibleText(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw CLIError.api("OpenAI-compatible response invalid")
        }

        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }
        throw CLIError.api("OpenAI-compatible response missing text")
    }

    private func apiKey(for provider: LLMProvider) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .claude:
            return env["BOSS_CLAUDE_API_KEY"] ?? env["CLAUDE_API_KEY"] ?? appDefaults?.string(forKey: "claudeAPIKey")
        case .openai:
            return env["BOSS_OPENAI_API_KEY"] ?? env["OPENAI_API_KEY"] ?? appDefaults?.string(forKey: "openAIAPIKey")
        case .aliyun:
            return env["BOSS_ALIYUN_API_KEY"] ?? env["DASHSCOPE_API_KEY"] ?? appDefaults?.string(forKey: "aliyunAPIKey")
        }
    }

    private func updateTaskAfterRun(taskID: String, trigger: AgentTrigger?) throws {
        let now = Date()
        let lastRun = now.timeIntervalSince1970
        let nextRun: Double?

        if case .cron(let expression) = trigger {
            nextRun = CronParser.nextDate(expression: expression, after: now)?.timeIntervalSince1970
        } else {
            nextRun = nil
        }

        try db.execute(
            "UPDATE agent_tasks SET last_run_at = ?, next_run_at = ? WHERE id = ?",
            bindings: [
                .real(lastRun),
                nextRun.map(SQLBinding.real) ?? .null,
                .text(taskID)
            ]
        )
    }

    private func describeTrigger(_ trigger: AgentTrigger) -> String {
        switch trigger {
        case .manual:
            return "manual"
        case .cron(let expression):
            return "cron(\(expression))"
        case .onRecordCreate(let tagFilter):
            return "onRecordCreate tags=\(tagFilter)"
        case .onRecordUpdate(let tagFilter):
            return "onRecordUpdate tags=\(tagFilter)"
        }
    }

    private func describeAction(_ action: AgentAction) -> String {
        switch action {
        case .shellCommand(let command):
            return "shell: \(command.prefix(40))"
        case .createRecord(let title, _):
            return "createRecord: \(title)"
        case .appendToRecord(let recordID, _):
            return "appendToRecord: \(recordID)"
        case .claudeAPI(_, _, let model):
            return "llm: \(model)"
        }
    }

    private func ensureStorageDirectories() throws {
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

    private func prepareSchemaIfNeeded() throws {
        if try tableExists("records") {
            let hasFilePath = try recordsTableHasColumn("file_path")
            let hasFileType = try recordsTableHasColumn("file_type")
            if !hasFilePath || !hasFileType {
                try migrateLegacyRecordSchema()
                try bootstrapSchema()
                return
            }

            let requiredTables = ["tags", "record_tags", "agent_tasks", "agent_run_logs", "records_fts", "assistant_pending_confirms"]
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

    private func tableExists(_ name: String) throws -> Bool {
        let rows = try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            bindings: [.text(name)]
        )
        return !rows.isEmpty
    }

    private func recordsTableHasColumn(_ column: String) throws -> Bool {
        let rows = try db.query("PRAGMA table_info(records)")
        for row in rows {
            if row["name"]?.stringValue == column {
                return true
            }
        }
        return false
    }

    private func migrateLegacyRecordSchema() throws {
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

    private func bootstrapSchema() throws {
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
            CREATE TABLE IF NOT EXISTS agent_tasks (
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
            CREATE TABLE IF NOT EXISTS agent_run_logs (
                id          TEXT PRIMARY KEY,
                task_id     TEXT NOT NULL,
                started_at  REAL NOT NULL,
                finished_at REAL,
                status      TEXT NOT NULL DEFAULT 'running',
                output      TEXT NOT NULL DEFAULT '',
                error       TEXT,
                FOREIGN KEY (task_id) REFERENCES agent_tasks(id) ON DELETE CASCADE
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
            "CREATE INDEX IF NOT EXISTS idx_agent_tasks_next_run ON agent_tasks(next_run_at);",
            "CREATE INDEX IF NOT EXISTS idx_assistant_pending_expires_at ON assistant_pending_confirms(expires_at);"
        ]

        for statement in statements {
            try db.execute(statement)
        }
    }

    private static func extractGlobalOptions(from rawArgs: [String]) -> (storagePath: String?, remaining: [String]) {
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

    private static func resolveStoragePath(storageArg: String?) -> URL {
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

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let clean = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "file" : clean
    }

    private func detectContentType(filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func detectFileType(contentType: String, filename: String) -> String {
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

    private func previewText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "…"
    }

    private func shortText(_ text: String, limit: Int) -> String {
        previewText(text, limit: limit)
    }

    private func readText(relativePath: String, maxBytes: Int) throws -> String {
        let url = storageURL.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
        return String(data: clipped, encoding: .utf8) ?? String(decoding: clipped, as: UTF8.self)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func formatDate(_ timestamp: Double?) -> String {
        guard let timestamp else { return "-" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .standard)
    }

    private func timestampFilename(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date())).txt"
    }

    private func iso8601Now() -> String {
        iso8601(Date())
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var recordUsage: String {
        """
Record commands:
    boss record list [--all] [--archived] [--limit N]
    boss record create <filename> [text]
    boss record import <file-path>
    boss record show <record-id>
    boss record delete <record-id>
"""
    }

    private var agentUsage: String {
        """
Agent commands:
    boss agent list
    boss agent logs <task-id> [--limit N]
    boss agent run <task-id>
"""
    }

    private var assistantUsage: String {
        """
Assistant commands:
    boss assistant ask <request> [--source <source>] [--json]
    boss assistant confirm <token> [--source <source>] [--json]
"""
    }

    private var usage: String {
        """
Boss CLI

Usage:
    boss [--storage <path>] help
    boss [--storage <path>] record <subcommand>
    boss [--storage <path>] agent <subcommand>
    boss [--storage <path>] assistant <subcommand>

Legacy aliases:
    boss list
    boss create <title> [content]
    boss delete <record-id>
    boss tags

Global options:
    --storage, -s   Override storage directory (default follows app config)
    BOSS_STORAGE_PATH env var is also supported.

\(recordUsage)
\(agentUsage)
\(assistantUsage)
"""
    }
}

struct CronParser {
    static func nextDate(expression: String, after date: Date) -> Date? {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }

        let calendar = Calendar.current
        var current = calendar.date(byAdding: .minute, value: 1, to: date) ?? date

        for _ in 0..<1000 {
            if matches(expression: expression, date: current) {
                return current
            }
            current = calendar.date(byAdding: .minute, value: 1, to: current) ?? current
        }
        return nil
    }

    private static func matches(expression: String, date: Date) -> Bool {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return false }

        let calendar = Calendar.current
        let values = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        let weekday = values.weekday ?? 1

        return matchesField(parts[0], value: values.minute ?? 0, min: 0, max: 59)
            && matchesField(parts[1], value: values.hour ?? 0, min: 0, max: 23)
            && matchesField(parts[2], value: values.day ?? 1, min: 1, max: 31)
            && matchesField(parts[3], value: values.month ?? 1, min: 1, max: 12)
            && matchesField(parts[4], value: weekday == 1 ? 7 : weekday - 1, min: 1, max: 7)
    }

    private static func matchesField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        if field == "*" {
            return true
        }

        if field.contains(",") {
            let items = field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return items.contains { matchesSingleField($0, value: value, min: min, max: max) }
        }

        return matchesSingleField(field, value: value, min: min, max: max)
    }

    private static func matchesSingleField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        if field == "*" {
            return true
        }

        if field.contains("/") {
            let parts = field.split(separator: "/")
            guard parts.count == 2, let step = Int(parts[1]), step > 0 else { return false }
            let base = String(parts[0])

            if base == "*" {
                return value % step == 0
            }

            if base.contains("-") {
                let range = base.split(separator: "-")
                guard range.count == 2,
                      let start = Int(range[0]),
                      let end = Int(range[1]),
                      start <= end,
                      (min...max).contains(start),
                      (min...max).contains(end) else { return false }
                guard value >= start && value <= end else { return false }
                return (value - start) % step == 0
            }

            return false
        }

        if field.contains("-") {
            let range = field.split(separator: "-")
            guard range.count == 2,
                  let start = Int(range[0]),
                  let end = Int(range[1]),
                  start <= end,
                  (min...max).contains(start),
                  (min...max).contains(end) else { return false }
            return value >= start && value <= end
        }

        guard let exact = Int(field), (min...max).contains(exact) else {
            return false
        }
        return value == exact
    }
}

@main
struct BossCLIApp {
    static func main() async {
        do {
            let cli = BossCLI(arguments: CommandLine.arguments)
            try await cli.run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fputs("Error: \(message)\n", stderr)
            exit(1)
        }
    }
}
