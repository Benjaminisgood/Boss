import Foundation

// MARK: - EventService (事件触发服务)
final class EventService {
    static let shared = EventService()

    private let agentRepo = AgentRepository()
    private let scheduler = SchedulerService.shared

    private init() {}

    // MARK: - Record Events
    func triggerOnRecordCreate(record: Record) {
        Task {
            await triggerEvents(for: .onRecordCreate, record: record)
        }
    }

    func triggerOnRecordUpdate(record: Record) {
        Task {
            await triggerEvents(for: .onRecordUpdate, record: record)
        }
    }

    // MARK: - Event Triggering
    private enum RecordEvent { case onRecordCreate, onRecordUpdate }

    private func triggerEvents(for event: RecordEvent, record: Record) async {
        guard let tasks = try? agentRepo.fetchAllTasks() else { return }

        for task in tasks where task.isEnabled {
            switch task.trigger {
            case .onRecordCreate(let tagFilter):
                if event == .onRecordCreate && (tagFilter.isEmpty || record.tags.contains(where: { tagFilter.contains($0) })) {
                    await runTask(task, record: record)
                }
            case .onRecordUpdate(let tagFilter):
                if event == .onRecordUpdate && (tagFilter.isEmpty || record.tags.contains(where: { tagFilter.contains($0) })) {
                    await runTask(task, record: record)
                }
            default:
                continue
            }
        }
    }

    // MARK: - Task Execution
    private func runTask(_ task: AgentTask, record: Record) async {
        _ = await scheduler.run(task: task)
        // 可以在这里添加额外的处理逻辑，比如将结果写入记录等
    }
}

// MARK: - Assistant Kernel
struct AssistantKernelResult {
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

final class AssistantKernelService {
    static let shared = AssistantKernelService()

    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
    private let coreTagPrimaryName = "Core"
    private let coreTagAliases = ["持久记忆", "core memory", "memory core"]
    private let auditTagPrimaryName = "AuditLog"
    private let auditTagAliases = ["audit", "audit log", "审计"]
    private let confirmationTTL: TimeInterval = 5 * 60
    private let confirmationStore = ConfirmationStore()

    private init() {}

    func handle(request rawRequest: String, source: String = "user") async -> AssistantKernelResult {
        let request = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = Date()
        let requestID = UUID().uuidString

        guard !request.isEmpty else {
            let finishedAt = Date()
            return AssistantKernelResult(
                requestID: requestID,
                source: source,
                request: request,
                intent: "empty",
                plannerSource: "rule",
                plannerNote: "请求为空",
                toolPlan: [],
                confirmationRequired: false,
                confirmationToken: nil,
                confirmationExpiresAt: nil,
                reply: "请输入要执行的任务描述。",
                actions: [],
                relatedRecordIDs: [],
                coreContextRecordIDs: [],
                coreMemoryRecordID: nil,
                auditRecordID: nil,
                startedAt: startedAt,
                finishedAt: finishedAt,
                succeeded: false
            )
        }

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
            let coreTag = try ensureTag(
                primaryName: coreTagPrimaryName,
                aliases: coreTagAliases,
                color: "#0A84FF",
                icon: "brain.head.profile"
            )
            let auditTag = try ensureTag(
                primaryName: auditTagPrimaryName,
                aliases: auditTagAliases,
                color: "#FF9F0A",
                icon: "doc.text.magnifyingglass"
            )
            actions.append("tag.ensure:\(coreTag.name)")
            actions.append("tag.ensure:\(auditTag.name)")

            let coreContext = try loadCoreContext(coreTagID: coreTag.id, request: request)
            coreContextRecordIDs = coreContext.map { $0.record.id }
            actions.append("context.load:\(coreContext.count)")

            let confirmationAttempt = await consumeConfirmationIntentIfProvided(request: request, source: source)
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
                let intent: Intent

                if let confirmedIntent {
                    intent = confirmedIntent
                    intentDescription = "\(confirmedIntent.description) [confirmed]"
                    plannerSource = "confirmation-token"
                    plannerNote = "已使用确认令牌执行高风险动作。"
                    toolPlan = defaultToolPlan(for: confirmedIntent)
                    if let token = confirmationAttempt.token {
                        actions.append("confirm.consume:\(token)")
                    }
                } else {
                    let planned = await planIntent(request: request, coreContext: coreContext)
                    intent = planned.intent
                    intentDescription = planned.intent.description
                    plannerSource = planned.plannerSource
                    plannerNote = planned.plannerNote
                    toolPlan = planned.toolPlan
                    actions.append("plan:\(plannerSource)")
                }

                if intent.requiresConfirmation && confirmedIntent == nil {
                    let pending = await savePendingConfirmation(intent: intent, request: request, source: source, toolPlan: toolPlan)
                    confirmationRequired = true
                    confirmationToken = pending.token
                    confirmationExpiresAt = pending.expiresAt
                    relatedRecordIDs = intent.relatedRecordIDs
                    reply = buildConfirmationReply(intent: intent, token: pending.token, expiresAt: pending.expiresAt)
                    actions.append("confirm.required:\(pending.token)")
                    succeeded = true
                } else {
                    let output = try execute(intent: intent, originalRequest: request, coreContext: coreContext)
                    reply = output.reply
                    actions.append(contentsOf: output.actions)
                    relatedRecordIDs = output.relatedRecordIDs
                    succeeded = true
                }
            }

            let memoryText = buildCoreMemoryText(
                requestID: requestID,
                source: source,
                request: request,
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
            let memoryRecord = try recordRepo.createTextRecord(
                text: memoryText,
                filename: timestampFilename(prefix: "assistant-core"),
                tags: [coreTag.id],
                visibility: .private
            )
            coreMemoryRecordID = memoryRecord.id
            actions.append("memory.write:\(memoryRecord.id)")

            let finishedAt = Date()
            let auditText = buildAuditText(
                requestID: requestID,
                source: source,
                request: request,
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
            let auditRecord = try recordRepo.createTextRecord(
                text: auditText,
                filename: timestampFilename(prefix: "assistant-audit"),
                tags: [auditTag.id],
                visibility: .private
            )
            auditRecordID = auditRecord.id
            actions.append("audit.write:\(auditRecord.id)")
        } catch {
            reply = "执行失败：\(error.localizedDescription)"
            actions.append("error:\(error.localizedDescription)")
            let finishedAt = Date()
            do {
                let auditTag = try ensureTag(
                    primaryName: auditTagPrimaryName,
                    aliases: auditTagAliases,
                    color: "#FF9F0A",
                    icon: "doc.text.magnifyingglass"
                )
                let failureAudit = buildAuditText(
                    requestID: requestID,
                    source: source,
                    request: request,
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
                if let audit = try? recordRepo.createTextRecord(
                    text: failureAudit,
                    filename: timestampFilename(prefix: "assistant-audit-failed"),
                    tags: [auditTag.id],
                    visibility: .private
                ) {
                    auditRecordID = audit.id
                }
            } catch {
                // ignore audit failure
            }
        }

        let finishedAt = Date()
        return AssistantKernelResult(
            requestID: requestID,
            source: source,
            request: request,
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
            finishedAt: finishedAt,
            succeeded: succeeded
        )
    }

    private struct ActionOutput {
        let reply: String
        let actions: [String]
        let relatedRecordIDs: [String]
    }

    private struct CoreContextItem {
        let record: Record
        let snippet: String
        let score: Int
    }

    private struct PlannedIntent {
        let intent: Intent
        let plannerSource: String
        let plannerNote: String?
        let toolPlan: [String]
    }

    private struct PendingConfirmation {
        let intent: Intent
        let source: String
        let request: String
        let toolPlan: [String]
        let createdAt: Date
        let expiresAt: Date
    }

    private actor ConfirmationStore {
        private var store: [String: PendingConfirmation] = [:]

        func save(token: String, pending: PendingConfirmation) {
            cleanupExpired()
            store[token] = pending
        }

        func consume(token: String, source: String) -> PendingConfirmation? {
            cleanupExpired()
            guard let pending = store[token] else { return nil }
            if !pending.source.isEmpty && pending.source != source {
                return nil
            }
            store[token] = nil
            return pending
        }

        private func cleanupExpired() {
            let now = Date()
            store = store.filter { _, pending in
                pending.expiresAt > now
            }
        }
    }

    private enum LLMProvider: String {
        case claude
        case openai
        case aliyun
    }

    private enum PlannerError: LocalizedError {
        case missingAPIKey(provider: String)
        case invalidResponse
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "Missing \(provider) API key"
            case .invalidResponse:
                return "Planner response invalid"
            case .apiError(let message):
                return message
            }
        }
    }

    private enum Intent {
        case help
        case summarizeCore
        case search(query: String)
        case delete(recordID: String)
        case append(recordID: String, content: String)
        case replace(recordID: String, content: String)
        case unknown(query: String)

        var description: String {
            switch self {
            case .help: return "help"
            case .summarizeCore: return "summarizeCore"
            case .search(let query): return "search(\(query))"
            case .delete(let recordID): return "delete(\(recordID))"
            case .append(let recordID, _): return "append(\(recordID))"
            case .replace(let recordID, _): return "replace(\(recordID))"
            case .unknown(let query): return "unknown(\(query))"
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
            case .delete(let recordID):
                return [recordID]
            case .append(let recordID, _):
                return [recordID]
            case .replace(let recordID, _):
                return [recordID]
            default:
                return []
            }
        }
    }

    private func parseIntent(_ request: String) -> Intent {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let recordID = extractRecordID(text)
        let payload = extractPayload(text)

        if lower.contains("help") || lower.contains("帮助") || lower.contains("你能做什么") {
            return .help
        }

        if lower.contains("总结") || lower.contains("回顾") || lower.contains("summarize core") || lower.contains("core memory") {
            return .summarizeCore
        }

        if let recordID, lower.contains("删除") || lower.contains("delete") || lower.contains("移除") {
            return .delete(recordID: recordID)
        }

        if let recordID, !payload.isEmpty, (lower.contains("追加") || lower.contains("append") || lower.contains("补充")) {
            return .append(recordID: recordID, content: payload)
        }

        if let recordID, !payload.isEmpty, (lower.contains("编辑") || lower.contains("更新") || lower.contains("改写") || lower.contains("replace") || lower.contains("rewrite")) {
            return .replace(recordID: recordID, content: payload)
        }

        if lower.contains("搜索") || lower.contains("检索") || lower.contains("查找") || lower.contains("search") || lower.contains("find") {
            let query = extractSearchQuery(text)
            return .search(query: query)
        }

        return .unknown(query: text)
    }

    private func planIntent(request: String, coreContext: [CoreContextItem]) async -> PlannedIntent {
        do {
            if let planned = try await planIntentWithLLM(request: request, coreContext: coreContext) {
                return planned
            }
        } catch {
            // fallback below
        }

        let intent = parseIntent(request)
        return PlannedIntent(
            intent: intent,
            plannerSource: "rule",
            plannerNote: "使用规则解析器（LLM 规划不可用或无结果）。",
            toolPlan: defaultToolPlan(for: intent)
        )
    }

    private func planIntentWithLLM(request: String, coreContext: [CoreContextItem]) async throws -> PlannedIntent? {
        let modelIdentifier = normalizedPlannerModelIdentifier(AppConfig.shared.claudeModel)
        let contextRows = coreContext.prefix(6).map { item in
            "[\(item.record.id)] \(item.record.content.filename): \(shortText(item.snippet, limit: 220))"
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

        let raw = try await callLLMAPI(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
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

        let intent: Intent
        switch rawIntent {
        case "help":
            intent = .help
        case "summarizecore", "summarize_core":
            intent = .summarizeCore
        case "search":
            intent = .search(query: query.isEmpty ? extractSearchQuery(request) : query)
        case "delete":
            let resolvedID = recordID.isEmpty ? (extractRecordID(request) ?? "") : recordID
            guard !resolvedID.isEmpty else { return nil }
            intent = .delete(recordID: resolvedID.uppercased())
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
            intent = .unknown(query: request)
        default:
            return nil
        }

        return PlannedIntent(
            intent: intent,
            plannerSource: "llm:\(modelIdentifier)",
            plannerNote: note.isEmpty ? nil : note,
            toolPlan: toolPlan.isEmpty ? defaultToolPlan(for: intent) : toolPlan
        )
    }

    private func defaultToolPlan(for intent: Intent) -> [String] {
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

    private func consumeConfirmationIntentIfProvided(request: String, source: String) async -> (token: String?, intent: Intent?) {
        guard let token = extractConfirmationToken(request) else {
            return (nil, nil)
        }
        let pending = await confirmationStore.consume(token: token, source: source)
        return (token, pending?.intent)
    }

    private func savePendingConfirmation(intent: Intent, request: String, source: String, toolPlan: [String]) async -> (token: String, expiresAt: Date) {
        let token = generateConfirmationToken()
        let now = Date()
        let expiresAt = now.addingTimeInterval(confirmationTTL)
        let pending = PendingConfirmation(
            intent: intent,
            source: source,
            request: request,
            toolPlan: toolPlan,
            createdAt: now,
            expiresAt: expiresAt
        )
        await confirmationStore.save(token: token, pending: pending)
        return (token, expiresAt)
    }

    private func buildConfirmationReply(intent: Intent, token: String, expiresAt: Date) -> String {
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
        """
    }

    private func extractConfirmationToken(_ text: String) -> String? {
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

    private func generateConfirmationToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }

    private func normalizedPlannerModelIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AppConfig.defaultLLMModelID }
        if trimmed.contains(":") { return trimmed }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return "openai:\(trimmed)"
        }
        if lower.hasPrefix("qwen") {
            return "aliyun:\(trimmed)"
        }
        return "claude:\(trimmed)"
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

    private func callLLMAPI(system: String, userPrompt: String, modelIdentifier: String) async throws -> String {
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

    private func callClaude(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.claudeAPIKey
        guard !apiKey.isEmpty else {
            throw PlannerError.missingAPIKey(provider: "Claude")
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
                "max_tokens": 800
            ]
        )

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw PlannerError.invalidResponse
        }

        let texts = content.compactMap { item in
            item["text"] as? String
        }
        guard !texts.isEmpty else {
            throw PlannerError.invalidResponse
        }
        return texts.joined(separator: "\n")
    }

    private func callOpenAI(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw PlannerError.missingAPIKey(provider: "OpenAI")
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
                "temperature": 0.2
            ]
        )

        return try parseOpenAICompatibleText(data)
    }

    private func callAliyun(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.aliyunAPIKey
        guard !apiKey.isEmpty else {
            throw PlannerError.missingAPIKey(provider: "阿里云")
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
                "temperature": 0.2
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
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PlannerError.apiError(message)
        }
        return data
    }

    private func parseOpenAICompatibleText(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw PlannerError.invalidResponse
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

        throw PlannerError.invalidResponse
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        guard start <= end else { return nil }
        return String(text[start...end])
    }

    private func execute(intent: Intent, originalRequest: String, coreContext: [CoreContextItem]) throws -> ActionOutput {
        switch intent {
        case .help:
            let reply = """
            我可以处理这些操作：
            1. 检索：例如“搜索 Swift 并发”
            2. 删除记录：例如“删除记录 <record-id>”
            3. 追加内容：例如“向 <record-id> 追加：<内容>”
            4. 覆写内容：例如“把 <record-id> 改写为：<内容>”
            5. 总结 Core：例如“总结 Core 记忆”
            """
            return ActionOutput(reply: reply, actions: ["intent.help"], relatedRecordIDs: [])

        case .summarizeCore:
            if coreContext.isEmpty {
                return ActionOutput(
                    reply: "当前没有命中 Core 记忆记录，建议先沉淀关键项目结论到 Core 标签。",
                    actions: ["core.summarize:empty"],
                    relatedRecordIDs: []
                )
            }
            let rows = coreContext.prefix(8).map { item in
                "- [\(item.record.id)] \(item.record.content.filename): \(shortText(item.snippet, limit: 120))"
            }.joined(separator: "\n")
            return ActionOutput(
                reply: "基于 Core 记忆的简要回顾：\n\(rows)",
                actions: ["core.summarize:\(coreContext.count)"],
                relatedRecordIDs: coreContext.map { $0.record.id }
            )

        case .search(let query):
            let records = try searchRecords(query: query, limit: 10)
            if records.isEmpty {
                return ActionOutput(
                    reply: "没有检索到与“\(query)”相关的记录。",
                    actions: ["record.search:\(query):0"],
                    relatedRecordIDs: []
                )
            }
            let lines = records.map {
                "- [\($0.id)] \($0.content.filename): \(shortText($0.preview, limit: 100))"
            }.joined(separator: "\n")
            return ActionOutput(
                reply: "检索“\(query)”命中 \(records.count) 条：\n\(lines)",
                actions: ["record.search:\(query):\(records.count)"],
                relatedRecordIDs: records.map { $0.id }
            )

        case .delete(let recordID):
            guard let record = try recordRepo.fetchByID(recordID) else {
                return ActionOutput(
                    reply: "未找到记录：\(recordID)",
                    actions: ["record.delete:\(recordID):not_found"],
                    relatedRecordIDs: []
                )
            }
            try recordRepo.delete(id: recordID)
            return ActionOutput(
                reply: "已删除记录：\(record.content.filename)（\(recordID)）",
                actions: ["record.delete:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .append(let recordID, let content):
            guard let record = try recordRepo.fetchByID(recordID) else {
                return ActionOutput(
                    reply: "未找到记录：\(recordID)",
                    actions: ["record.append:\(recordID):not_found"],
                    relatedRecordIDs: []
                )
            }
            guard record.content.fileType.isTextLike else {
                return ActionOutput(
                    reply: "记录不是文本类型，无法追加：\(recordID)",
                    actions: ["record.append:\(recordID):not_text"],
                    relatedRecordIDs: [recordID]
                )
            }
            let current = try recordRepo.loadTextContent(record: record)
            let merged = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? content
                : current + "\n\n---\n\n" + content
            _ = try recordRepo.updateTextContent(recordID: recordID, text: merged)
            return ActionOutput(
                reply: "已向记录 \(recordID) 追加内容。",
                actions: ["record.append:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .replace(let recordID, let content):
            guard let record = try recordRepo.fetchByID(recordID) else {
                return ActionOutput(
                    reply: "未找到记录：\(recordID)",
                    actions: ["record.replace:\(recordID):not_found"],
                    relatedRecordIDs: []
                )
            }
            guard record.content.fileType.isTextLike else {
                return ActionOutput(
                    reply: "记录不是文本类型，无法改写：\(recordID)",
                    actions: ["record.replace:\(recordID):not_text"],
                    relatedRecordIDs: [recordID]
                )
            }
            _ = try recordRepo.updateTextContent(recordID: recordID, text: content)
            return ActionOutput(
                reply: "已改写记录 \(recordID) 的文本内容。",
                actions: ["record.replace:\(recordID):ok"],
                relatedRecordIDs: [recordID]
            )

        case .unknown(let query):
            let records = try searchRecords(query: query, limit: 5)
            if records.isEmpty {
                let coreHint = coreContext.prefix(5).map { "- [\($0.record.id)] \(shortText($0.snippet, limit: 90))" }.joined(separator: "\n")
                let suffix = coreHint.isEmpty ? "" : "\n可参考 Core 上下文：\n\(coreHint)"
                return ActionOutput(
                    reply: "我暂时无法直接执行该指令，已尝试检索但未命中。请明确“搜索/删除/追加/改写”的目标记录。\(suffix)",
                    actions: ["intent.unknown:\(query)", "record.search.fallback:0"],
                    relatedRecordIDs: coreContext.map { $0.record.id }
                )
            }
            let lines = records.map { "- [\($0.id)] \($0.content.filename): \(shortText($0.preview, limit: 90))" }.joined(separator: "\n")
            return ActionOutput(
                reply: "我先按检索理解你的需求，命中这些记录：\n\(lines)\n\n如果你要我继续执行，请补充“删除/追加/改写 + 记录ID + 内容”。",
                actions: ["intent.unknown:\(query)", "record.search.fallback:\(records.count)"],
                relatedRecordIDs: records.map { $0.id }
            )
        }
    }

    private func searchRecords(query: String, limit: Int) throws -> [Record] {
        var filter = RecordFilter()
        filter.searchText = query
        let result = try recordRepo.fetchAll(filter: filter)
        return Array(result.prefix(limit))
    }

    private func loadCoreContext(coreTagID: String, request: String, limit: Int = 20) throws -> [CoreContextItem] {
        var filter = RecordFilter()
        filter.tagIDs = [coreTagID]
        filter.tagMatchAny = true
        let records = try recordRepo.fetchAll(filter: filter)
        guard !records.isEmpty else { return [] }

        let tokens = queryTokens(from: request)
        let items: [CoreContextItem] = records.map { record in
            let snippet: String
            if record.content.fileType.isTextLike {
                let loaded = (try? recordRepo.loadTextContent(record: record, maxBytes: 120_000)) ?? ""
                snippet = loaded.isEmpty ? record.preview : loaded
            } else {
                snippet = record.preview
            }
            let score = relevanceScore(text: "\(record.content.filename) \(record.preview) \(snippet)", tokens: tokens)
            return CoreContextItem(record: record, snippet: snippet, score: score)
        }

        return items
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.record.updatedAt > rhs.record.updatedAt
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func ensureTag(primaryName: String, aliases: [String], color: String, icon: String) throws -> Tag {
        let allTags = try tagRepo.fetchAll()
        let candidateNames = Set(([primaryName] + aliases).map { normalizeTagName($0) })
        if let existed = allTags.first(where: { candidateNames.contains(normalizeTagName($0.name)) }) {
            return existed
        }
        let tag = Tag(name: primaryName, color: color, icon: icon)
        try tagRepo.create(tag)
        return tag
    }

    private func normalizeTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func extractRecordID(_ text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange]).uppercased()
    }

    private func extractQuotedText(_ text: String) -> String? {
        let patterns = [
            "\\\"([^\\\"]+)\\\"",
            "“([^”]+)”",
            "「([^」]+)」"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { continue }
            guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let result = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
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
        var result = text
        for keyword in keywords {
            result = result.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
        }
        result = result.replacingOccurrences(of: "记录", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    private func queryTokens(from text: String) -> [String] {
        let parts = text.lowercased().split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_")
        }
        let tokens = parts.map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return [text.lowercased()] }
        return Array(tokens.prefix(12))
    }

    private func relevanceScore(text: String, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let haystack = text.lowercased()
        return tokens.reduce(0) { score, token in
            haystack.contains(token) ? score + min(token.count, 8) : score
        }
    }

    private func buildCoreMemoryText(
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

    private func buildAuditText(
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

    private func shortText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let idx = normalized.index(normalized.startIndex, offsetBy: max(1, limit - 1))
        return String(normalized[..<idx]) + "…"
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
}
