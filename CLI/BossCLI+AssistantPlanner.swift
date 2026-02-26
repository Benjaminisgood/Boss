import Foundation
import SQLite3

extension BossCLI {
    func planAssistantToolCalls(_ request: String, coreContext: [CLIAssistantContextItem]) async throws -> CLIAssistantPlannedToolCalls {
        var fallbackNote = "使用规则解析器（LLM 规划不可用或无结果）。"
        do {
            if let planned = try await planAssistantToolCallsWithLLM(request, coreContext: coreContext) {
                return planned
            }
        } catch {
            fallbackNote = "使用规则解析器（LLM 规划失败：\(error.localizedDescription)）"
        }

        if let clarify = minimalAssistantClarifyQuestion(for: request) {
            return CLIAssistantPlannedToolCalls(
                calls: [],
                plannerSource: "rule",
                plannerNote: fallbackNote,
                toolPlan: ["ask-minimal-clarify-question"],
                clarifyQuestion: clarify
            )
        }

        let intent = parseAssistantIntent(request)
        let calls = assistantToolCalls(for: intent, request: request)
        return CLIAssistantPlannedToolCalls(
            calls: calls,
            plannerSource: "rule",
            plannerNote: fallbackNote,
            toolPlan: defaultAssistantToolPlan(for: calls),
            clarifyQuestion: nil
        )
    }

    func planAssistantToolCallsWithLLM(_ request: String, coreContext: [CLIAssistantContextItem]) async throws -> CLIAssistantPlannedToolCalls? {
        let modelIdentifier = normalizedAssistantPlannerModelIdentifier()
        let contextRows = coreContext.prefix(6).map { item in
            "[\(item.id)] \(item.filename): \(shortText(item.snippet, limit: 220))"
        }.joined(separator: "\n")
        let toolsJSON: [[String: Any]] = assistantToolSpecs().map { spec in
            [
                "name": spec.name,
                "description": spec.description,
                "required_arguments": spec.requiredArguments,
                "risk": spec.riskLevel.rawValue
            ]
        }
        let toolsData = (try? JSONSerialization.data(withJSONObject: toolsJSON, options: [.prettyPrinted])) ?? Data()
        let toolsText = String(data: toolsData, encoding: .utf8) ?? "[]"

        let system = """
        你是 Boss 项目助理的 Planner。你只能规划工具调用，不能直接回答业务结果。
        输出 JSON，字段：
        - calls: [{ "name": string, "arguments": object }]
        - clarify_question: string (只有在无法执行时填写；此时 calls 应为空)
        - tool_plan: string[] (简短步骤，可为空)
        - note: string
        只允许使用给定工具名。
        """
        let userPrompt = """
        REQUEST:
        \(request)

        CORE_CONTEXT:
        \(contextRows.isEmpty ? "(none)" : contextRows)

        TOOLS:
        \(toolsText)

        输出 JSON，不要附加 Markdown 代码块。
        """

        let raw = try await callLLM(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
        guard let payload = extractFirstJSONObject(from: raw),
              let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let clarifyQuestion = (object["clarify_question"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (object["note"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolPlan = (object["tool_plan"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var plannedCalls: [CLIAssistantToolCall] = []
        if let rawCalls = object["calls"] as? [[String: Any]] {
            plannedCalls = rawCalls.compactMap { item in
                let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let rawArgs = item["arguments"] as? [String: Any] ?? [:]
                let normalizedArgs: [String: String] = rawArgs.reduce(into: [:]) { partialResult, pair in
                    if let stringValue = pair.value as? String {
                        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            partialResult[pair.key] = trimmed
                        }
                    } else if let number = pair.value as? NSNumber {
                        partialResult[pair.key] = number.stringValue
                    }
                }
                return materializeAssistantToolCall(name: name, arguments: normalizedArgs, request: request)
            }
        }

        if plannedCalls.isEmpty, let legacy = legacyAssistantIntentCall(from: object, request: request) {
            plannedCalls = [legacy]
        }

        if let override = overrideAssistantLLMPlannedCallsIfNeeded(request: request, plannedCalls: plannedCalls) {
            return CLIAssistantPlannedToolCalls(
                calls: override,
                plannerSource: "llm:\(modelIdentifier)",
                plannerNote: note.isEmpty ? "已应用规则覆盖（避免日期语义被降级为纯检索）。" : "\(note)（已应用规则覆盖）",
                toolPlan: defaultAssistantToolPlan(for: override),
                clarifyQuestion: nil
            )
        }

        if clarifyQuestion.isEmpty,
           let forcedClarify = minimalAssistantClarifyQuestion(for: request) {
            let mutatingToolNames: Set<String> = ["record.create", "record.delete", "record.append", "record.replace", "task.run", "skill.run"]
            if plannedCalls.contains(where: { mutatingToolNames.contains($0.name) }) {
                return CLIAssistantPlannedToolCalls(
                    calls: [],
                    plannerSource: "llm:\(modelIdentifier)",
                    plannerNote: note.isEmpty ? nil : note,
                    toolPlan: toolPlan.isEmpty ? ["ask-minimal-clarify-question"] : toolPlan,
                    clarifyQuestion: forcedClarify
                )
            }
        }

        if plannedCalls.isEmpty && clarifyQuestion.isEmpty {
            if let fallbackClarify = minimalAssistantClarifyQuestion(for: request) {
                return CLIAssistantPlannedToolCalls(
                    calls: [],
                    plannerSource: "llm:\(modelIdentifier)",
                    plannerNote: note.isEmpty ? nil : note,
                    toolPlan: toolPlan.isEmpty ? ["ask-minimal-clarify-question"] : toolPlan,
                    clarifyQuestion: fallbackClarify
                )
            }
            return nil
        }

        return CLIAssistantPlannedToolCalls(
            calls: plannedCalls,
            plannerSource: "llm:\(modelIdentifier)",
            plannerNote: note.isEmpty ? nil : note,
            toolPlan: toolPlan.isEmpty ? defaultAssistantToolPlan(for: plannedCalls) : toolPlan,
            clarifyQuestion: clarifyQuestion.isEmpty ? nil : clarifyQuestion
        )
    }

    func legacyAssistantIntentCall(from object: [String: Any], request: String) -> CLIAssistantToolCall? {
        let rawIntent = (object["intent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query = (object["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = (object["record_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (object["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = ((object["filename"] as? String) ?? (object["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch rawIntent {
        case "help":
            return CLIAssistantToolCall(name: "assistant.help")
        case "summarizecore", "summarize_core":
            return CLIAssistantToolCall(name: "core.summarize")
        case "answer", "qa", "question":
            let resolvedQuestion = query.isEmpty ? request : query
            return materializeAssistantToolCall(name: "assistant.answer", arguments: ["question": resolvedQuestion], request: request)
        case "skillscatalog", "skills_catalog", "skillcatalog", "skill_catalog":
            return CLIAssistantToolCall(name: "skills.catalog")
        case "search":
            let resolved = query.isEmpty ? extractSearchQuery(request) : query
            return materializeAssistantToolCall(name: "record.search", arguments: ["query": resolved], request: request)
        case "create", "create_record", "record_create":
            let resolvedContent = content.isEmpty ? extractCreateContent(request) : content
            let resolvedFilename: String
            if filename.isEmpty {
                resolvedFilename = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
            } else {
                resolvedFilename = normalizeCreateFilename(filename)
            }
            return materializeAssistantToolCall(name: "record.create", arguments: ["filename": resolvedFilename, "content": resolvedContent], request: request)
        case "taskrun", "task_run":
            let resolved = query.isEmpty ? extractTaskReference(request) : query
            return materializeAssistantToolCall(name: "task.run", arguments: ["task_ref": resolved], request: request)
        case "skillrun", "skill_run":
            let resolved = query.isEmpty ? extractSkillReference(request) : query
            let resolvedInput = content.isEmpty ? extractPayload(request) : content
            return materializeAssistantToolCall(name: "skill.run", arguments: ["skill_ref": resolved, "input": resolvedInput], request: request)
        case "delete":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            return materializeAssistantToolCall(name: "record.delete", arguments: ["record_id": resolvedID], request: request)
        case "append":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            return materializeAssistantToolCall(name: "record.append", arguments: ["record_id": resolvedID, "content": resolvedContent], request: request)
        case "replace":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            return materializeAssistantToolCall(name: "record.replace", arguments: ["record_id": resolvedID, "content": resolvedContent], request: request)
        default:
            return nil
        }
    }

    func assistantToolCalls(for intent: CLIAssistantIntent, request: String) -> [CLIAssistantToolCall] {
        switch intent {
        case .help:
            return [CLIAssistantToolCall(name: "assistant.help")]
        case .summarizeCore:
            return [CLIAssistantToolCall(name: "core.summarize")]
        case .answer(let question):
            return [CLIAssistantToolCall(name: "assistant.answer", arguments: ["question": question])]
        case .skillsCatalog:
            return [CLIAssistantToolCall(name: "skills.catalog")]
        case .skillRun(let skillRef, let input):
            return [CLIAssistantToolCall(name: "skill.run", arguments: ["skill_ref": skillRef, "input": input])]
        case .search(let query):
            return [CLIAssistantToolCall(name: "record.search", arguments: ["query": query])]
        case .create(let filename, let content):
            return [CLIAssistantToolCall(name: "record.create", arguments: ["filename": filename, "content": content])]
        case .taskRun(let taskRef):
            return [CLIAssistantToolCall(name: "task.run", arguments: ["task_ref": taskRef])]
        case .delete(let recordID):
            return [CLIAssistantToolCall(name: "record.delete", arguments: ["record_id": recordID])]
        case .append(let recordID, let content):
            return [CLIAssistantToolCall(name: "record.append", arguments: ["record_id": recordID, "content": content])]
        case .replace(let recordID, let content):
            return [CLIAssistantToolCall(name: "record.replace", arguments: ["record_id": recordID, "content": content])]
        case .unknown:
            return [CLIAssistantToolCall(name: "record.search", arguments: ["query": extractSearchQuery(request)])]
        }
    }

    func materializeAssistantToolCall(name: String, arguments: [String: String], request: String) -> CLIAssistantToolCall? {
        guard let spec = assistantToolSpec(named: name) else { return nil }
        var args = arguments.reduce(into: [String: String]()) { partialResult, pair in
            let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[pair.key] = trimmed
            }
        }

        switch name {
        case "assistant.answer":
            if args["question"]?.isEmpty ?? true {
                args["question"] = request
            }
        case "record.search":
            if args["query"]?.isEmpty ?? true {
                args["query"] = extractSearchQuery(request)
            }
        case "record.create":
            if args["filename"]?.isEmpty ?? true {
                args["filename"] = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
            } else if let raw = args["filename"] {
                args["filename"] = normalizeCreateFilename(raw)
            }
            if args["content"]?.isEmpty ?? true {
                args["content"] = extractCreateContent(request)
            }
        case "task.run":
            if args["task_ref"]?.isEmpty ?? true {
                args["task_ref"] = extractTaskReference(request)
            }
        case "skill.run":
            if args["skill_ref"]?.isEmpty ?? true {
                args["skill_ref"] = extractSkillReference(request)
            }
            if args["input"]?.isEmpty ?? true {
                args["input"] = extractPayload(request)
            }
        case "record.delete":
            if let raw = args["record_id"], isPlaceholderRecordReference(raw) {
                args["record_id"] = extractRecordReference(request)
            }
            if args["record_id"]?.isEmpty ?? true {
                args["record_id"] = extractRecordReference(request)
            }
        case "record.append", "record.replace":
            if let raw = args["record_id"], isPlaceholderRecordReference(raw) {
                args["record_id"] = extractRecordReference(request)
            }
            if args["record_id"]?.isEmpty ?? true {
                args["record_id"] = extractRecordReference(request)
            }
            if args["content"]?.isEmpty ?? true {
                args["content"] = extractPayload(request)
            }
        default:
            break
        }

        let hasAllRequiredArgs = spec.requiredArguments.allSatisfy { key in
            let value = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !value.isEmpty
        }
        guard hasAllRequiredArgs else { return nil }

        return CLIAssistantToolCall(name: name, arguments: args)
    }

    func describeAssistantToolCalls(_ calls: [CLIAssistantToolCall], fallbackRequest: String) -> String {
        guard !calls.isEmpty else {
            return "unknown(\(fallbackRequest))"
        }
        return calls.map { call in
            if let recordID = call.arguments["record_id"], !recordID.isEmpty {
                return "\(call.name)(\(recordID.uppercased()))"
            }
            if let filename = call.arguments["filename"], !filename.isEmpty {
                return "\(call.name)(\(filename))"
            }
            if let taskRef = call.arguments["task_ref"], !taskRef.isEmpty {
                return "\(call.name)(\(taskRef))"
            }
            if let skillRef = call.arguments["skill_ref"], !skillRef.isEmpty {
                return "\(call.name)(\(skillRef))"
            }
            if let query = call.arguments["query"], !query.isEmpty {
                return "\(call.name)(\(query))"
            }
            return call.name
        }.joined(separator: " -> ")
    }

    func requiresConfirmation(toolCalls: [CLIAssistantToolCall]) -> Bool {
        toolCalls.contains { call in
            assistantToolSpec(named: call.name)?.riskLevel == .high
        }
    }

    func relatedRecordIDsFromToolCalls(_ toolCalls: [CLIAssistantToolCall]) -> [String] {
        var ids: [String] = []
        for call in toolCalls {
            guard let recordID = call.arguments["record_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !recordID.isEmpty else {
                continue
            }
            let normalized = recordID.uppercased()
            if !ids.contains(normalized) {
                ids.append(normalized)
            }
        }
        return ids
    }

    func buildAssistantDryRunPreview(toolCalls: [CLIAssistantToolCall]) throws -> String {
        var lines: [String] = []
        for call in toolCalls {
            switch call.name {
            case "record.delete":
                let requested = call.arguments["record_id"] ?? "-"
                let recordID = (try? resolveRecordReference(requested, for: .delete, request: requested)) ?? requested.uppercased()
                let rows = try db.query(
                    "SELECT id, filename FROM records WHERE id = ? LIMIT 1",
                    bindings: [.text(recordID)]
                )
                if let row = rows.first {
                    lines.append("- record.delete: 将删除 [\(row["id"]?.stringValue ?? recordID)] \(row["filename"]?.stringValue ?? "")")
                } else {
                    lines.append("- record.delete: 目标记录不存在 [\(recordID)]")
                }

            case "record.replace":
                let requested = call.arguments["record_id"] ?? "-"
                let recordID = (try? resolveRecordReference(requested, for: .replace, request: requested)) ?? requested.uppercased()
                let content = call.arguments["content"] ?? ""
                let rows = try db.query(
                    "SELECT id, filename FROM records WHERE id = ? LIMIT 1",
                    bindings: [.text(recordID)]
                )
                if let row = rows.first {
                    lines.append("- record.replace: 将改写 [\(row["id"]?.stringValue ?? recordID)] \(row["filename"]?.stringValue ?? "")，新内容约 \(content.count) 字符")
                } else {
                    lines.append("- record.replace: 目标记录不存在 [\(recordID)]")
                }

            case "task.run":
                let ref = call.arguments["task_ref"] ?? ""
                if ref.isEmpty {
                    lines.append("- task.run: 缺少 task_ref")
                } else if let resolved = try? resolveTaskID(taskRef: ref) {
                    lines.append("- task.run: 将运行任务 \(resolved.name)（\(resolved.id)）")
                } else {
                    lines.append("- task.run: 未找到任务 \(ref)")
                }

            case "skill.run":
                let ref = call.arguments["skill_ref"] ?? ""
                if ref.isEmpty {
                    lines.append("- skill.run: 缺少 skill_ref")
                } else if let resolved = try? resolveSkillMetadata(skillRef: ref) {
                    lines.append("- skill.run: 将运行 Skill \(resolved.name)（\(resolved.id)）")
                } else {
                    lines.append("- skill.run: 未找到 Skill \(ref)")
                }

            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    func normalizedAssistantPlannerModelIdentifier() -> String {
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

    func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        guard start <= end else { return nil }
        return String(text[start...end])
    }

    func buildAssistantConfirmationReply(toolCalls: [CLIAssistantToolCall], token: String, expiresAt: Date, dryRunPreview: String) -> String {
        let actionDescription: String
        if let deleteCall = toolCalls.first(where: { $0.name == "record.delete" }),
           let recordID = deleteCall.arguments["record_id"], !recordID.isEmpty {
            actionDescription = "删除记录 \(recordID.uppercased())"
        } else if let replaceCall = toolCalls.first(where: { $0.name == "record.replace" }),
                  let recordID = replaceCall.arguments["record_id"], !recordID.isEmpty {
            actionDescription = "改写记录 \(recordID.uppercased())"
        } else {
            actionDescription = "执行高风险动作"
        }
        return """
        Dry-run 预览（影响范围）：
        \(dryRunPreview.isEmpty ? "- 无可预览信息" : dryRunPreview)

        此操作需要二次确认：\(actionDescription)。
        请在 \(iso8601(expiresAt)) 前发送：#CONFIRM:\(token)
        或执行：boss assistant confirm \(token)
        """
    }

    func extractAssistantConfirmationToken(_ text: String) -> String? {
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

    func generateAssistantConfirmationToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }

    func consumePendingConfirmationIfProvided(request: String, source: String) throws -> (token: String?, toolCalls: [CLIAssistantToolCall]?) {
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

        guard let payloadData = payloadRaw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CLIAssistantPendingIntent.self, from: payloadData) else {
            try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
            return (token, nil)
        }

        if expiresAt <= Date().timeIntervalSince1970 {
            try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
            return (token, nil)
        }

        guard payload.source.isEmpty || payload.source == source else {
            return (token, nil)
        }

        try db.execute("DELETE FROM assistant_pending_confirms WHERE token = ?", bindings: [.text(token)])
        return (token, payload.toolCalls)
    }

    func savePendingConfirmation(
        toolCalls: [CLIAssistantToolCall],
        request: String,
        source: String,
        toolPlan: [String]
    ) throws -> (token: String, expiresAt: Date) {
        try cleanupExpiredPendingConfirmations()
        guard !toolCalls.isEmpty else {
            throw CLIError.invalidData("高风险动作确认数据构造失败：toolCalls 为空")
        }
        let now = Date().timeIntervalSince1970
        let expiresAtValue = now + 5 * 60
        let payload = CLIAssistantPendingIntent(
            toolCalls: toolCalls,
            source: source,
            request: request,
            toolPlan: toolPlan,
            createdAt: now,
            expiresAt: expiresAtValue
        )
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

    func cleanupExpiredPendingConfirmations() throws {
        try db.execute(
            "DELETE FROM assistant_pending_confirms WHERE expires_at <= ?",
            bindings: [.real(Date().timeIntervalSince1970)]
        )
    }

}
