import Foundation
import SQLite3

extension BossCLI {
    func executeAssistantToolCalls(
        _ toolCalls: [CLIAssistantToolCall],
        request: String,
        coreContext: [CLIAssistantContextItem]
    ) async throws -> CLIAssistantOutput {
        guard !toolCalls.isEmpty else {
            return CLIAssistantOutput(
                reply: "我需要更多信息才能继续。请补充你要执行的动作（搜索/删除/追加/改写）以及目标记录。",
                actions: ["tool.execute:empty"],
                relatedRecordIDs: []
            )
        }

        var replies: [String] = []
        var actions: [String] = []
        var relatedIDs: [String] = []

        for call in toolCalls {
            guard let intent = assistantIntent(from: call, request: request) else {
                actions.append("tool.unsupported:\(call.name)")
                continue
            }
            let output = try await executeAssistantIntent(intent, request: request, coreContext: coreContext)
            if !output.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                replies.append(output.reply)
            }
            actions.append("tool.execute:\(call.name)")
            actions.append(contentsOf: output.actions)
            for recordID in output.relatedRecordIDs where !relatedIDs.contains(recordID) {
                relatedIDs.append(recordID)
            }
        }

        let reply = replies.joined(separator: "\n\n")
        return CLIAssistantOutput(
            reply: reply.isEmpty ? "未执行任何有效工具调用，请重试并明确目标。" : reply,
            actions: actions,
            relatedRecordIDs: relatedIDs
        )
    }

    func assistantIntent(from call: CLIAssistantToolCall, request: String) -> CLIAssistantIntent? {
        switch call.name {
        case "assistant.help":
            return .help
        case "core.summarize":
            return .summarizeCore
        case "assistant.answer":
            let question = call.arguments["question"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .answer(question: question.isEmpty ? request : question)
        case "skills.catalog":
            return .skillsCatalog
        case "skill.run":
            let skillRef = call.arguments["skill_ref"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !skillRef.isEmpty else { return nil }
            let input = call.arguments["input"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .skillRun(skillRef: skillRef, input: input)
        case "record.search":
            let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .search(query.isEmpty ? extractSearchQuery(request) : query)
        case "record.create":
            let filename = call.arguments["filename"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = call.arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { return nil }
            let resolvedFilename = filename.isEmpty ? defaultCreateFilename(for: request) : normalizeCreateFilename(filename)
            return .create(filename: resolvedFilename, content: content)
        case "task.run":
            let taskRef = call.arguments["task_ref"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !taskRef.isEmpty else { return nil }
            return .taskRun(taskRef)
        case "record.delete":
            let rawRecordID = call.arguments["record_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let recordID: String
            if rawRecordID.isEmpty || isPlaceholderRecordReference(rawRecordID) {
                recordID = extractRecordReference(request) ?? ""
            } else {
                recordID = rawRecordID
            }
            guard !recordID.isEmpty else { return nil }
            return .delete(recordID.uppercased())
        case "record.append":
            let rawRecordID = call.arguments["record_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let recordID: String
            if rawRecordID.isEmpty || isPlaceholderRecordReference(rawRecordID) {
                recordID = extractRecordReference(request) ?? ""
            } else {
                recordID = rawRecordID
            }
            let content = call.arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !recordID.isEmpty, !content.isEmpty else { return nil }
            return .append(recordID: recordID.uppercased(), content: content)
        case "record.replace":
            let rawRecordID = call.arguments["record_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let recordID: String
            if rawRecordID.isEmpty || isPlaceholderRecordReference(rawRecordID) {
                recordID = extractRecordReference(request) ?? ""
            } else {
                recordID = rawRecordID
            }
            let content = call.arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !recordID.isEmpty, !content.isEmpty else { return nil }
            return .replace(recordID: recordID.uppercased(), content: content)
        default:
            return nil
        }
    }

    func executeAssistantIntent(
        _ intent: CLIAssistantIntent,
        request: String,
        coreContext: [CLIAssistantContextItem]
    ) async throws -> CLIAssistantOutput {
        switch intent {
        case .help:
            return CLIAssistantOutput(
                reply: """
                我支持这些操作：
                1. 搜索/检索：例如 “搜索 Swift 并发”
                2. 新建文本记录：例如 “为明天新建计划：<内容>”
                3. 运行任务：例如 “运行任务 <task-id>”
                4. 运行 Skill：例如 “运行 skill:<skill-name>，输入：<内容>”
                5. 问答：例如 “今天我做了什么？”
                6. 查看 Skill 文档：例如 “skills catalog” 或 “技能列表”
                7. 删除记录：例如 “删除记录 <record-id>”
                8. 追加文本：例如 “向 <record-id> 或 TODAY 追加：<内容>”
                9. 改写文本：例如 “把 <record-id> 改写为：<内容>”
                10. 总结 Core：例如 “总结 Core 记忆”
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

        case .answer(let question):
            return try await answerAssistantQuestion(question: question, coreContext: coreContext)

        case .skillsCatalog:
            return CLIAssistantOutput(
                reply: try loadSkillManifestText(refreshIfMissing: true),
                actions: ["skills.catalog:read"],
                relatedRecordIDs: []
            )

        case .skillRun(let skillRef, let input):
            let skill = try resolveSkillMetadata(skillRef: skillRef)
            guard skill.isEnabled else {
                return CLIAssistantOutput(
                    reply: "Skill 已停用：\(skill.name)（\(skill.id)）",
                    actions: ["skill.run:\(skill.id):disabled"],
                    relatedRecordIDs: []
                )
            }
            let resolvedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request : input
            return try await executeCLISkill(skill: skill, input: resolvedInput, request: request)

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

        case .create(let filename, let content):
            let id = try createTextRecord(filename: filename, text: content)
            var reply = "已创建文本记录：\(filename)（\(id)）"
            if let date = resolveDateReference(in: request) {
                reply += "\n日期：\(dateFilenameStamp(date))"
            }
            return CLIAssistantOutput(
                reply: reply,
                actions: ["record.create:\(id):ok"],
                relatedRecordIDs: [id]
            )

        case .taskRun(let taskRef):
            let resolved = try resolveTaskID(taskRef: taskRef)
            let output = try await runTaskNow(taskID: resolved.id)
            return CLIAssistantOutput(
                reply: "已运行 任务：\(resolved.name)（\(resolved.id)）\n\(shortText(output, limit: 260))",
                actions: ["task.run:\(resolved.id):ok"],
                relatedRecordIDs: []
            )

        case .delete(let recordID):
            let resolvedID = try resolveRecordReference(recordID, for: .delete, request: request)
            try deleteRecord(id: resolvedID, printOutput: false)
            return CLIAssistantOutput(
                reply: "已删除记录：\(resolvedID)",
                actions: ["record.delete:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .append(let recordID, let content):
            let resolvedID = try resolveRecordReference(recordID, for: .append, request: request, createIfMissingContent: content)
            let output = try appendToRecord(recordID: resolvedID, appendText: content)
            return CLIAssistantOutput(
                reply: output,
                actions: ["record.append:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .replace(let recordID, let content):
            let resolvedID = try resolveRecordReference(recordID, for: .replace, request: request)
            let output = try replaceRecordText(recordID: resolvedID, text: content)
            return CLIAssistantOutput(
                reply: output,
                actions: ["record.replace:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .unknown(let query):
            let rows = try searchRecords(query: query, limit: 5)
            if rows.isEmpty {
                return CLIAssistantOutput(
                    reply: "我无法直接确认你的意图，且检索未命中。请提供明确动作（搜索/新建/删除/追加/改写）和记录ID。",
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
                reply: "我先按检索理解你的需求，命中这些记录：\n\(lines)\n\n请继续给出动作（新建/删除/追加/改写）与目标记录ID（可用 TODAY/明天）。",
                actions: ["intent.unknown", "record.search.fallback:\(rows.count)"],
                relatedRecordIDs: rows.compactMap { $0["id"]?.stringValue }
            )
        }
    }

    func shouldTreatAsAssistantQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let actionKeywords = [
            "创建", "新建", "新增", "删除", "追加", "补充", "改写", "编辑", "更新",
            "create", "new note", "delete", "append", "replace", "rewrite",
            "搜索", "检索", "查找", "search", "find", "task.run", "run task", "skill.run", "run skill"
        ]
        if containsAssistantKeyword(lower, keywords: actionKeywords) {
            return false
        }
        if text.contains("?") || text.contains("？") {
            return true
        }
        let questionKeywords = [
            "今天我做了什么", "今天做了什么", "我做了什么", "回顾", "总结", "为什么", "怎么", "如何", "哪些", "什么",
            "what did i do", "what have i done", "why", "how", "what", "which", "when"
        ]
        return containsAssistantKeyword(lower, keywords: questionKeywords)
    }

    func isTodayAssistantActivityQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let dayKeywords = ["今天", "today"]
        let activityKeywords = ["做了什么", "干了什么", "完成了什么", "what did i do", "what have i done"]
        return containsAssistantKeyword(lower, keywords: dayKeywords) && containsAssistantKeyword(lower, keywords: activityKeywords)
    }

    func tailAssistantText(_ text: String, limit: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let start = normalized.index(normalized.endIndex, offsetBy: -limit)
        return "...\n" + normalized[start...]
    }

    func loadAssistantAuditSnippetsForAnswer(question: String, limit: Int) throws -> [(id: String, filename: String, snippet: String)] {
        let auditTagID = try ensureTag(name: "AuditLog", aliases: ["audit", "audit log", "审计"], color: "#FF9F0A", icon: "doc.text.magnifyingglass")
        var rows = try db.query(
            """
            SELECT r.id, r.filename, r.file_path, r.updated_at
            FROM records r
            JOIN record_tags rt ON rt.record_id = r.id
            WHERE rt.tag_id = ? AND r.is_archived = 0
            ORDER BY r.updated_at DESC
            LIMIT 120
            """,
            bindings: [.text(auditTagID)]
        )

        if isTodayAssistantActivityQuestion(question) {
            let todayFilename = "assistant-audit-\(dateFilenameStamp(Date())).txt"
            rows.sort { lhs, rhs in
                let lhsFilename = lhs["filename"]?.stringValue ?? ""
                let rhsFilename = rhs["filename"]?.stringValue ?? ""
                let lhsToday = lhsFilename.caseInsensitiveCompare(todayFilename) == .orderedSame
                let rhsToday = rhsFilename.caseInsensitiveCompare(todayFilename) == .orderedSame
                if lhsToday == rhsToday {
                    return (lhs["updated_at"]?.doubleValue ?? 0) > (rhs["updated_at"]?.doubleValue ?? 0)
                }
                return lhsToday && !rhsToday
            }
        }

        return rows.prefix(limit).compactMap { row in
            guard let id = row["id"]?.stringValue,
                  let filename = row["filename"]?.stringValue,
                  let filePath = row["file_path"]?.stringValue else {
                return nil
            }
            let text = (try? readText(relativePath: filePath, maxBytes: 240_000)) ?? ""
            return (id: id, filename: filename, snippet: tailAssistantText(text, limit: 1800))
        }
    }

    func answerAssistantQuestion(
        question: String,
        coreContext: [CLIAssistantContextItem]
    ) async throws -> CLIAssistantOutput {
        let coreRows = coreContext.prefix(8).map { item in
            "[\(item.id)] \(item.filename): \(shortText(item.snippet, limit: 180))"
        }
        let auditRows = try loadAssistantAuditSnippetsForAnswer(question: question, limit: 6)

        var relatedIDs: [String] = []
        for item in coreContext.prefix(8) where !relatedIDs.contains(item.id) {
            relatedIDs.append(item.id)
        }
        for row in auditRows where !relatedIDs.contains(row.id) {
            relatedIDs.append(row.id)
        }

        let coreContextText = coreRows.joined(separator: "\n")
        let auditContextText = auditRows.map { row in
            "[\(row.id)] \(row.filename): \(shortText(row.snippet, limit: 320))"
        }.joined(separator: "\n")
        let skillCatalog = (try? loadSkillManifestText(refreshIfMissing: true)) ?? "(empty)"

        let system = """
        你是 Boss 助理。必须优先根据提供的 Core 记忆、Audit 日志、Skill 目录回答问题，不得编造。
        如果问题是“今天做了什么”，优先基于当天审计记录做事实性总结。
        如果证据不足，请明确说“不确定”，并说明缺少哪些信息。
        回答简洁、直接。
        """
        let userPrompt = """
        QUESTION:
        \(question)

        CORE_CONTEXT:
        \(coreContextText.isEmpty ? "(none)" : coreContextText)

        AUDIT_CONTEXT:
        \(auditContextText.isEmpty ? "(none)" : auditContextText)

        SKILL_CATALOG:
        \(skillCatalog)
        """

        do {
            let answer = try await callLLM(
                system: system,
                userPrompt: userPrompt,
                modelIdentifier: normalizedAssistantPlannerModelIdentifier()
            )
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return CLIAssistantOutput(
                    reply: trimmed,
                    actions: ["assistant.answer:context"],
                    relatedRecordIDs: relatedIDs
                )
            }
        } catch {
            // fallback to local summary below
        }

        if isTodayAssistantActivityQuestion(question) {
            if let today = auditRows.first(where: { $0.filename.contains(dateFilenameStamp(Date())) }) {
                return CLIAssistantOutput(
                    reply: "根据今天的日志，已记录这些活动：\n\(shortText(today.snippet, limit: 520))",
                    actions: ["assistant.answer:fallback:today"],
                    relatedRecordIDs: relatedIDs
                )
            }
            return CLIAssistantOutput(
                reply: "今天还没有可用的审计日志记录，所以我还不能可靠地回答“今天做了什么”。",
                actions: ["assistant.answer:fallback:today-empty"],
                relatedRecordIDs: relatedIDs
            )
        }

        if !coreRows.isEmpty {
            let lines = coreRows.prefix(4).joined(separator: "\n")
            return CLIAssistantOutput(
                reply: "我当前能从 Core 记忆确认这些信息：\n\(lines)\n\n如果你希望更精确，我可以继续按关键词检索相关记录。",
                actions: ["assistant.answer:fallback:core"],
                relatedRecordIDs: relatedIDs
            )
        }

        return CLIAssistantOutput(
            reply: "当前可用上下文不足，暂时无法可靠回答。你可以先让我“搜索 <关键词>”或“总结 Core 记忆”。",
            actions: ["assistant.answer:fallback:empty"],
            relatedRecordIDs: relatedIDs
        )
    }

    func parseAssistantIntent(_ request: String) -> CLIAssistantIntent {
        let lower = request.lowercased()
        let recordReference = extractRecordReference(request)
        let payload = extractPayload(request)
        let createContent = extractCreateContent(request)
        let taskRef = extractTaskReference(request)
        let skillRef = extractSkillReference(request)

        if lower.contains("help") || lower.contains("帮助") || lower.contains("你能做什么") {
            return .help
        }
        if lower.contains("总结") || lower.contains("回顾") || lower.contains("core memory") || lower.contains("持久记忆") {
            return .summarizeCore
        }
        if lower.contains("skills.catalog")
            || lower.contains("skill manifest")
            || lower.contains("skill list")
            || lower.contains("skills list")
            || lower.contains("技能列表")
            || lower.contains("skill文档")
            || lower.contains("技能文档")
        {
            return .skillsCatalog
        }
        if lower.contains("task.run")
            || lower.contains("run task")
            || lower.contains("运行任务")
            || lower.contains("执行任务")
            || lower.contains("运行任务")
            || lower.contains("执行任务")
        {
            if !taskRef.isEmpty {
                return .taskRun(taskRef)
            }
        }
        if lower.contains("skill.run")
            || lower.contains("run skill")
            || lower.contains("运行skill")
            || lower.contains("执行skill")
            || lower.contains("运行技能")
            || lower.contains("执行技能")
            || lower.contains("调用skill")
            || lower.contains("使用skill")
        {
            if !skillRef.isEmpty {
                let input = payload.isEmpty ? request : payload
                return .skillRun(skillRef: skillRef, input: input)
            }
        }
        if shouldCreateRecordIntent(lowerText: lower) {
            if !createContent.isEmpty {
                let filename = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
                return .create(filename: filename, content: createContent)
            }
        }
        if let recordReference, lower.contains("删除") || lower.contains("delete") || lower.contains("移除") {
            return .delete(recordReference)
        }
        if let recordReference, !payload.isEmpty, (lower.contains("追加") || lower.contains("append") || lower.contains("补充")) {
            return .append(recordID: recordReference, content: payload)
        }
        if let recordReference, !payload.isEmpty, (lower.contains("改写") || lower.contains("replace") || lower.contains("rewrite") || lower.contains("编辑") || lower.contains("更新")) {
            return .replace(recordID: recordReference, content: payload)
        }
        if lower.contains("搜索") || lower.contains("检索") || lower.contains("查找") || lower.contains("search") || lower.contains("find") {
            return .search(extractSearchQuery(request))
        }
        if shouldTreatAsAssistantQuestion(request) {
            return .answer(question: request)
        }
        return .unknown(request)
    }

    func ensureTag(name: String, aliases: [String], color: String, icon: String) throws -> String {
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

    func loadCoreContext(coreTagID: String, request: String, limit: Int) throws -> [CLIAssistantContextItem] {
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

    func searchRecords(query: String, limit: Int) throws -> [[String: SQLColumnValue]] {
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

    enum RecordReferenceAction {
        case delete
        case append
        case replace
    }

    func resolveRecordReference(
        _ raw: String,
        for action: RecordReferenceAction,
        request: String,
        createIfMissingContent: String? = nil
    ) throws -> String {
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw CLIError.invalidData("记录引用为空")
        }

        if isPlaceholderRecordReference(reference) {
            if let extracted = extractRecordReference(request),
               !extracted.isEmpty,
               extracted.caseInsensitiveCompare(reference) != .orderedSame {
                return try resolveRecordReference(
                    extracted,
                    for: action,
                    request: request,
                    createIfMissingContent: createIfMissingContent
                )
            }
            throw CLIError.invalidData("缺少目标记录引用，请提供记录 ID 或 TODAY/明天。")
        }

        if let uuid = extractRecordID(reference) {
            return uuid
        }

        if let date = resolveDateReference(in: reference) {
            if let existing = try findTextRecordID(for: date) {
                return existing
            }
            if action == .append,
               let content = createIfMissingContent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                let id = try createTextRecord(filename: defaultCreateFilename(for: request, date: date), text: content)
                return id
            }
            throw CLIError.notFound("未找到 \(dateFilenameStamp(date)) 对应记录")
        }

        return reference.uppercased()
    }

    func findTextRecordID(for date: Date) throws -> String? {
        let compact = dateCompactStamp(date)
        let dashed = dateFilenameStamp(date)
        let rows = try db.query(
            """
            SELECT id, filename, file_type
            FROM records
            WHERE is_archived = 0
            ORDER BY updated_at DESC
            LIMIT 500
            """
        )
        return rows.first { row in
            let fileType = row["file_type"]?.stringValue ?? ""
            guard ["text", "web", "log"].contains(fileType) else { return false }
            let filename = (row["filename"]?.stringValue ?? "").lowercased()
            return filename.contains(compact) || filename.contains(dashed)
        }?["id"]?.stringValue
    }

    func resolveTaskID(taskRef: String) throws -> (id: String, name: String) {
        let reference = taskRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw CLIError.invalidData("任务引用为空")
        }

        let rows = try db.query(
            """
            SELECT id, name
            FROM tasks
            ORDER BY created_at DESC
            """
        )
        guard !rows.isEmpty else {
            throw CLIError.notFound("当前没有可运行的任务")
        }

        if let byID = rows.first(where: { ($0["id"]?.stringValue ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            return (byID["id"]?.stringValue ?? "", byID["name"]?.stringValue ?? "")
        }

        if let byExactName = rows.first(where: { ($0["name"]?.stringValue ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            return (byExactName["id"]?.stringValue ?? "", byExactName["name"]?.stringValue ?? "")
        }

        if let byContainsName = rows.first(where: { ($0["name"]?.stringValue ?? "").lowercased().contains(reference.lowercased()) }) {
            return (byContainsName["id"]?.stringValue ?? "", byContainsName["name"]?.stringValue ?? "")
        }

        throw CLIError.notFound("未找到任务：\(reference)")
    }

    func resolveSkillMetadata(skillRef: String) throws -> (id: String, name: String, isEnabled: Bool, action: CLISkillAction) {
        let reference = skillRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw CLIError.invalidData("Skill 引用为空")
        }

        let rows = try db.query(
            """
            SELECT id, name, is_enabled, action_json
            FROM assistant_skills
            ORDER BY created_at DESC
            """
        )
        guard !rows.isEmpty else {
            throw CLIError.notFound("当前没有可运行的 Skill")
        }

        let decoder = JSONDecoder()
        let matched: [String: SQLColumnValue]?
        if let byID = rows.first(where: { ($0["id"]?.stringValue ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            matched = byID
        } else if let byName = rows.first(where: { ($0["name"]?.stringValue ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            matched = byName
        } else if let byContains = rows.first(where: { ($0["name"]?.stringValue ?? "").lowercased().contains(reference.lowercased()) }) {
            matched = byContains
        } else {
            matched = nil
        }

        guard let row = matched,
              let id = row["id"]?.stringValue,
              let name = row["name"]?.stringValue,
              let actionRaw = row["action_json"]?.stringValue,
              let actionData = actionRaw.data(using: .utf8),
              let action = try? decoder.decode(CLISkillAction.self, from: actionData)
        else {
            throw CLIError.notFound("未找到 Skill：\(reference)")
        }

        let isEnabled = (row["is_enabled"]?.intValue ?? 0) == 1
        return (id: id, name: name, isEnabled: isEnabled, action: action)
    }

    func executeCLISkill(
        skill: (id: String, name: String, isEnabled: Bool, action: CLISkillAction),
        input: String,
        request: String
    ) async throws -> CLIAssistantOutput {
        switch skill.action {
        case .llmPrompt(let systemPrompt, let userPromptTemplate, let model):
            let system = renderSkillTemplate(systemPrompt, input: input, request: request)
            let prompt = renderSkillTemplate(userPromptTemplate, input: input, request: request)
            let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? normalizedAssistantPlannerModelIdentifier()
                : model
            let output = try await callLLM(system: system, userPrompt: prompt, modelIdentifier: modelID)
            return CLIAssistantOutput(
                reply: "Skill \(skill.name) 执行完成。\n\(output)",
                actions: ["skill.run:\(skill.id):llm"],
                relatedRecordIDs: []
            )

        case .shellCommand(let commandTemplate):
            let command = renderSkillTemplate(commandTemplate, input: input, request: request)
            let output = try runShell(command)
            return CLIAssistantOutput(
                reply: "Skill \(skill.name) 执行完成。\n\(shortText(output, limit: 800))",
                actions: ["skill.run:\(skill.id):shell"],
                relatedRecordIDs: []
            )

        case .createRecord(let filenameTemplate, let contentTemplate):
            let filenameRaw = renderSkillTemplate(
                filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "skill-note-{{date}}.txt" : filenameTemplate,
                input: input,
                request: request
            )
            let filename = normalizeCreateFilename(filenameRaw)
            let content = renderSkillTemplate(contentTemplate, input: input, request: request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError.invalidData("Skill 输出内容为空，无法创建记录")
            }
            let recordID = try createTextRecord(filename: filename, text: content)
            return CLIAssistantOutput(
                reply: "Skill \(skill.name) 已创建记录：\(filename)（\(recordID)）",
                actions: ["skill.run:\(skill.id):create:\(recordID)"],
                relatedRecordIDs: [recordID]
            )

        case .appendToRecord(let recordRef, let contentTemplate):
            let renderedRef = renderSkillTemplate(
                recordRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TODAY" : recordRef,
                input: input,
                request: request
            )
            let content = renderSkillTemplate(contentTemplate, input: input, request: request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError.invalidData("Skill 追加内容为空")
            }
            let resolvedID = try resolveRecordReference(renderedRef, for: .append, request: request, createIfMissingContent: content)
            let output = try appendToRecord(recordID: resolvedID, appendText: content)
            return CLIAssistantOutput(
                reply: "Skill \(skill.name) 执行完成。\n\(output)",
                actions: ["skill.run:\(skill.id):append:\(resolvedID)"],
                relatedRecordIDs: [resolvedID]
            )
        }
    }

    func renderSkillTemplate(_ template: String, input: String, request: String) -> String {
        var output = template
        output = output.replacingOccurrences(of: "{{input}}", with: input)
        output = output.replacingOccurrences(of: "{{request}}", with: request)
        output = output.replacingOccurrences(of: "{{date}}", with: dateFilenameStamp(Date()))
        output = output.replacingOccurrences(of: "{{timestamp}}", with: skillTimestamp())
        return output
    }

    func skillTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    func replaceRecordText(recordID: String, text: String) throws -> String {
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

    func extractRecordID(_ text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange]).uppercased()
    }

    func extractRecordReference(_ text: String) -> String? {
        if let uuid = extractRecordID(text) {
            return uuid
        }

        let lower = text.lowercased()
        if lower.contains("后天") || lower.contains("day after tomorrow") {
            return "DAY_AFTER_TOMORROW"
        }
        if lower.contains("明天") || lower.contains("tomorrow") {
            return "TOMORROW"
        }
        if lower.contains("今天") || lower.contains("today") {
            return "TODAY"
        }
        if let date = resolveDateReference(in: text) {
            return dateFilenameStamp(date)
        }
        return nil
    }

    func isPlaceholderRecordReference(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let upper = value.uppercased()

        if upper.hasPrefix("<") && upper.hasSuffix(">") {
            return true
        }

        let markers = [
            "RESULT_OF_SEARCH",
            "SEARCH_RESULT",
            "RECORD_ID",
            "TARGET_RECORD",
            "ID_FROM_SEARCH",
            "FIRST_RESULT",
            "UNKNOWN"
        ]
        if markers.contains(where: { upper.contains($0) }) {
            return true
        }

        return false
    }

    func extractQuotedText(_ text: String) -> String? {
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

    func extractPayload(_ text: String) -> String {
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

    func shouldCreateRecordIntent(lowerText: String) -> Bool {
        let blockedKeywords = [
            "删除", "delete", "移除",
            "追加", "append", "补充",
            "改写", "replace", "rewrite",
            "搜索", "检索", "查找", "search", "find",
            "task.run", "run task", "运行任务", "执行任务",
            "skill.run", "run skill", "运行技能", "执行技能", "skill list", "技能列表"
        ]
        if containsAssistantKeyword(lowerText, keywords: blockedKeywords) {
            return false
        }

        let createKeywords = [
            "新建", "创建", "新增", "记录一下", "写一条", "记一条", "写个",
            "create", "new note", "new record", "capture", "log"
        ]
        if containsAssistantKeyword(lowerText, keywords: createKeywords) {
            return true
        }

        let planKeywords = ["计划", "待办", "todo", "日程", "安排", "日志", "日记", "plan", "schedule"]
        if resolveDateReference(in: lowerText) != nil && containsAssistantKeyword(lowerText, keywords: planKeywords) {
            return true
        }

        return false
    }

    func extractCreateContent(_ text: String) -> String {
        if let quoted = extractQuotedText(text) {
            return quoted
        }

        let extracted = extractPayload(text)
        if !extracted.isEmpty {
            return extracted
        }

        var cleaned = text
        let removable = [
            "请", "帮我", "帮忙", "新建", "创建", "新增", "记录一下", "写一条", "记一条", "写个",
            "create", "new note", "new record", "capture", "log",
            "今天", "明天", "后天", "today", "tomorrow", "day after tomorrow",
            "的", "一个", "一条", "一下"
        ]
        for item in removable {
            cleaned = cleaned.replacingOccurrences(of: item, with: "", options: .caseInsensitive)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    func extractCreateFilename(_ text: String) -> String? {
        let markers = ["文件名:", "filename:", "标题:", "title:", "名为", "叫做"]
        for marker in markers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                var rhs = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let cut = rhs.firstIndex(where: { $0 == "，" || $0 == "," || $0 == "。" || $0 == ";" }) {
                    rhs = rhs[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !rhs.isEmpty {
                    return normalizeCreateFilename(rhs)
                }
            }
        }
        return nil
    }

    func normalizeCreateFilename(_ raw: String) -> String {
        let cleaned = sanitizeFilename(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "note" : cleaned
        return base.contains(".") ? base : base + ".txt"
    }

    func defaultCreateFilename(for request: String, date: Date? = nil) -> String {
        let lower = request.lowercased()
        let prefix: String
        if containsAssistantKeyword(lower, keywords: ["计划", "待办", "todo", "plan", "schedule", "日程"]) {
            prefix = "plan"
        } else if containsAssistantKeyword(lower, keywords: ["日志", "日记", "log", "journal"]) {
            prefix = "journal"
        } else {
            prefix = "note"
        }

        if let date {
            return "\(prefix)-\(dateFilenameStamp(date)).txt"
        }
        if let inferred = resolveDateReference(in: request) {
            return "\(prefix)-\(dateFilenameStamp(inferred)).txt"
        }
        return timestampFilename(prefix: prefix)
    }

    func resolveDateReference(in text: String) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if lower.contains("后天") || lower.contains("day after tomorrow") {
            return calendar.date(byAdding: .day, value: 2, to: today)
        }
        if lower.contains("明天") || lower.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
        if lower.contains("今天") || lower.contains("today") {
            return today
        }

        let pattern = "(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges == 4,
              let yearRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let year = Int(text[yearRange]),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange])
        else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    func dateFilenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func dateCompactStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    func extractSearchQuery(_ text: String) -> String {
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

    func extractTaskReference(_ text: String) -> String {
        if let uuid = extractRecordID(text) {
            return uuid
        }
        if let quoted = extractQuotedText(text) {
            return quoted
        }

        let patterns = ["task:", "task:", "任务:", "task ", "task ", "任务 "]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .caseInsensitive) {
                let rhs = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rhs.isEmpty {
                    return rhs
                }
            }
        }
        return ""
    }

    func extractSkillReference(_ text: String) -> String {
        if let uuid = extractRecordID(text) {
            return uuid
        }
        if let quoted = extractQuotedText(text) {
            return quoted
        }

        let patterns = ["skill:", "技能:", "skill ", "技能 "]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .caseInsensitive) {
                let rhs = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rhs.isEmpty {
                    if let cut = rhs.firstIndex(where: { [",", "，", "。", ";", "；", ":", "："].contains(String($0)) }) {
                        return String(rhs[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return rhs
                }
            }
        }
        return ""
    }

    func containsAssistantKeyword(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { keyword in
            text.range(of: keyword, options: .caseInsensitive) != nil
        }
    }

    func minimalAssistantClarifyQuestion(for request: String) -> String? {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let recordReference = extractRecordReference(text)
        let payload = extractPayload(text)
        let createContent = extractCreateContent(text)
        let taskRef = extractTaskReference(text)
        let skillRef = extractSkillReference(text)

        if shouldCreateRecordIntent(lowerText: lower), createContent.isEmpty {
            return "请提供要写入新记录的内容，例如：为明天新建计划：<内容>。"
        }

        let deleteKeywords = ["删除", "delete", "移除"]
        if containsAssistantKeyword(lower, keywords: deleteKeywords), recordReference == nil {
            return "请提供要删除的记录 ID（UUID 或 TODAY/明天），例如：删除记录 <record-id>。"
        }

        let appendKeywords = ["追加", "append", "补充"]
        if containsAssistantKeyword(lower, keywords: appendKeywords) {
            if recordReference == nil && payload.isEmpty {
                return "请补充目标记录引用和追加内容，例如：向 TODAY 追加：<内容>。"
            }
            if recordReference == nil {
                return "请提供要追加内容的记录 ID（UUID 或 TODAY/明天）。"
            }
            if payload.isEmpty {
                return "请提供要追加的内容，例如：向 \(recordReference ?? "TODAY") 追加：<内容>。"
            }
        }

        let replaceKeywords = ["改写", "replace", "rewrite", "编辑", "更新"]
        if containsAssistantKeyword(lower, keywords: replaceKeywords) {
            if recordReference == nil && payload.isEmpty {
                return "请补充目标记录引用和改写后的内容，例如：把 TODAY 改写为：<内容>。"
            }
            if recordReference == nil {
                return "请提供要改写的记录 ID（UUID 或 TODAY/明天）。"
            }
            if payload.isEmpty {
                return "请提供改写后的内容，例如：把 \(recordReference ?? "TODAY") 改写为：<内容>。"
            }
        }

        let taskKeywords = ["task.run", "run task", "运行任务", "执行任务", "运行任务", "执行任务"]
        if containsAssistantKeyword(lower, keywords: taskKeywords), taskRef.isEmpty {
            return "请提供要运行的 任务 ID 或任务名，例如：运行任务 <task-id>。"
        }

        let skillKeywords = ["skill.run", "run skill", "执行skill", "运行skill", "执行技能", "运行技能", "调用skill", "使用skill"]
        if containsAssistantKeyword(lower, keywords: skillKeywords), skillRef.isEmpty {
            return "请提供要运行的 Skill ID 或名称，例如：运行 skill:daily-standup。"
        }

        return nil
    }

    func requestTokens(_ text: String) -> [String] {
        let parts = text.lowercased().split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_")
        }
        let tokens = parts.map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return [text.lowercased()] }
        return Array(tokens.prefix(12))
    }

    func scoreText(_ text: String, tokens: [String]) -> Int {
        let haystack = text.lowercased()
        return tokens.reduce(0) { partial, token in
            haystack.contains(token) ? partial + min(token.count, 8) : partial
        }
    }

    func parseAssistantMergeStrategy(from request: String) -> CLIAssistantCoreMergeStrategy? {
        let pattern = "(?i)#merge\\s*[:：]\\s*(overwrite|keep|version|versioned|覆盖|保留|版本)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: request.utf16.count)
        guard let match = regex.firstMatch(in: request, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: request)
        else {
            return nil
        }
        let raw = String(request[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "overwrite", "覆盖":
            return .overwrite
        case "keep", "保留":
            return .keep
        case "version", "versioned", "版本":
            return .versioned
        default:
            return nil
        }
    }

    func resolveAssistantMergeStrategy(
        explicit: CLIAssistantCoreMergeStrategy?,
        conflict: CLIAssistantCoreConflict?
    ) -> CLIAssistantCoreMergeStrategy {
        if let explicit { return explicit }
        if conflict != nil { return .versioned }
        return .versioned
    }

    func detectAssistantCoreConflict(
        request: String,
        reply: String,
        coreContext: [CLIAssistantContextItem]
    ) -> CLIAssistantCoreConflict? {
        let requestTokens = normalizedAssistantTokenSet(request)
        let replyTokens = normalizedAssistantTokenSet(reply)
        guard !requestTokens.isEmpty, !replyTokens.isEmpty else { return nil }

        var best: CLIAssistantCoreConflict?
        for item in coreContext.prefix(12) {
            let oldRequest = extractAssistantMarkdownSection("Request", in: item.snippet) ?? item.filename
            let oldReply = extractAssistantMarkdownSection("Decision / Reply", in: item.snippet)
                ?? extractAssistantMarkdownSection("Reply", in: item.snippet)
                ?? item.snippet

            let requestSimilarity = assistantJaccardSimilarity(requestTokens, normalizedAssistantTokenSet(oldRequest))
            let replySimilarity = assistantJaccardSimilarity(replyTokens, normalizedAssistantTokenSet(oldReply))
            let score = requestSimilarity * (1 - replySimilarity)

            guard requestSimilarity >= 0.34, replySimilarity <= 0.62, score >= 0.22 else { continue }
            if let current = best {
                if score > current.score {
                    best = CLIAssistantCoreConflict(recordID: item.id, score: score)
                }
            } else {
                best = CLIAssistantCoreConflict(recordID: item.id, score: score)
            }
        }

        return best
    }

    func extractAssistantMarkdownSection(_ title: String, in markdown: String) -> String? {
        let marker = "## \(title)"
        guard let start = markdown.range(of: marker) else { return nil }
        let tail = String(markdown[start.upperBound...])
        let raw = tail.components(separatedBy: "\n## ").first ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func normalizedAssistantTokenSet(_ text: String, maxTokens: Int = 64) -> Set<String> {
        let parts = text.lowercased().split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_")
        }
        let tokens = parts.map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return [] }
        return Set(tokens.prefix(maxTokens))
    }

    func assistantJaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    func appendAssistantNotice(_ base: String, _ notice: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotice = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotice.isEmpty else { return trimmedBase }
        guard !trimmedBase.isEmpty else { return trimmedNotice }
        return "\(trimmedBase)\n\n\(trimmedNotice)"
    }

    func normalizeTagName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func shouldPersistAssistantCoreMemory(
        request: String,
        reply: String,
        actions: [String],
        relatedRecordIDs: [String],
        confirmationRequired: Bool,
        succeeded: Bool,
        explicitMergeStrategy: CLIAssistantCoreMergeStrategy?
    ) -> Bool {
        if explicitMergeStrategy != nil {
            return true
        }
        guard succeeded, !confirmationRequired else {
            return false
        }

        let lower = request.lowercased()
        let memoryKeywords = [
            "记住", "记下来", "沉淀", "长期", "偏好", "习惯", "约定", "原则", "目标", "复盘", "结论",
            "remember", "preference", "habit", "rule", "goal", "decision", "key point"
        ]
        if containsAssistantKeyword(lower, keywords: memoryKeywords) {
            return true
        }

        if actions.contains(where: isAssistantCoreActionWorthPersisting) {
            return true
        }

        let normalizedReply = shortText(reply, limit: 240).lowercased()
        if (normalizedReply.contains("结论") || normalizedReply.contains("decision")) && !relatedRecordIDs.isEmpty {
            return true
        }

        return false
    }

    func isAssistantCoreActionWorthPersisting(_ action: String) -> Bool {
        if action.hasPrefix("record.create:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.append:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.replace:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.delete:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("task.run:") && (action.hasSuffix(":ok") || action.hasSuffix(":success")) { return true }
        if action.hasPrefix("skill.run:") && (action.contains(":create:") || action.contains(":append:")) { return true }
        return false
    }

    func appendAssistantDailyRecord(tagID: String, prefix: String, entry: String) throws -> String {
        let filename = "\(prefix)-\(dateFilenameStamp(Date())).txt"
        let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingID = try findAssistantDailyRecordID(tagID: tagID, filename: filename) {
            let rows = try db.query(
                "SELECT file_path, file_type FROM records WHERE id = ? LIMIT 1",
                bindings: [.text(existingID)]
            )
            guard let row = rows.first,
                  let relativePath = row["file_path"]?.stringValue,
                  let fileType = row["file_type"]?.stringValue,
                  ["text", "web", "log"].contains(fileType) else {
                return existingID
            }
            let current = (try? readText(relativePath: relativePath, maxBytes: 2_000_000)) ?? ""
            let merged = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? trimmedEntry
                : current + "\n\n---\n\n" + trimmedEntry
            _ = try replaceRecordText(recordID: existingID, text: merged)
            return existingID
        }

        return try createTextRecord(
            filename: filename,
            text: trimmedEntry,
            tags: [tagID]
        )
    }

    func findAssistantDailyRecordID(tagID: String, filename: String) throws -> String? {
        let rows = try db.query(
            """
            SELECT r.id
            FROM records r
            JOIN record_tags rt ON rt.record_id = r.id
            WHERE rt.tag_id = ? AND r.is_archived = 0 AND lower(r.filename) = lower(?)
            ORDER BY r.updated_at DESC
            LIMIT 1
            """,
            bindings: [.text(tagID), .text(filename)]
        )
        return rows.first?["id"]?.stringValue
    }

    func buildAssistantCoreMemoryText(
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
        coreContextRecordIDs: [String],
        mergeStrategy: String,
        conflictRecordID: String?,
        conflictScore: Double?
    ) -> String {
        let keyActions = actions.filter(isAssistantCoreActionWorthPersisting)
        let actionRows = keyActions.isEmpty ? "- (none)" : keyActions.prefix(6).map { "- \($0)" }.joined(separator: "\n")
        let relatedRows = relatedRecordIDs.isEmpty ? "- (none)" : relatedRecordIDs.prefix(8).map { "- \($0)" }.joined(separator: "\n")
        let planRows = toolPlan.isEmpty ? "- (none)" : toolPlan.prefix(5).map { "- \($0)" }.joined(separator: "\n")

        return """
        # Core Memory Entry
        at: \(iso8601Now())
        request_id: \(requestID)
        source: \(source)
        intent: \(intent)
        planner_source: \(plannerSource)
        planner_note: \(plannerNote ?? "-")
        merge_strategy: \(mergeStrategy)
        confirmation_required: \(confirmationRequired ? "yes" : "no")
        conflict_ref: \(conflictRecordID ?? "-")
        conflict_score: \(conflictScore.map { String(format: "%.2f", $0) } ?? "-")

        ## Key Request
        \(shortText(request, limit: 180))

        ## Key Reply
        \(shortText(reply, limit: 260))

        ## Tool Plan
        \(planRows)

        ## Key Actions
        \(actionRows)

        ## Related Records
        \(relatedRows)

        ## Context Size
        \(coreContextRecordIDs.count)
        """
    }

    func buildAssistantAuditText(
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
        confirmationExpiresAt: Date?,
        mergeStrategy: String,
        conflictRecordID: String?,
        conflictScore: Double?
    ) -> String {
        let actionRows = actions.isEmpty ? "- (none)" : actions.prefix(14).map { "- \($0)" }.joined(separator: "\n")
        let relatedRows = relatedRecordIDs.isEmpty ? "- (none)" : relatedRecordIDs.prefix(10).map { "- \($0)" }.joined(separator: "\n")
        let contextRows = coreContextRecordIDs.isEmpty ? "- (none)" : coreContextRecordIDs.prefix(10).map { "- \($0)" }.joined(separator: "\n")
        let status = actions.contains(where: { $0.hasPrefix("error:") }) ? "failed" : "ok"

        return """
        # Assistant Audit Entry
        request_id: \(requestID)
        status: \(status)
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
        merge_strategy: \(mergeStrategy)
        conflict_record_id: \(conflictRecordID ?? "-")
        conflict_score: \(conflictScore.map { String(format: "%.2f", $0) } ?? "-")
        core_memory_record_id: \(coreMemoryRecordID ?? "-")

        ## Request
        \(shortText(request, limit: 280))

        ## Reply
        \(shortText(reply, limit: 360))

        ## Tool Plan
        \(toolPlan.isEmpty ? "- (none)" : toolPlan.prefix(8).map { "- \($0)" }.joined(separator: "\n"))

        ## Actions
        \(actionRows)

        ## Related Records
        \(relatedRows)

        ## Core Context Records
        \(contextRows)
        """
    }

}
