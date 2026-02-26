import Foundation
import SQLite3

extension BossCLI {
    func executeTaskAction(_ action: TaskAction) async throws -> String {
        switch action {
        case .shellCommand(let command):
            return try runShell(command)

        case .createRecord(let title, let contentTemplate):
            let filename = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "task-log.txt"
                : sanitizeFilename("\(title).txt")
            let id = try createTextRecord(filename: filename, text: contentTemplate)
            return "Created record: \(id)"

        case .appendToRecord(let recordID, let contentTemplate):
            return try appendToRecord(recordID: recordID, appendText: contentTemplate)

        case .claudeAPI(let systemPrompt, let userPromptTemplate, let model):
            return try await callLLM(system: systemPrompt, userPrompt: userPromptTemplate, modelIdentifier: model)
        }
    }

    func runShell(_ command: String) throws -> String {
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

    func appendToRecord(recordID: String, appendText: String) throws -> String {
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

    func callLLM(system: String, userPrompt: String, modelIdentifier: String) async throws -> String {
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

    func parseModelIdentifier(_ identifier: String) -> (provider: LLMProvider, model: String) {
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

    func callClaude(system: String, userPrompt: String, model: String) async throws -> String {
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

    func callOpenAI(system: String, userPrompt: String, model: String) async throws -> String {
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

    func callAliyun(system: String, userPrompt: String, model: String) async throws -> String {
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

    func sendJSONRequest(url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
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

    func parseOpenAICompatibleText(_ data: Data) throws -> String {
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

    func apiKey(for provider: LLMProvider) -> String? {
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

    func updateTaskAfterRun(taskID: String, trigger: TaskTrigger?) throws {
        let now = Date()
        let lastRun = now.timeIntervalSince1970
        let nextRun: Double?

        if case .cron(let expression) = trigger {
            nextRun = CronParser.nextDate(expression: expression, after: now)?.timeIntervalSince1970
        } else {
            nextRun = nil
        }

        try db.execute(
            "UPDATE tasks SET last_run_at = ?, next_run_at = ? WHERE id = ?",
            bindings: [
                .real(lastRun),
                nextRun.map(SQLBinding.real) ?? .null,
                .text(taskID)
            ]
        )
    }

    func describeTrigger(_ trigger: TaskTrigger) -> String {
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

    func describeAction(_ action: TaskAction) -> String {
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

    func describeSkillAction(_ action: CLISkillAction) -> String {
        switch action {
        case .llmPrompt(_, _, let model):
            return "llmPrompt(model=\(model))"
        case .shellCommand(let command):
            return "shellCommand(\(command.prefix(48)))"
        case .createRecord(let filenameTemplate, _):
            return "createRecord(filenameTemplate=\(filenameTemplate))"
        case .appendToRecord(let recordRef, _):
            return "appendToRecord(recordRef=\(recordRef))"
        }
    }

}
