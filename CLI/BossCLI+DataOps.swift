import Foundation
import SQLite3

extension BossCLI {
    func listRecords(includeArchived: Bool, onlyArchived: Bool, limit: Int) throws {
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

    func showRecord(id: String) throws {
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

    func createTextRecord(filename: String, text: String, tags: [String] = []) throws -> String {
        let data = text.data(using: .utf8) ?? Data()
        return try createRecordFromData(data: data, filename: filename, textFallback: text, tags: tags)
    }

    func importFileRecord(filePath: String, tags: [String] = []) throws -> String {
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

    func createRecordFromData(data: Data, filename: String, textFallback: String?, tags: [String] = []) throws -> String {
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

    func deleteRecord(id: String, printOutput: Bool = true) throws {
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

    func listTags() throws {
        let rows = try db.query("SELECT id, name, color, icon FROM tags ORDER BY name")
        print("Tags (\(rows.count)):")
        print(String(repeating: "-", count: 72))
        for row in rows {
            print("\(row["id"]?.stringValue ?? "") | \(row["name"]?.stringValue ?? "") | \(row["color"]?.stringValue ?? "") | \(row["icon"]?.stringValue ?? "")")
        }
    }

    func listTasks() throws {
        let rows = try db.query(
            """
            SELECT id, name, is_enabled, trigger_json, action_json, next_run_at, last_run_at
            FROM tasks
            ORDER BY created_at DESC
            """
        )

        let decoder = JSONDecoder()
        print("Task Items (\(rows.count)):")
        print(String(repeating: "-", count: 92))
        for row in rows {
            let id = row["id"]?.stringValue ?? ""
            let name = row["name"]?.stringValue ?? ""
            let enabled = (row["is_enabled"]?.intValue ?? 0) == 1 ? "ON" : "OFF"
            let triggerRaw = row["trigger_json"]?.stringValue ?? "{}"
            let actionRaw = row["action_json"]?.stringValue ?? "{}"

            let triggerText: String
            if let data = triggerRaw.data(using: .utf8), let trigger = try? decoder.decode(TaskTrigger.self, from: data) {
                triggerText = describeTrigger(trigger)
            } else {
                triggerText = "unknown"
            }

            let actionText: String
            if let data = actionRaw.data(using: .utf8), let action = try? decoder.decode(TaskAction.self, from: data) {
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

    func listSkills() throws {
        let rows = try db.query(
            """
            SELECT id, name, description, trigger_hint, action_json, is_enabled, updated_at
            FROM assistant_skills
            ORDER BY created_at DESC
            """
        )
        let decoder = JSONDecoder()

        print("Skills (\(rows.count)):")
        print(String(repeating: "-", count: 92))
        for row in rows {
            let id = row["id"]?.stringValue ?? ""
            let name = row["name"]?.stringValue ?? ""
            let enabled = (row["is_enabled"]?.intValue ?? 0) == 1 ? "ON" : "OFF"
            let triggerHint = row["trigger_hint"]?.stringValue ?? ""
            let description = row["description"]?.stringValue ?? ""
            let actionRaw = row["action_json"]?.stringValue ?? "{}"

            let actionText: String
            if let data = actionRaw.data(using: .utf8),
               let action = try? decoder.decode(CLISkillAction.self, from: data) {
                actionText = describeSkillAction(action)
            } else {
                actionText = "unknown"
            }

            let updatedAt = formatDate(row["updated_at"]?.doubleValue)

            print("\(id) [\(enabled)]")
            print("  \(name)")
            if !triggerHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("  trigger: \(triggerHint)")
            }
            if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("  desc: \(shortText(description, limit: 120))")
            }
            print("  action: \(actionText)")
            print("  updated: \(updatedAt)")
            print(String(repeating: "-", count: 92))
        }
    }

    func listTaskLogs(taskID: String, limit: Int) throws {
        let rows = try db.query(
            """
            SELECT started_at, finished_at, status, output, error
            FROM task_run_logs
            WHERE task_id = ?
            ORDER BY started_at DESC
            LIMIT ?
            """,
            bindings: [.text(taskID), .integer(Int64(limit))]
        )

        print("Task Logs (\(rows.count)) for \(taskID):")
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

    func runTaskNow(taskID: String) async throws -> String {
        let rows = try db.query(
            """
            SELECT id, name, trigger_json, action_json
            FROM tasks
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
            throw CLIError.notFound("Task not found: \(taskID)")
        }

        let decoder = JSONDecoder()
        guard let actionData = actionJSON.data(using: .utf8),
              let action = try? decoder.decode(TaskAction.self, from: actionData) else {
            throw CLIError.invalidData("无法解析任务动作: \(taskID)")
        }

        let trigger: TaskTrigger? = {
            guard let data = triggerJSON.data(using: .utf8) else { return nil }
            return try? decoder.decode(TaskTrigger.self, from: data)
        }()

        let logID = UUID().uuidString
        let startedAt = Date().timeIntervalSince1970
        try db.execute(
            """
            INSERT OR REPLACE INTO task_run_logs (id, task_id, started_at, finished_at, status, output, error)
            VALUES (?, ?, ?, NULL, 'running', '', NULL)
            """,
            bindings: [.text(logID), .text(id), .real(startedAt)]
        )

        do {
            let output = try await executeTaskAction(action)
            let finishedAt = Date().timeIntervalSince1970
            try db.execute(
                """
                INSERT OR REPLACE INTO task_run_logs (id, task_id, started_at, finished_at, status, output, error)
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
                INSERT OR REPLACE INTO task_run_logs (id, task_id, started_at, finished_at, status, output, error)
                VALUES (?, ?, ?, ?, 'failed', '', ?)
                """,
                bindings: [.text(logID), .text(id), .real(startedAt), .real(finishedAt), .text(message)]
            )
            try updateTaskAfterRun(taskID: id, trigger: trigger)
            throw error
        }
    }

}
