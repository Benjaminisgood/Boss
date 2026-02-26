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
    let path: String

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

    func withConnection<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CLIError.sqliteOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5000)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        return try body(db)
    }

    func bind(_ values: [SQLBinding], to statement: OpaquePointer?) throws {
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

enum TaskTrigger: Codable {
    case manual
    case cron(expression: String)
    case onRecordCreate(tagFilter: [String])
    case onRecordUpdate(tagFilter: [String])
}

enum TaskAction: Codable {
    case createRecord(title: String, contentTemplate: String)
    case appendToRecord(recordID: String, contentTemplate: String)
    case shellCommand(command: String)
    case claudeAPI(systemPrompt: String, userPromptTemplate: String, model: String)
}

enum CLISkillAction: Codable {
    case llmPrompt(systemPrompt: String, userPromptTemplate: String, model: String)
    case shellCommand(command: String)
    case createRecord(filenameTemplate: String, contentTemplate: String)
    case appendToRecord(recordRef: String, contentTemplate: String)
}

enum LLMProvider: String {
    case claude
    case openai
    case aliyun
}

final class BossCLI {
    let args: [String]
    let appDefaults = UserDefaults(suiteName: "com.boss.app")
    let storageURL: URL
    let db: SQLiteDB

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

        case "task":
            try await runTaskCommand(args: Array(commandArgs.dropFirst()))

        case "assistant":
            try await runAssistant(args: Array(commandArgs.dropFirst()))

        case "skills":
            try await runSkills(args: Array(commandArgs.dropFirst()))

        case "skill":
            try await runSkill(args: Array(commandArgs.dropFirst()))

        case "commands", "catalog":
            try runCommandsCatalog(args: Array(commandArgs.dropFirst()))

        case "interface":
            try await runInterface(args: Array(commandArgs.dropFirst()))

        default:
            throw CLIError.invalidArguments("Unknown command: \(command)\n\n\(usage)")
        }
    }

    func runRecord(args: [String]) async throws {
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

        case "search":
            var limit = 10
            var outputJSON = false
            var queryTokens: [String] = []
            var index = 1
            while index < args.count {
                let token = args[index]
                switch token {
                case "--limit":
                    guard index + 1 < args.count, let parsed = Int(args[index + 1]), parsed > 0 else {
                        throw CLIError.invalidArguments("--limit 需要正整数")
                    }
                    limit = parsed
                    index += 1
                case "--json":
                    outputJSON = true
                default:
                    queryTokens.append(token)
                }
                index += 1
            }

            let query = queryTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw CLIError.invalidArguments("Usage: boss record search <query> [--limit N] [--json]")
            }

            let rows = try searchRecords(query: query, limit: limit)
            let records: [[String: Any]] = rows.map { row in
                [
                    "id": row["id"].map { $0.stringValue ?? "" } ?? "",
                    "filename": row["filename"].map { $0.stringValue ?? "" } ?? "",
                    "preview": row["preview"].map { $0.stringValue ?? "" } ?? "",
                    "updated_at": row["updated_at"].map { $0.doubleValue ?? 0 } ?? 0
                ]
            }

            if outputJSON {
                let payload: [String: Any] = [
                    "query": query,
                    "limit": limit,
                    "records": records
                ]
                try printJSONObject(payload)
            } else {
                print("Search results (\(records.count)):")
                print(String(repeating: "-", count: 92))
                for record in records {
                    print("\(record["id"] ?? "")  \(record["filename"] ?? "")")
                    let preview = (record["preview"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    if !preview.isEmpty {
                        print("  \(preview)")
                    }
                    print(String(repeating: "-", count: 92))
                }
            }

        case "create", "create-text":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss record create <filename> [text]")
            }
            let filename = args[1]
            let text = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : ""
            let id = try createTextRecord(filename: filename, text: text)
            print("Created record: \(id)")

        case "append":
            guard args.count >= 3 else {
                throw CLIError.invalidArguments("Usage: boss record append <record-id> <text> [--json]")
            }
            let recordRef = args[1]
            var outputJSON = false
            let text = args.dropFirst(2).filter { token in
                if token == "--json" {
                    outputJSON = true
                    return false
                }
                return true
            }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CLIError.invalidArguments("record append 需要非空文本")
            }
            let request = "record.append \(recordRef)"
            let resolvedID = try resolveRecordReference(recordRef, for: .append, request: request, createIfMissingContent: text)
            let message = try appendToRecord(recordID: resolvedID, appendText: text)
            if outputJSON {
                let payload: [String: Any] = [
                    "record_id": resolvedID,
                    "updated": true,
                    "message": message
                ]
                try printJSONObject(payload)
            } else {
                print(message)
            }

        case "replace":
            guard args.count >= 3 else {
                throw CLIError.invalidArguments("Usage: boss record replace <record-id> <text> [--json]")
            }
            let recordRef = args[1]
            var outputJSON = false
            let text = args.dropFirst(2).filter { token in
                if token == "--json" {
                    outputJSON = true
                    return false
                }
                return true
            }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CLIError.invalidArguments("record replace 需要非空文本")
            }
            let request = "record.replace \(recordRef)"
            let resolvedID = try resolveRecordReference(recordRef, for: .replace, request: request)
            let message = try replaceRecordText(recordID: resolvedID, text: text)
            if outputJSON {
                let payload: [String: Any] = [
                    "record_id": resolvedID,
                    "updated": true,
                    "message": message
                ]
                try printJSONObject(payload)
            } else {
                print(message)
            }

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

    func runTaskCommand(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(taskUsage)
        }

        switch sub {
        case "list":
            try listTasks()

        case "logs":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss task logs <task-id> [--limit N]")
            }
            var limit = 30
            if args.count >= 4, args[2] == "--limit" {
                guard let parsed = Int(args[3]), parsed > 0 else {
                    throw CLIError.invalidArguments("--limit 需要正整数")
                }
                limit = parsed
            }
            try listTaskLogs(taskID: args[1], limit: limit)

        case "run":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss task run <task-id>")
            }
            let result = try await runTaskNow(taskID: args[1])
            print(result)

        default:
            throw CLIError.invalidArguments("Unknown task subcommand: \(sub)\n\n\(taskUsage)")
        }
    }

    func runAssistant(args: [String]) async throws {
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

    func runSkills(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(skillsUsage)
        }

        switch sub {
        case "list":
            try listSkills()

        case "manifest", "catalog":
            let outputJSON = args.contains("--json")
            let text = try loadSkillManifestText(refreshIfMissing: true)
            if outputJSON {
                var payload: [String: Any] = [
                    "generated_at": iso8601Now(),
                    "manifest": text
                ]
                if sub == "catalog" {
                    payload["manifest_markdown"] = text
                }
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else {
                print(text)
            }

        case "refresh-manifest":
            let recordID = try refreshSkillManifestRecord()
            print("Skill manifest refreshed: \(recordID)")

        default:
            throw CLIError.invalidArguments("Unknown skills subcommand: \(sub)\n\n\(skillsUsage)")
        }
    }

    func printJSONObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    func runSkill(args: [String]) async throws {
        guard let sub = args.first else {
            throw CLIError.invalidArguments(skillUsage)
        }

        switch sub {
        case "run":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: boss skill run <skill-ref> [input] [--source <source>] [--json]")
            }

            let skillRef = args[1]
            var outputJSON = false
            var source = "runtime"
            var inputTokens: [String] = []
            var index = 2
            while index < args.count {
                let token = args[index]
                if token == "--json" {
                    outputJSON = true
                    index += 1
                    continue
                }
                if token == "--source" {
                    guard index + 1 < args.count else {
                        throw CLIError.invalidArguments("--source 需要一个值")
                    }
                    source = args[index + 1]
                    index += 2
                    continue
                }
                inputTokens.append(token)
                index += 1
            }

            let input = inputTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let skill = try resolveSkillMetadata(skillRef: skillRef)
            if !skill.isEnabled {
                if outputJSON {
                    try printJSONObject([
                        "status": "disabled",
                        "skill_id": skill.id,
                        "skill_name": skill.name,
                        "actions": ["skill.run:\(skill.id):disabled"],
                        "related_record_ids": []
                    ])
                } else {
                    print("Skill disabled: \(skill.name) (\(skill.id))")
                }
                return
            }

            let request = input.isEmpty ? "skill.run \(skillRef) from \(source)" : input
            let result = try await executeCLISkill(skill: skill, input: request, request: request)
            if outputJSON {
                try printJSONObject([
                    "status": "success",
                    "skill_id": skill.id,
                    "skill_name": skill.name,
                    "actions": result.actions,
                    "related_record_ids": result.relatedRecordIDs,
                    "output": result.reply
                ])
            } else {
                print(result.reply)
            }

        default:
            throw CLIError.invalidArguments("Unknown skill subcommand: \(sub)\n\n\(skillUsage)")
        }
    }

    func printAssistantResult(_ result: CLIAssistantResult, outputJSON: Bool) throws {
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


}
