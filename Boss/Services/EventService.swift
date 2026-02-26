import Foundation

// MARK: - EventService (事件触发服务)
final class EventService {
    static let shared = EventService()

    private let taskRepo = TaskRepository()
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
        guard let tasks = try? taskRepo.fetchAllTasks() else { return }

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
    private func runTask(_ task: TaskItem, record: Record) async {
        let reason: String
        switch task.trigger {
        case .onRecordCreate:
            reason = "event.record.create"
        case .onRecordUpdate:
            reason = "event.record.update"
        default:
            reason = "event.record"
        }
        _ = await scheduler.run(task: task, triggerReason: reason, eventRecord: record)
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

struct BossInterfaceSpec: Codable, Hashable {
    let name: String
    let category: String
    let summary: String
    let inputSchema: String
    let outputSchema: String
    let riskLevel: String
}

enum BossInterfaceCatalog {
    static let specs: [BossInterfaceSpec] = [
        .init(
            name: "record.search",
            category: "records",
            summary: "全文检索并返回记录列表（ID、文件名、预览）",
            inputSchema: "{ query: string, limit?: int }",
            outputSchema: "{ records: [{ id, filename, preview, updated_at }] }",
            riskLevel: "low"
        ),
        .init(
            name: "record.create",
            category: "records",
            summary: "创建文本记录",
            inputSchema: "{ filename: string, content: string, tags?: [string] }",
            outputSchema: "{ record_id: string }",
            riskLevel: "medium"
        ),
        .init(
            name: "record.append",
            category: "records",
            summary: "追加文本到指定记录",
            inputSchema: "{ record_id: string, content: string }",
            outputSchema: "{ record_id: string, updated: bool }",
            riskLevel: "medium"
        ),
        .init(
            name: "record.replace",
            category: "records",
            summary: "覆盖指定文本记录内容",
            inputSchema: "{ record_id: string, content: string }",
            outputSchema: "{ record_id: string, updated: bool }",
            riskLevel: "high"
        ),
        .init(
            name: "record.delete",
            category: "records",
            summary: "删除指定记录",
            inputSchema: "{ record_id: string }",
            outputSchema: "{ record_id: string, deleted: bool }",
            riskLevel: "high"
        ),
        .init(
            name: "task.run",
            category: "tasks",
            summary: "执行预设任务（由外部 Runtime 发起）",
            inputSchema: "{ task_ref: string }",
            outputSchema: "{ status: string, output: string }",
            riskLevel: "high"
        ),
        .init(
            name: "skill.run",
            category: "skills",
            summary: "执行 Skill（Skill 自身定义了会访问的 Boss 数据）",
            inputSchema: "{ skill_ref: string, input?: string }",
            outputSchema: "{ status: string, actions: [string], related_record_ids: [string] }",
            riskLevel: "medium"
        ),
        .init(
            name: "skills.catalog",
            category: "skills",
            summary: "读取 Skill 清单及说明",
            inputSchema: "{}",
            outputSchema: "{ manifest_markdown: string }",
            riskLevel: "low"
        )
    ]

    static func markdownTable() -> String {
        let header = """
        | 接口 | 分类 | 风险 | 输入 | 输出 | 说明 |
        | --- | --- | --- | --- | --- | --- |
        """
        let rows = specs.map { spec in
            "| \(spec.name) | \(spec.category) | \(spec.riskLevel) | `\(spec.inputSchema)` | `\(spec.outputSchema)` | \(spec.summary) |"
        }.joined(separator: "\n")
        return "\(header)\n\(rows)"
    }
}

final class AssistantKernelService {
    static let shared = AssistantKernelService()

    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
    private let taskRepo = TaskRepository()
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
                intent: "conversation.empty",
                plannerSource: "rag-core",
                plannerNote: "请求为空",
                toolPlan: ["collect-request"],
                confirmationRequired: false,
                confirmationToken: nil,
                confirmationExpiresAt: nil,
                reply: "请输入你想讨论的问题或上下文。",
                actions: ["assistant.mode:conversation-only", "assistant.error:empty-request"],
                relatedRecordIDs: [],
                coreContextRecordIDs: [],
                coreMemoryRecordID: nil,
                auditRecordID: nil,
                startedAt: startedAt,
                finishedAt: finishedAt,
                succeeded: false
            )
        }

        var actions: [String] = ["assistant.mode:conversation-only"]
        var plannerSource = "rag-core"
        var plannerNote = "纯对话模式：Boss 内部不执行写操作，操作任务交由外部 OpenClaw Runtime。"
        var relatedRecordIDs: [String] = []
        var coreContextRecordIDs: [String] = []
        var coreContext: [CoreContextItem] = []
        var coreMemoryRecordID: String? = nil
        var auditRecordID: String? = nil
        var reply = ""
        var succeeded = false
        let confirmationRequired = false
        let confirmationToken: String? = nil
        let confirmationExpiresAt: Date? = nil

        do {
            if let coreTagID = try findExistingTagID(primaryName: coreTagPrimaryName, aliases: coreTagAliases) {
                coreContext = try loadCoreContext(coreTagID: coreTagID, request: request)
                actions.append("context.core.load:\(coreContext.count)")
            } else {
                coreContext = []
                actions.append("context.core.load:0")
                actions.append("context.core.tag:not_found")
            }

            coreContextRecordIDs = coreContext.map { $0.record.id }
            let output = try await answerQuestion(question: request, coreContext: coreContext)
            reply = output.reply
            relatedRecordIDs = output.relatedRecordIDs
            actions.append(contentsOf: output.actions)

            let relay = await relayToOpenClaw(
                requestID: requestID,
                request: request,
                source: source,
                coreContext: coreContext
            )
            actions.append(contentsOf: relay.actions)
            if let relayNote = relay.humanReadableNote, !relayNote.isEmpty {
                reply += "\n\n\(relayNote)"
            }
            if let relayPlannerSource = relay.plannerSource {
                plannerSource = relayPlannerSource
            }
            if let relayPlannerNote = relay.plannerNote, !relayPlannerNote.isEmpty {
                plannerNote = "\(plannerNote)\n\(relayPlannerNote)"
            }

            AssistantRuntimeDocService.shared.refreshSilently()
            actions.append("docs.runtime.refresh:triggered")
            succeeded = true
        } catch {
            reply = "对话处理失败：\(error.localizedDescription)"
            actions.append("assistant.error:\(error.localizedDescription)")
            succeeded = false
        }

        let finishedAt = Date()
        let explicitMergeStrategy = parseMergeStrategy(from: request)
        let conflict = detectCoreConflict(request: request, reply: reply, coreContext: coreContext)
        let mergeStrategy = resolveMergeStrategy(explicit: explicitMergeStrategy, conflict: conflict)

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
                icon: "text.append"
            )

            if shouldPersistCoreMemory(
                request: request,
                reply: reply,
                actions: actions,
                relatedRecordIDs: relatedRecordIDs,
                confirmationRequired: confirmationRequired,
                succeeded: succeeded,
                explicitMergeStrategy: explicitMergeStrategy
            ) {
                let coreText = buildCoreMemoryText(
                    requestID: requestID,
                    source: source,
                    request: request,
                    intent: "conversation.rag",
                    plannerSource: plannerSource,
                    plannerNote: plannerNote,
                    toolPlan: ["retrieve-core-memory", "compose-answer", "relay-openclaw(optional)"],
                    confirmationRequired: confirmationRequired,
                    confirmationToken: confirmationToken,
                    confirmationExpiresAt: confirmationExpiresAt,
                    reply: reply,
                    actions: actions,
                    relatedRecordIDs: relatedRecordIDs,
                    coreContextRecordIDs: coreContextRecordIDs,
                    mergeStrategy: mergeStrategy.rawValue,
                    conflictRecordID: conflict?.recordID,
                    conflictScore: conflict?.score
                )

                switch mergeStrategy {
                case .overwrite:
                    if let targetID = conflict?.recordID,
                       let target = try recordRepo.fetchByID(targetID),
                       target.tags.contains(coreTag.id),
                       target.content.fileType.isTextLike {
                        if let updated = try recordRepo.updateTextContent(recordID: targetID, text: coreText) {
                            coreMemoryRecordID = updated.id
                        } else {
                            coreMemoryRecordID = targetID
                        }
                        actions.append("core.memory:overwrite:\(targetID)")
                    } else {
                        let created = try appendToDailyAssistantRecord(tagID: coreTag.id, prefix: "assistant-core", entry: coreText)
                        coreMemoryRecordID = created.id
                        actions.append("core.memory:create:\(created.id)")
                    }
                case .keep:
                    actions.append("core.memory:skip:keep")
                case .versioned:
                    let created = try appendToDailyAssistantRecord(tagID: coreTag.id, prefix: "assistant-core", entry: coreText)
                    coreMemoryRecordID = created.id
                    actions.append("core.memory:create:\(created.id)")
                }
            } else {
                actions.append("core.memory:skip")
            }

            let auditText = buildAuditText(
                requestID: requestID,
                source: source,
                request: request,
                intent: "conversation.rag",
                startedAt: startedAt,
                finishedAt: finishedAt,
                reply: reply,
                actions: actions,
                relatedRecordIDs: relatedRecordIDs,
                coreContextRecordIDs: coreContextRecordIDs,
                coreMemoryRecordID: coreMemoryRecordID,
                plannerSource: plannerSource,
                plannerNote: plannerNote,
                toolPlan: ["retrieve-core-memory", "compose-answer", "relay-openclaw(optional)"],
                confirmationRequired: confirmationRequired,
                confirmationToken: confirmationToken,
                confirmationExpiresAt: confirmationExpiresAt,
                mergeStrategy: mergeStrategy.rawValue,
                conflictRecordID: conflict?.recordID,
                conflictScore: conflict?.score
            )
            let auditRecord = try appendToDailyAssistantRecord(
                tagID: auditTag.id,
                prefix: "assistant-audit",
                entry: auditText
            )
            auditRecordID = auditRecord.id
            actions.append("audit.log:write:\(auditRecord.id)")
        } catch {
            actions.append("assistant.persist:error:\(shortText(error.localizedDescription, limit: 140))")
        }

        return AssistantKernelResult(
            requestID: requestID,
            source: source,
            request: request,
            intent: "conversation.rag",
            plannerSource: plannerSource,
            plannerNote: plannerNote,
            toolPlan: ["retrieve-core-memory", "compose-answer", "relay-openclaw(optional)"],
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

    private struct OpenClawRelayResult {
        let actions: [String]
        let humanReadableNote: String?
        let plannerSource: String?
        let plannerNote: String?
    }

    private func relayToOpenClaw(
        requestID: String,
        request: String,
        source: String,
        coreContext: [CoreContextItem]
    ) async -> OpenClawRelayResult {
        let config = AppConfig.shared
        guard config.openClawRelayEnabled else {
            return OpenClawRelayResult(
                actions: ["openclaw.relay:disabled"],
                humanReadableNote: nil,
                plannerSource: nil,
                plannerNote: nil
            )
        }

        let endpoint = config.openClawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            return OpenClawRelayResult(
                actions: ["openclaw.relay:invalid-endpoint"],
                humanReadableNote: "OpenClaw 转发未执行：请在设置中配置有效 Endpoint。",
                plannerSource: nil,
                plannerNote: "OpenClaw Endpoint 未配置或无效。"
            )
        }

        let contextPayload: [[String: Any]] = coreContext.prefix(10).map { item in
            [
                "record_id": item.record.id,
                "filename": item.record.content.filename,
                "snippet": shortText(item.snippet, limit: 420),
                "score": item.score
            ]
        }
        let payload: [String: Any] = [
            "request_id": requestID,
            "source": source,
            "request": request,
            "mode": "conversation_only",
            "interfaces": BossInterfaceCatalog.specs.map { spec in
                [
                    "name": spec.name,
                    "category": spec.category,
                    "summary": spec.summary,
                    "input": spec.inputSchema,
                    "output": spec.outputSchema,
                    "risk": spec.riskLevel
                ]
            },
            "skills_manifest": SkillManifestService.shared.loadManifestText(),
            "core_context": contextPayload
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return OpenClawRelayResult(
                actions: ["openclaw.relay:encode-failed"],
                humanReadableNote: "OpenClaw 转发未执行：请求编码失败。",
                plannerSource: nil,
                plannerNote: nil
            )
        }

        var requestObject = URLRequest(url: url)
        requestObject.httpMethod = "POST"
        requestObject.httpBody = body
        requestObject.timeoutInterval = 25
        requestObject.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = config.openClawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            requestObject.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: requestObject)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(statusCode) else {
                return OpenClawRelayResult(
                    actions: ["openclaw.relay:http:\(statusCode)"],
                    humanReadableNote: "OpenClaw 已连接但返回异常状态：\(statusCode)。",
                    plannerSource: nil,
                    plannerNote: "OpenClaw HTTP 状态异常：\(statusCode)"
                )
            }

            let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clipped = responseText.isEmpty ? "ok" : shortText(responseText, limit: 260)
            return OpenClawRelayResult(
                actions: ["openclaw.relay:ok", "openclaw.relay.response:\(clipped)"],
                humanReadableNote: "OpenClaw 已收到本次会话上下文，可在外部 Runtime 继续执行操作链路。",
                plannerSource: "rag-core+openclaw",
                plannerNote: "OpenClaw 转发成功（会话型协同，不在 Boss 内直接执行操作）。"
            )
        } catch {
            return OpenClawRelayResult(
                actions: ["openclaw.relay:failed:\(error.localizedDescription)"],
                humanReadableNote: "OpenClaw 转发失败：\(error.localizedDescription)",
                plannerSource: nil,
                plannerNote: "OpenClaw 转发失败。"
            )
        }
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

    private enum CoreMergeStrategy: String {
        case overwrite
        case keep
        case versioned
    }

    private struct CoreConflictCandidate {
        let recordID: String
        let score: Double
    }

    private enum ToolRiskLevel: String {
        case low
        case medium
        case high
    }

    private struct AssistantToolCall: Codable {
        let name: String
        let arguments: [String: String]

        init(name: String, arguments: [String: String] = [:]) {
            self.name = name
            self.arguments = arguments
        }
    }

    private struct AssistantToolSpec {
        let name: String
        let description: String
        let requiredArguments: [String]
        let riskLevel: ToolRiskLevel
    }

    private struct PlannedToolCalls {
        let calls: [AssistantToolCall]
        let plannerSource: String
        let plannerNote: String?
        let toolPlan: [String]
        let clarifyQuestion: String?
    }

    private struct PendingConfirmation {
        let toolCalls: [AssistantToolCall]
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
        case answer(question: String)
        case search(query: String)
        case create(filename: String, content: String)
        case taskRun(taskRef: String)
        case skillRun(skillRef: String, input: String)
        case skillsCatalog
        case delete(recordID: String)
        case append(recordID: String, content: String)
        case replace(recordID: String, content: String)
        case unknown(query: String)

        var description: String {
            switch self {
            case .help: return "help"
            case .summarizeCore: return "summarizeCore"
            case .answer(let question): return "answer(\(question))"
            case .search(let query): return "search(\(query))"
            case .create(let filename, _): return "create(\(filename))"
            case .taskRun(let taskRef): return "taskRun(\(taskRef))"
            case .skillRun(let skillRef, _): return "skillRun(\(skillRef))"
            case .skillsCatalog: return "skillsCatalog"
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
        let recordReference = extractRecordReference(text)
        let payload = extractPayload(text)
        let createContent = extractCreateContent(text)
        let skillRef = extractSkillReference(text)

        if lower.contains("help") || lower.contains("帮助") || lower.contains("你能做什么") {
            return .help
        }

        if lower.contains("总结") || lower.contains("回顾") || lower.contains("summarize core") || lower.contains("core memory") {
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
        {
            let taskRef = extractTaskReference(text)
            if !taskRef.isEmpty {
                return .taskRun(taskRef: taskRef)
            }
        }

        if lower.contains("skill.run")
            || lower.contains("run skill")
            || lower.contains("执行skill")
            || lower.contains("运行skill")
            || lower.contains("调用skill")
            || lower.contains("使用skill")
            || lower.contains("执行技能")
            || lower.contains("运行技能")
        {
            if !skillRef.isEmpty {
                let input = payload.isEmpty ? text : payload
                return .skillRun(skillRef: skillRef, input: input)
            }
        }

        if shouldCreateRecordIntent(lowerText: lower) {
            if !createContent.isEmpty {
                let filename = extractCreateFilename(text) ?? defaultCreateFilename(for: text)
                return .create(filename: filename, content: createContent)
            }
        }

        if let recordReference, lower.contains("删除") || lower.contains("delete") || lower.contains("移除") {
            return .delete(recordID: recordReference)
        }

        if let recordReference, !payload.isEmpty, (lower.contains("追加") || lower.contains("append") || lower.contains("补充")) {
            return .append(recordID: recordReference, content: payload)
        }

        if let recordReference, !payload.isEmpty, (lower.contains("编辑") || lower.contains("更新") || lower.contains("改写") || lower.contains("replace") || lower.contains("rewrite")) {
            return .replace(recordID: recordReference, content: payload)
        }

        if lower.contains("搜索") || lower.contains("检索") || lower.contains("查找") || lower.contains("search") || lower.contains("find") {
            let query = extractSearchQuery(text)
            return .search(query: query)
        }

        if shouldTreatAsQuestion(text) {
            return .answer(question: text)
        }

        return .unknown(query: text)
    }

    private func toolSpecs() -> [AssistantToolSpec] {
        [
            AssistantToolSpec(name: "assistant.help", description: "输出助理能力说明", requiredArguments: [], riskLevel: .low),
            AssistantToolSpec(name: "core.summarize", description: "总结 Core 持久记忆上下文", requiredArguments: [], riskLevel: .low),
            AssistantToolSpec(name: "assistant.answer", description: "基于 Core/审计/技能上下文回答问题，参数 question", requiredArguments: ["question"], riskLevel: .low),
            AssistantToolSpec(name: "skills.catalog", description: "读取当前 Skill 清单与基础接口说明", requiredArguments: [], riskLevel: .low),
            AssistantToolSpec(name: "record.search", description: "检索记录，参数 query", requiredArguments: ["query"], riskLevel: .low),
            AssistantToolSpec(name: "record.create", description: "创建文本记录，参数 content，可选 filename", requiredArguments: ["content"], riskLevel: .low),
            AssistantToolSpec(name: "task.run", description: "运行已有任务，参数 task_ref（任务ID或任务名）", requiredArguments: ["task_ref"], riskLevel: .high),
            AssistantToolSpec(name: "skill.run", description: "运行已注册 Skill，参数 skill_ref，可选 input", requiredArguments: ["skill_ref"], riskLevel: .medium),
            AssistantToolSpec(name: "record.delete", description: "删除记录，参数 record_id", requiredArguments: ["record_id"], riskLevel: .high),
            AssistantToolSpec(name: "record.append", description: "向文本记录追加内容，参数 record_id/content", requiredArguments: ["record_id", "content"], riskLevel: .medium),
            AssistantToolSpec(name: "record.replace", description: "改写文本记录内容，参数 record_id/content", requiredArguments: ["record_id", "content"], riskLevel: .high)
        ]
    }

    private func toolSpec(named name: String) -> AssistantToolSpec? {
        toolSpecs().first { $0.name == name }
    }

    private func planToolCalls(request: String, coreContext: [CoreContextItem]) async -> PlannedToolCalls {
        var fallbackNote = "使用规则解析器（LLM 规划不可用或无结果）。"
        do {
            if let planned = try await planToolCallsWithLLM(request: request, coreContext: coreContext) {
                return planned
            }
        } catch {
            fallbackNote = "使用规则解析器（LLM 规划失败：\(error.localizedDescription)）"
        }

        if let clarify = minimalClarifyQuestion(for: request) {
            return PlannedToolCalls(
                calls: [],
                plannerSource: "rule",
                plannerNote: fallbackNote,
                toolPlan: ["ask-minimal-clarify-question"],
                clarifyQuestion: clarify
            )
        }

        let intent = parseIntent(request)
        let calls = toolCalls(for: intent, request: request)
        return PlannedToolCalls(
            calls: calls,
            plannerSource: "rule",
            plannerNote: fallbackNote,
            toolPlan: defaultToolPlan(for: calls),
            clarifyQuestion: nil
        )
    }

    private func planToolCallsWithLLM(request: String, coreContext: [CoreContextItem]) async throws -> PlannedToolCalls? {
        let modelIdentifier = normalizedPlannerModelIdentifier(AppConfig.shared.claudeModel)
        let contextRows = coreContext.prefix(6).map { item in
            "[\(item.record.id)] \(item.record.content.filename): \(shortText(item.snippet, limit: 220))"
        }.joined(separator: "\n")
        let skillContext = skillPlannerContext(limit: 24)
        let toolsJSON: [[String: Any]] = toolSpecs().map { spec in
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
        若请求与 Skill 清单匹配，优先使用 skill.run。
        """
        let userPrompt = """
        REQUEST:
        \(request)

        CORE_CONTEXT:
        \(contextRows.isEmpty ? "(none)" : contextRows)

        TOOLS:
        \(toolsText)

        SKILL_CATALOG:
        \(skillContext)

        输出 JSON，不要附加 Markdown 代码块。
        """

        let raw = try await callLLMAPI(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
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

        var plannedCalls: [AssistantToolCall] = []
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
                return materializeToolCall(name: name, arguments: normalizedArgs, request: request)
            }
        }

        if plannedCalls.isEmpty, let legacy = legacyIntentCall(from: object, request: request) {
            plannedCalls = [legacy]
        }

        if let override = overrideLLMPlannedCallsIfNeeded(request: request, plannedCalls: plannedCalls) {
            return PlannedToolCalls(
                calls: override,
                plannerSource: "llm:\(modelIdentifier)",
                plannerNote: note.isEmpty ? "已应用规则覆盖（避免日期语义被降级为纯检索）。" : "\(note)（已应用规则覆盖）",
                toolPlan: defaultToolPlan(for: override),
                clarifyQuestion: nil
            )
        }

        if clarifyQuestion.isEmpty,
           let forcedClarify = minimalClarifyQuestion(for: request) {
            let mutatingToolNames: Set<String> = ["record.create", "record.delete", "record.append", "record.replace", "task.run", "skill.run"]
            if plannedCalls.contains(where: { mutatingToolNames.contains($0.name) }) {
                return PlannedToolCalls(
                    calls: [],
                    plannerSource: "llm:\(modelIdentifier)",
                    plannerNote: note.isEmpty ? nil : note,
                    toolPlan: toolPlan.isEmpty ? ["ask-minimal-clarify-question"] : toolPlan,
                    clarifyQuestion: forcedClarify
                )
            }
        }

        if plannedCalls.isEmpty && clarifyQuestion.isEmpty {
            if let fallbackClarify = minimalClarifyQuestion(for: request) {
                return PlannedToolCalls(
                    calls: [],
                    plannerSource: "llm:\(modelIdentifier)",
                    plannerNote: note.isEmpty ? nil : note,
                    toolPlan: toolPlan.isEmpty ? ["ask-minimal-clarify-question"] : toolPlan,
                    clarifyQuestion: fallbackClarify
                )
            }
            return nil
        }

        return PlannedToolCalls(
            calls: plannedCalls,
            plannerSource: "llm:\(modelIdentifier)",
            plannerNote: note.isEmpty ? nil : note,
            toolPlan: toolPlan.isEmpty ? defaultToolPlan(for: plannedCalls) : toolPlan,
            clarifyQuestion: clarifyQuestion.isEmpty ? nil : clarifyQuestion
        )
    }

    private func skillPlannerContext(limit: Int) -> String {
        let skills = (try? taskRepo.fetchEnabledSkills()) ?? []
        guard !skills.isEmpty else {
            return "- (empty)"
        }

        return skills.prefix(limit).map { skill in
            let trigger = skill.triggerHint.isEmpty ? "-" : skill.triggerHint
            let description = skill.description.isEmpty ? "-" : shortText(skill.description, limit: 120)
            let action = describeSkillActionForPlanner(skill.action)
            return "- id: \(skill.id), name: \(skill.name), trigger: \(trigger), action: \(action), description: \(description)"
        }.joined(separator: "\n")
    }

    private func describeSkillActionForPlanner(_ action: ProjectSkill.SkillAction) -> String {
        switch action {
        case .llmPrompt(_, _, let model):
            return "llmPrompt(\(model))"
        case .shellCommand:
            return "shellCommand"
        case .createRecord:
            return "createRecord"
        case .appendToRecord:
            return "appendToRecord"
        }
    }

    private func legacyIntentCall(from object: [String: Any], request: String) -> AssistantToolCall? {
        let rawIntent = (object["intent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query = (object["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = (object["record_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (object["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = ((object["filename"] as? String) ?? (object["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch rawIntent {
        case "help":
            return AssistantToolCall(name: "assistant.help")
        case "summarizecore", "summarize_core":
            return AssistantToolCall(name: "core.summarize")
        case "answer", "qa", "question":
            let resolvedQuestion = query.isEmpty ? request : query
            return materializeToolCall(name: "assistant.answer", arguments: ["question": resolvedQuestion], request: request)
        case "skillscatalog", "skills_catalog", "skillcatalog", "skill_catalog":
            return AssistantToolCall(name: "skills.catalog")
        case "search":
            let resolved = query.isEmpty ? extractSearchQuery(request) : query
            return materializeToolCall(name: "record.search", arguments: ["query": resolved], request: request)
        case "create", "create_record", "record_create":
            let resolvedContent = content.isEmpty ? extractCreateContent(request) : content
            let resolvedFilename: String
            if filename.isEmpty {
                resolvedFilename = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
            } else {
                resolvedFilename = normalizeCreateFilename(filename)
            }
            return materializeToolCall(name: "record.create", arguments: ["filename": resolvedFilename, "content": resolvedContent], request: request)
        case "taskrun", "task_run":
            let resolved = query.isEmpty ? extractTaskReference(request) : query
            return materializeToolCall(name: "task.run", arguments: ["task_ref": resolved], request: request)
        case "skillrun", "skill_run":
            let resolved = query.isEmpty ? extractSkillReference(request) : query
            let resolvedInput = content.isEmpty ? extractPayload(request) : content
            return materializeToolCall(name: "skill.run", arguments: ["skill_ref": resolved, "input": resolvedInput], request: request)
        case "delete":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            return materializeToolCall(name: "record.delete", arguments: ["record_id": resolvedID], request: request)
        case "append":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            return materializeToolCall(name: "record.append", arguments: ["record_id": resolvedID, "content": resolvedContent], request: request)
        case "replace":
            let resolvedID = recordID.isEmpty ? (extractRecordReference(request) ?? "") : recordID
            let resolvedContent = content.isEmpty ? extractPayload(request) : content
            return materializeToolCall(name: "record.replace", arguments: ["record_id": resolvedID, "content": resolvedContent], request: request)
        default:
            return nil
        }
    }

    private func toolCalls(for intent: Intent, request: String) -> [AssistantToolCall] {
        switch intent {
        case .help:
            return [AssistantToolCall(name: "assistant.help")]
        case .summarizeCore:
            return [AssistantToolCall(name: "core.summarize")]
        case .answer(let question):
            return [AssistantToolCall(name: "assistant.answer", arguments: ["question": question])]
        case .skillsCatalog:
            return [AssistantToolCall(name: "skills.catalog")]
        case .search(let query):
            return [AssistantToolCall(name: "record.search", arguments: ["query": query])]
        case .create(let filename, let content):
            return [AssistantToolCall(name: "record.create", arguments: ["filename": filename, "content": content])]
        case .taskRun(let taskRef):
            return [AssistantToolCall(name: "task.run", arguments: ["task_ref": taskRef])]
        case .skillRun(let skillRef, let input):
            return [AssistantToolCall(name: "skill.run", arguments: ["skill_ref": skillRef, "input": input])]
        case .delete(let recordID):
            return [AssistantToolCall(name: "record.delete", arguments: ["record_id": recordID])]
        case .append(let recordID, let content):
            return [AssistantToolCall(name: "record.append", arguments: ["record_id": recordID, "content": content])]
        case .replace(let recordID, let content):
            return [AssistantToolCall(name: "record.replace", arguments: ["record_id": recordID, "content": content])]
        case .unknown:
            return [AssistantToolCall(name: "record.search", arguments: ["query": extractSearchQuery(request)])]
        }
    }

    private func materializeToolCall(name: String, arguments: [String: String], request: String) -> AssistantToolCall? {
        guard let spec = toolSpec(named: name) else { return nil }
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

        return AssistantToolCall(name: name, arguments: args)
    }

    private func defaultToolPlan(for calls: [AssistantToolCall]) -> [String] {
        if calls.isEmpty {
            return ["fallback-search", "request-disambiguation"]
        }
        return calls.enumerated().map { index, call in
            "\(index + 1). \(call.name)"
        }
    }

    private func overrideLLMPlannedCallsIfNeeded(request: String, plannedCalls: [AssistantToolCall]) -> [AssistantToolCall]? {
        let lower = request.lowercased()
        let hasWriteCall = plannedCalls.contains { call in
            ["record.create", "record.delete", "record.append", "record.replace"].contains(call.name)
        }
        let searchOnly = !plannedCalls.isEmpty && plannedCalls.allSatisfy { $0.name == "record.search" }
        if !hasWriteCall, (searchOnly || plannedCalls.isEmpty), shouldTreatAsQuestion(request) {
            return [AssistantToolCall(name: "assistant.answer", arguments: ["question": request])]
        }
        guard !hasWriteCall, searchOnly || plannedCalls.isEmpty else {
            return nil
        }

        let payload = extractPayload(request)
        if containsAnyKeyword(lower, keywords: ["追加", "append", "补充"]),
           !payload.isEmpty,
           let reference = extractRecordReference(request) {
            return [AssistantToolCall(name: "record.append", arguments: ["record_id": reference, "content": payload])]
        }

        let createContent = extractCreateContent(request)
        if shouldCreateRecordIntent(lowerText: lower), !createContent.isEmpty {
            let filename = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
            return [AssistantToolCall(name: "record.create", arguments: ["filename": filename, "content": createContent])]
        }

        if containsAnyKeyword(lower, keywords: ["skill.run", "run skill", "运行skill", "执行skill", "运行技能", "执行技能"]) {
            let skillRef = extractSkillReference(request)
            if !skillRef.isEmpty {
                let input = extractPayload(request)
                return [AssistantToolCall(name: "skill.run", arguments: ["skill_ref": skillRef, "input": input])]
            }
        }

        return nil
    }

    private func describeToolCalls(_ calls: [AssistantToolCall], fallbackRequest: String) -> String {
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

    private func requiresConfirmation(toolCalls: [AssistantToolCall]) -> Bool {
        toolCalls.contains { call in
            toolSpec(named: call.name)?.riskLevel == .high
        }
    }

    private func relatedRecordIDsFromToolCalls(_ toolCalls: [AssistantToolCall]) -> [String] {
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

    private func buildDryRunPreview(toolCalls: [AssistantToolCall]) throws -> String {
        var lines: [String] = []
        for call in toolCalls {
            switch call.name {
            case "record.delete":
                let requested = call.arguments["record_id"] ?? "-"
                let resolvedID = (try? resolveRecordReference(requested, for: .delete, request: requested)) ?? requested.uppercased()
                if let record = try recordRepo.fetchByID(resolvedID) {
                    lines.append("- record.delete: 将删除 [\(record.id)] \(record.content.filename)")
                } else {
                    lines.append("- record.delete: 目标记录不存在 [\(resolvedID)]")
                }

            case "record.replace":
                let requested = call.arguments["record_id"] ?? "-"
                let recordID = (try? resolveRecordReference(requested, for: .replace, request: requested)) ?? requested.uppercased()
                let content = call.arguments["content"] ?? ""
                if let record = try recordRepo.fetchByID(recordID) {
                    lines.append("- record.replace: 将改写 [\(record.id)] \(record.content.filename)，新内容约 \(content.count) 字符")
                } else {
                    lines.append("- record.replace: 目标记录不存在 [\(recordID)]")
                }

            case "task.run":
                let ref = call.arguments["task_ref"] ?? ""
                if ref.isEmpty {
                    lines.append("- task.run: 缺少 task_ref")
                } else if let task = try? resolveTaskItem(taskRef: ref) {
                    lines.append("- task.run: 将运行任务 \(task.name)（\(task.id)）")
                } else {
                    lines.append("- task.run: 未找到任务 \(ref)")
                }

            case "skill.run":
                let ref = call.arguments["skill_ref"] ?? ""
                if ref.isEmpty {
                    lines.append("- skill.run: 缺少 skill_ref")
                } else if let skill = try? resolveSkill(skillRef: ref) {
                    lines.append("- skill.run: 将运行 Skill \(skill.name)（\(skill.id)）")
                } else {
                    lines.append("- skill.run: 未找到 Skill \(ref)")
                }

            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private func consumeConfirmationToolCallsIfProvided(request: String, source: String) async -> (token: String?, toolCalls: [AssistantToolCall]?) {
        guard let token = extractConfirmationToken(request) else {
            return (nil, nil)
        }
        let pending = await confirmationStore.consume(token: token, source: source)
        return (token, pending?.toolCalls)
    }

    private func savePendingConfirmation(toolCalls: [AssistantToolCall], request: String, source: String, toolPlan: [String]) async -> (token: String, expiresAt: Date) {
        let token = generateConfirmationToken()
        let now = Date()
        let expiresAt = now.addingTimeInterval(confirmationTTL)
        let pending = PendingConfirmation(
            toolCalls: toolCalls,
            source: source,
            request: request,
            toolPlan: toolPlan,
            createdAt: now,
            expiresAt: expiresAt
        )
        await confirmationStore.save(token: token, pending: pending)
        return (token, expiresAt)
    }

    private func buildConfirmationReply(toolCalls: [AssistantToolCall], token: String, expiresAt: Date, dryRunPreview: String) -> String {
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

    private func execute(toolCalls: [AssistantToolCall], originalRequest: String, coreContext: [CoreContextItem]) async throws -> ActionOutput {
        guard !toolCalls.isEmpty else {
            return ActionOutput(
                reply: "我需要更多信息才能继续。请补充你要执行的动作（搜索/删除/追加/改写）以及目标记录。",
                actions: ["tool.execute:empty"],
                relatedRecordIDs: []
            )
        }

        var replies: [String] = []
        var actions: [String] = []
        var relatedIDs: [String] = []

        for call in toolCalls {
            guard let intent = intent(from: call, request: originalRequest) else {
                actions.append("tool.unsupported:\(call.name)")
                continue
            }

            let output = try await execute(intent: intent, originalRequest: originalRequest, coreContext: coreContext)
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
        return ActionOutput(
            reply: reply.isEmpty ? "未执行任何有效工具调用，请重试并明确目标。" : reply,
            actions: actions,
            relatedRecordIDs: relatedIDs
        )
    }

    private func intent(from call: AssistantToolCall, request: String) -> Intent? {
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
        case "record.search":
            let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .search(query: query.isEmpty ? extractSearchQuery(request) : query)
        case "record.create":
            let filename = call.arguments["filename"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = call.arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { return nil }
            let resolvedFilename = filename.isEmpty ? defaultCreateFilename(for: request) : normalizeCreateFilename(filename)
            return .create(filename: resolvedFilename, content: content)
        case "task.run":
            let taskRef = call.arguments["task_ref"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !taskRef.isEmpty else { return nil }
            return .taskRun(taskRef: taskRef)
        case "skill.run":
            let skillRef = call.arguments["skill_ref"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !skillRef.isEmpty else { return nil }
            let input = call.arguments["input"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .skillRun(skillRef: skillRef, input: input)
        case "record.delete":
            let rawRecordID = call.arguments["record_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let recordID: String
            if rawRecordID.isEmpty || isPlaceholderRecordReference(rawRecordID) {
                recordID = extractRecordReference(request) ?? ""
            } else {
                recordID = rawRecordID
            }
            guard !recordID.isEmpty else { return nil }
            return .delete(recordID: recordID.uppercased())
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

    private func execute(intent: Intent, originalRequest: String, coreContext: [CoreContextItem]) async throws -> ActionOutput {
        switch intent {
        case .help:
            let reply = """
            我可以处理这些操作：
            1. 检索：例如“搜索 Swift 并发”
            2. 新建文本记录：例如“为明天新建计划：<内容>”
            3. 运行任务：例如“运行任务 <task-id>”
            4. 运行 Skill：例如“运行 skill:<skill-name>，输入：<内容>”
            5. 问答：例如“今天我做了什么？”、“这周重点是什么？”
            6. 查看 Skill 文档：例如“skills catalog”或“技能列表”
            7. 删除记录：例如“删除记录 <record-id>”
            8. 追加内容：例如“向 <record-id> 或 TODAY 追加：<内容>”
            9. 覆写内容：例如“把 <record-id> 改写为：<内容>”
            10. 总结 Core：例如“总结 Core 记忆”
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

        case .answer(let question):
            return try await answerQuestion(question: question, coreContext: coreContext)

        case .skillsCatalog:
            let manifest = SkillManifestService.shared.loadManifestText()
            return ActionOutput(
                reply: manifest,
                actions: ["skills.catalog:read"],
                relatedRecordIDs: []
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

        case .create(let filename, let content):
            let record = try recordRepo.createTextRecord(text: content, filename: filename)
            var reply = "已创建文本记录：\(record.content.filename)（\(record.id)）"
            if let date = resolveDateReference(in: originalRequest) {
                reply += "\n日期：\(dateFilenameStamp(date))"
            }
            return ActionOutput(
                reply: reply,
                actions: ["record.create:\(record.id):ok"],
                relatedRecordIDs: [record.id]
            )

        case .taskRun(let taskRef):
            let task = try resolveTaskItem(taskRef: taskRef)
            let log = await SchedulerService.shared.run(task: task)
            if log.status == .success {
                let output = shortText(log.output, limit: 220)
                return ActionOutput(
                    reply: "已运行任务：\(task.name)（\(task.id)）\n输出：\(output)",
                    actions: ["task.run:\(task.id):success"],
                    relatedRecordIDs: []
                )
            }
            return ActionOutput(
                reply: "任务执行失败：\(task.name)（\(task.id)）\n错误：\(log.error ?? "未知错误")",
                actions: ["task.run:\(task.id):failed"],
                relatedRecordIDs: []
            )

        case .skillRun(let skillRef, let input):
            let skill = try resolveSkill(skillRef: skillRef)
            guard skill.isEnabled else {
                return ActionOutput(
                    reply: "Skill 已停用：\(skill.name)（\(skill.id)）",
                    actions: ["skill.run:\(skill.id):disabled"],
                    relatedRecordIDs: []
                )
            }
            let resolvedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? originalRequest
                : input
            return try await executeSkill(
                skill: skill,
                input: resolvedInput,
                originalRequest: originalRequest,
                coreContext: coreContext
            )

        case .delete(let recordID):
            let resolvedID = try resolveRecordReference(recordID, for: .delete, request: originalRequest)
            guard let record = try recordRepo.fetchByID(resolvedID) else {
                return ActionOutput(
                    reply: "未找到记录：\(resolvedID)",
                    actions: ["record.delete:\(resolvedID):not_found"],
                    relatedRecordIDs: []
                )
            }
            try recordRepo.delete(id: resolvedID)
            return ActionOutput(
                reply: "已删除记录：\(record.content.filename)（\(resolvedID)）",
                actions: ["record.delete:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .append(let recordID, let content):
            let resolvedID = try resolveRecordReference(recordID, for: .append, request: originalRequest, createIfMissingContent: content)
            guard let record = try recordRepo.fetchByID(resolvedID) else {
                return ActionOutput(
                    reply: "未找到记录：\(resolvedID)",
                    actions: ["record.append:\(resolvedID):not_found"],
                    relatedRecordIDs: []
                )
            }
            guard record.content.fileType.isTextLike else {
                return ActionOutput(
                    reply: "记录不是文本类型，无法追加：\(resolvedID)",
                    actions: ["record.append:\(resolvedID):not_text"],
                    relatedRecordIDs: [resolvedID]
                )
            }
            let current = try recordRepo.loadTextContent(record: record)
            let merged = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? content
                : current + "\n\n---\n\n" + content
            _ = try recordRepo.updateTextContent(recordID: resolvedID, text: merged)
            return ActionOutput(
                reply: "已向记录 \(resolvedID) 追加内容。",
                actions: ["record.append:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .replace(let recordID, let content):
            let resolvedID = try resolveRecordReference(recordID, for: .replace, request: originalRequest)
            guard let record = try recordRepo.fetchByID(resolvedID) else {
                return ActionOutput(
                    reply: "未找到记录：\(resolvedID)",
                    actions: ["record.replace:\(resolvedID):not_found"],
                    relatedRecordIDs: []
                )
            }
            guard record.content.fileType.isTextLike else {
                return ActionOutput(
                    reply: "记录不是文本类型，无法改写：\(resolvedID)",
                    actions: ["record.replace:\(resolvedID):not_text"],
                    relatedRecordIDs: [resolvedID]
                )
            }
            _ = try recordRepo.updateTextContent(recordID: resolvedID, text: content)
            return ActionOutput(
                reply: "已改写记录 \(resolvedID) 的文本内容。",
                actions: ["record.replace:\(resolvedID):ok"],
                relatedRecordIDs: [resolvedID]
            )

        case .unknown(let query):
            let records = try searchRecords(query: query, limit: 5)
            if records.isEmpty {
                let coreHint = coreContext.prefix(5).map { "- [\($0.record.id)] \(shortText($0.snippet, limit: 90))" }.joined(separator: "\n")
                let suffix = coreHint.isEmpty ? "" : "\n可参考 Core 上下文：\n\(coreHint)"
                return ActionOutput(
                    reply: "我暂时无法直接执行该指令，已尝试检索但未命中。请明确“搜索/新建/删除/追加/改写”的目标记录。\(suffix)",
                    actions: ["intent.unknown:\(query)", "record.search.fallback:0"],
                    relatedRecordIDs: coreContext.map { $0.record.id }
                )
            }
            let lines = records.map { "- [\($0.id)] \($0.content.filename): \(shortText($0.preview, limit: 90))" }.joined(separator: "\n")
            return ActionOutput(
                reply: "我先按检索理解你的需求，命中这些记录：\n\(lines)\n\n如果你要我继续执行，请补充“新建/删除/追加/改写 + 记录ID(可用 TODAY/明天) + 内容”。",
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

    private func shouldTreatAsQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let actionKeywords = [
            "创建", "新建", "新增", "删除", "追加", "补充", "改写", "编辑", "更新",
            "create", "new note", "delete", "append", "replace", "rewrite",
            "搜索", "检索", "查找", "search", "find", "task.run", "run task", "skill.run", "run skill"
        ]
        if containsAnyKeyword(lower, keywords: actionKeywords) {
            return false
        }
        if text.contains("?") || text.contains("？") {
            return true
        }
        let questionKeywords = [
            "今天我做了什么", "今天做了什么", "我做了什么", "回顾", "总结", "为什么", "怎么", "如何", "哪些", "什么",
            "what did i do", "what have i done", "why", "how", "what", "which", "when"
        ]
        return containsAnyKeyword(lower, keywords: questionKeywords)
    }

    private func isTodayActivityQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let dayKeywords = ["今天", "today"]
        let activityKeywords = ["做了什么", "干了什么", "完成了什么", "what did i do", "what have i done"]
        return containsAnyKeyword(lower, keywords: dayKeywords) && containsAnyKeyword(lower, keywords: activityKeywords)
    }

    private func tailText(_ text: String, limit: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let start = normalized.index(normalized.endIndex, offsetBy: -limit)
        return "...\n" + normalized[start...]
    }

    private func loadAuditSnippetsForAnswer(question: String, limit: Int) throws -> [(record: Record, snippet: String)] {
        guard let auditTagID = try findExistingTagID(primaryName: auditTagPrimaryName, aliases: auditTagAliases) else {
            return []
        }
        var filter = RecordFilter()
        filter.tagIDs = [auditTagID]
        filter.tagMatchAny = true
        var records = try recordRepo.fetchAll(filter: filter).filter { $0.content.fileType.isTextLike }

        if isTodayActivityQuestion(question) {
            let todayFilename = "assistant-audit-\(dateFilenameStamp(Date())).txt"
            records.sort { lhs, rhs in
                let lhsToday = lhs.content.filename.caseInsensitiveCompare(todayFilename) == .orderedSame
                let rhsToday = rhs.content.filename.caseInsensitiveCompare(todayFilename) == .orderedSame
                if lhsToday == rhsToday {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhsToday && !rhsToday
            }
        } else {
            records.sort { $0.updatedAt > $1.updatedAt }
        }

        return records.prefix(limit).map { record in
            let text = (try? recordRepo.loadTextContent(record: record, maxBytes: 240_000)) ?? record.preview
            return (record, tailText(text, limit: 1800))
        }
    }

    private func findExistingTagID(primaryName: String, aliases: [String]) throws -> String? {
        let allTags = try tagRepo.fetchAll()
        let candidates = Set(([primaryName] + aliases).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return allTags.first {
            candidates.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }?.id
    }

    private func answerQuestion(question: String, coreContext: [CoreContextItem]) async throws -> ActionOutput {
        let coreRows = coreContext.prefix(8).map { item in
            "[\(item.record.id)] \(item.record.content.filename): \(shortText(item.snippet, limit: 180))"
        }
        let auditRows = try loadAuditSnippetsForAnswer(question: question, limit: 6)

        var relatedIDs: [String] = []
        for item in coreContext.prefix(8) where !relatedIDs.contains(item.record.id) {
            relatedIDs.append(item.record.id)
        }
        for row in auditRows where !relatedIDs.contains(row.record.id) {
            relatedIDs.append(row.record.id)
        }

        let auditContext = auditRows.map { row in
            "[\(row.record.id)] \(row.record.content.filename): \(shortText(row.snippet, limit: 320))"
        }.joined(separator: "\n")
        let coreContextText = coreRows.joined(separator: "\n")

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
        \(auditContext.isEmpty ? "(none)" : auditContext)

        SKILL_CATALOG:
        \(skillPlannerContext(limit: 20))
        """

        do {
            let modelIdentifier = normalizedPlannerModelIdentifier(AppConfig.shared.claudeModel)
            let answer = try await callLLMAPI(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ActionOutput(
                    reply: trimmed,
                    actions: ["assistant.answer:context"],
                    relatedRecordIDs: relatedIDs
                )
            }
        } catch {
            // fallback to local summary below
        }

        if isTodayActivityQuestion(question) {
            if let today = auditRows.first(where: { $0.record.content.filename.contains(dateFilenameStamp(Date())) }) {
                return ActionOutput(
                    reply: "根据今天的日志，已记录这些活动：\n\(shortText(today.snippet, limit: 520))",
                    actions: ["assistant.answer:fallback:today"],
                    relatedRecordIDs: relatedIDs
                )
            }
            return ActionOutput(
                reply: "今天还没有可用的审计日志记录，所以我还不能可靠地回答“今天做了什么”。",
                actions: ["assistant.answer:fallback:today-empty"],
                relatedRecordIDs: relatedIDs
            )
        }

        if !coreRows.isEmpty {
            let lines = coreRows.prefix(4).joined(separator: "\n")
            return ActionOutput(
                reply: "我当前能从 Core 记忆确认这些信息：\n\(lines)\n\n如果你希望更精确，我可以继续按关键词检索相关记录。",
                actions: ["assistant.answer:fallback:core"],
                relatedRecordIDs: relatedIDs
            )
        }

        return ActionOutput(
            reply: "当前可用上下文不足，暂时无法可靠回答。你可以先让我“搜索 <关键词>”或“总结 Core 记忆”。",
            actions: ["assistant.answer:fallback:empty"],
            relatedRecordIDs: relatedIDs
        )
    }

    private enum RecordReferenceAction {
        case delete
        case append
        case replace
    }

    private func resolveRecordReference(
        _ raw: String,
        for action: RecordReferenceAction,
        request: String,
        createIfMissingContent: String? = nil
    ) throws -> String {
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw PlannerError.apiError("记录引用为空")
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
            throw PlannerError.apiError("缺少目标记录引用，请提供记录 ID 或 TODAY/明天。")
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
                let filename = defaultCreateFilename(for: request, date: date)
                let created = try recordRepo.createTextRecord(text: content, filename: filename)
                return created.id
            }
            throw PlannerError.apiError("未找到 \(dateFilenameStamp(date)) 对应记录")
        }

        return reference.uppercased()
    }

    private func findTextRecordID(for date: Date) throws -> String? {
        let compact = dateCompactStamp(date)
        let dashed = dateFilenameStamp(date)
        let records = try recordRepo.fetchAll()
        return records.first { record in
            guard record.content.fileType.isTextLike else { return false }
            let filename = record.content.filename.lowercased()
            return filename.contains(compact) || filename.contains(dashed)
        }?.id
    }

    private func resolveTaskItem(taskRef: String) throws -> TaskItem {
        let reference = taskRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw PlannerError.apiError("任务引用为空")
        }

        let tasks = try taskRepo.fetchAllTasks()
        guard !tasks.isEmpty else {
            throw PlannerError.apiError("当前没有可运行的任务")
        }

        if let exactID = tasks.first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) {
            return exactID
        }

        if let exactName = tasks.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) {
            return exactName
        }

        if let containsName = tasks.first(where: { $0.name.lowercased().contains(reference.lowercased()) }) {
            return containsName
        }

        throw PlannerError.apiError("未找到任务：\(reference)")
    }

    private func resolveSkill(skillRef: String) throws -> ProjectSkill {
        let reference = skillRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw PlannerError.apiError("Skill 引用为空")
        }

        let skills = try taskRepo.fetchAllSkills()
        guard !skills.isEmpty else {
            throw PlannerError.apiError("当前没有可运行的 Skill")
        }

        if let exactID = skills.first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) {
            return exactID
        }
        if let exactName = skills.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) {
            return exactName
        }
        if let containsName = skills.first(where: { $0.name.lowercased().contains(reference.lowercased()) }) {
            return containsName
        }

        throw PlannerError.apiError("未找到 Skill：\(reference)")
    }

    private func executeSkill(
        skill: ProjectSkill,
        input: String,
        originalRequest: String,
        coreContext: [CoreContextItem]
    ) async throws -> ActionOutput {
        switch skill.action {
        case .llmPrompt(let systemPrompt, let userPromptTemplate, let model):
            let system = renderSkillTemplate(systemPrompt, input: input, request: originalRequest)
            let coreSnippet = coreContext.prefix(4).map { item in
                "[\(item.record.id)] \(shortText(item.snippet, limit: 160))"
            }.joined(separator: "\n")
            let userPrompt = """
            \(renderSkillTemplate(userPromptTemplate, input: input, request: originalRequest))

            CoreContext:
            \(coreSnippet.isEmpty ? "(none)" : coreSnippet)
            """
            let modelIdentifier = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppConfig.shared.claudeModel
                : model
            let reply = try await callLLMAPI(system: system, userPrompt: userPrompt, modelIdentifier: modelIdentifier)
            return ActionOutput(
                reply: "Skill \(skill.name) 执行完成。\n\(reply)",
                actions: ["skill.run:\(skill.id):llm"],
                relatedRecordIDs: []
            )

        case .shellCommand(let commandTemplate):
            let command = renderSkillTemplate(commandTemplate, input: input, request: originalRequest)
            let output = try await runSkillShell(command)
            return ActionOutput(
                reply: "Skill \(skill.name) 执行完成。\n\(shortText(output, limit: 800))",
                actions: ["skill.run:\(skill.id):shell"],
                relatedRecordIDs: []
            )

        case .createRecord(let filenameTemplate, let contentTemplate):
            let rawFilename = renderSkillTemplate(
                filenameTemplate.isEmpty ? "skill-note-{{date}}.txt" : filenameTemplate,
                input: input,
                request: originalRequest
            )
            let filename = normalizeCreateFilename(rawFilename)
            let content = renderSkillTemplate(contentTemplate, input: input, request: originalRequest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw PlannerError.apiError("Skill 输出内容为空，无法创建记录")
            }
            let record = try recordRepo.createTextRecord(text: content, filename: filename)
            return ActionOutput(
                reply: "Skill \(skill.name) 已创建记录：\(record.content.filename)（\(record.id)）",
                actions: ["skill.run:\(skill.id):create:\(record.id)"],
                relatedRecordIDs: [record.id]
            )

        case .appendToRecord(let recordRef, let contentTemplate):
            let renderedRef = renderSkillTemplate(
                recordRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TODAY" : recordRef,
                input: input,
                request: originalRequest
            )
            let content = renderSkillTemplate(contentTemplate, input: input, request: originalRequest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw PlannerError.apiError("Skill 追加内容为空")
            }
            let resolvedID = try resolveRecordReference(
                renderedRef,
                for: .append,
                request: originalRequest,
                createIfMissingContent: content
            )
            guard let record = try recordRepo.fetchByID(resolvedID) else {
                return ActionOutput(
                    reply: "Skill \(skill.name) 目标记录不存在：\(resolvedID)",
                    actions: ["skill.run:\(skill.id):append:not_found:\(resolvedID)"],
                    relatedRecordIDs: []
                )
            }
            guard record.content.fileType.isTextLike else {
                return ActionOutput(
                    reply: "Skill \(skill.name) 目标记录不是文本类型：\(resolvedID)",
                    actions: ["skill.run:\(skill.id):append:not_text:\(resolvedID)"],
                    relatedRecordIDs: [resolvedID]
                )
            }
            let current = try recordRepo.loadTextContent(record: record)
            let merged = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? content
                : current + "\n\n---\n\n" + content
            _ = try recordRepo.updateTextContent(recordID: resolvedID, text: merged)
            return ActionOutput(
                reply: "Skill \(skill.name) 已追加到记录 \(resolvedID)。",
                actions: ["skill.run:\(skill.id):append:\(resolvedID)"],
                relatedRecordIDs: [resolvedID]
            )
        }
    }

    private func renderSkillTemplate(_ template: String, input: String, request: String) -> String {
        var output = template
        output = output.replacingOccurrences(of: "{{input}}", with: input)
        output = output.replacingOccurrences(of: "{{request}}", with: request)
        output = output.replacingOccurrences(of: "{{date}}", with: dateFilenameStamp(Date()))
        output = output.replacingOccurrences(of: "{{timestamp}}", with: compactTimestamp())
        return output
    }

    private func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func runSkillShell(_ command: String) async throws -> String {
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
            throw PlannerError.apiError("Skill shell 执行失败（exit \(process.terminationStatus)）：\(shortText(output, limit: 300))")
        }
        return output
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

    private func extractRecordReference(_ text: String) -> String? {
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

    private func isPlaceholderRecordReference(_ raw: String) -> Bool {
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

    private func shouldCreateRecordIntent(lowerText: String) -> Bool {
        let blockedKeywords = [
            "删除", "delete", "移除",
            "追加", "append", "补充",
            "改写", "replace", "rewrite",
            "搜索", "检索", "查找", "search", "find",
            "task.run", "run task", "运行任务", "执行任务",
            "skill.run", "run skill", "运行技能", "执行技能", "skill list", "技能列表"
        ]
        if containsAnyKeyword(lowerText, keywords: blockedKeywords) {
            return false
        }

        let createKeywords = [
            "新建", "创建", "新增", "记录一下", "写一条", "记一条", "写个",
            "create", "new note", "new record", "capture", "log"
        ]
        if containsAnyKeyword(lowerText, keywords: createKeywords) {
            return true
        }

        let planKeywords = ["计划", "待办", "todo", "日程", "安排", "日志", "日记", "plan", "schedule"]
        if resolveDateReference(in: lowerText) != nil && containsAnyKeyword(lowerText, keywords: planKeywords) {
            return true
        }

        return false
    }

    private func extractCreateContent(_ text: String) -> String {
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

    private func extractCreateFilename(_ text: String) -> String? {
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

    private func normalizeCreateFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "note" : cleaned
        return base.contains(".") ? base : base + ".txt"
    }

    private func defaultCreateFilename(for request: String, date: Date? = nil) -> String {
        let lower = request.lowercased()
        let prefix: String
        if containsAnyKeyword(lower, keywords: ["计划", "待办", "todo", "plan", "schedule", "日程"]) {
            prefix = "plan"
        } else if containsAnyKeyword(lower, keywords: ["日志", "日记", "log", "journal"]) {
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

    private func resolveDateReference(in text: String) -> Date? {
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

    private func dateFilenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dateCompactStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
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

    private func extractTaskReference(_ text: String) -> String {
        if let uuid = extractRecordID(text) {
            return uuid
        }
        if let quoted = extractQuotedText(text) {
            return quoted
        }

        let patterns = ["task:", "任务:", "task ", "任务 "]
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

    private func extractSkillReference(_ text: String) -> String {
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

    private func containsAnyKeyword(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { keyword in
            text.range(of: keyword, options: .caseInsensitive) != nil
        }
    }

    private func minimalClarifyQuestion(for request: String) -> String? {
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
        if containsAnyKeyword(lower, keywords: deleteKeywords), recordReference == nil {
            return "请提供要删除的记录 ID（UUID 或 TODAY/明天），例如：删除记录 <record-id>。"
        }

        let appendKeywords = ["追加", "append", "补充"]
        if containsAnyKeyword(lower, keywords: appendKeywords) {
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
        if containsAnyKeyword(lower, keywords: replaceKeywords) {
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

        let taskKeywords = ["task.run", "run task", "运行任务", "执行任务"]
        if containsAnyKeyword(lower, keywords: taskKeywords), taskRef.isEmpty {
            return "请提供要运行的任务 ID 或任务名，例如：运行任务 <task-id>。"
        }

        let skillKeywords = ["skill.run", "run skill", "执行skill", "运行skill", "执行技能", "运行技能", "调用skill", "使用skill"]
        if containsAnyKeyword(lower, keywords: skillKeywords), skillRef.isEmpty {
            return "请提供要运行的 Skill ID 或名称，例如：运行 skill:daily-standup。"
        }

        return nil
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

    private func parseMergeStrategy(from request: String) -> CoreMergeStrategy? {
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

    private func resolveMergeStrategy(explicit: CoreMergeStrategy?, conflict: CoreConflictCandidate?) -> CoreMergeStrategy {
        if let explicit { return explicit }
        if conflict != nil { return .versioned }
        return .versioned
    }

    private func detectCoreConflict(request: String, reply: String, coreContext: [CoreContextItem]) -> CoreConflictCandidate? {
        let requestTokens = normalizedTokenSet(request)
        let replyTokens = normalizedTokenSet(reply)
        guard !requestTokens.isEmpty, !replyTokens.isEmpty else { return nil }

        var best: CoreConflictCandidate?
        for item in coreContext.prefix(12) {
            let oldRequest = extractMarkdownSection("Request", in: item.snippet) ?? item.record.preview
            let oldReply = extractMarkdownSection("Decision / Reply", in: item.snippet)
                ?? extractMarkdownSection("Reply", in: item.snippet)
                ?? item.snippet

            let requestSimilarity = jaccardSimilarity(requestTokens, normalizedTokenSet(oldRequest))
            let replySimilarity = jaccardSimilarity(replyTokens, normalizedTokenSet(oldReply))
            let score = requestSimilarity * (1 - replySimilarity)

            guard requestSimilarity >= 0.34, replySimilarity <= 0.62, score >= 0.22 else { continue }
            if let current = best {
                if score > current.score {
                    best = CoreConflictCandidate(recordID: item.record.id, score: score)
                }
            } else {
                best = CoreConflictCandidate(recordID: item.record.id, score: score)
            }
        }

        return best
    }

    private func extractMarkdownSection(_ title: String, in markdown: String) -> String? {
        let marker = "## \(title)"
        guard let start = markdown.range(of: marker) else { return nil }
        let tail = String(markdown[start.upperBound...])
        let raw = tail.components(separatedBy: "\n## ").first ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func normalizedTokenSet(_ text: String, maxTokens: Int = 64) -> Set<String> {
        let parts = text.lowercased().split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_")
        }
        let filtered = parts.map(String.init).filter { !$0.isEmpty }
        if filtered.isEmpty { return [] }
        return Set(filtered.prefix(maxTokens))
    }

    private func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func appendNotice(_ base: String, _ notice: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotice = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotice.isEmpty else { return trimmedBase }
        guard !trimmedBase.isEmpty else { return trimmedNotice }
        return "\(trimmedBase)\n\n\(trimmedNotice)"
    }

    private func shouldPersistCoreMemory(
        request: String,
        reply: String,
        actions: [String],
        relatedRecordIDs: [String],
        confirmationRequired: Bool,
        succeeded: Bool,
        explicitMergeStrategy: CoreMergeStrategy?
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
        if containsAnyKeyword(lower, keywords: memoryKeywords) {
            return true
        }

        if actions.contains(where: isCoreActionWorthPersisting) {
            return true
        }

        let normalizedReply = shortText(reply, limit: 240).lowercased()
        if (normalizedReply.contains("结论") || normalizedReply.contains("decision")) && !relatedRecordIDs.isEmpty {
            return true
        }

        return false
    }

    private func isCoreActionWorthPersisting(_ action: String) -> Bool {
        if action.hasPrefix("record.create:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.append:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.replace:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("record.delete:") && action.hasSuffix(":ok") { return true }
        if action.hasPrefix("task.run:") && action.hasSuffix(":success") { return true }
        if action.hasPrefix("skill.run:") && (action.contains(":create:") || action.contains(":append:")) { return true }
        return false
    }

    private func appendToDailyAssistantRecord(tagID: String, prefix: String, entry: String) throws -> Record {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(prefix)-\(dateFilenameStamp(Date())).txt"
        if let existed = try findAssistantDailyRecord(tagID: tagID, filename: filename) {
            let current = try recordRepo.loadTextContent(record: existed)
            let merged = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? trimmed
                : current + "\n\n---\n\n" + trimmed
            if let updated = try recordRepo.updateTextContent(recordID: existed.id, text: merged) {
                return updated
            }
            return existed
        }
        return try recordRepo.createTextRecord(
            text: trimmed,
            filename: filename,
            tags: [tagID],
            visibility: .private
        )
    }

    private func findAssistantDailyRecord(tagID: String, filename: String) throws -> Record? {
        var filter = RecordFilter()
        filter.tagIDs = [tagID]
        filter.tagMatchAny = true
        let records = try recordRepo.fetchAll(filter: filter)
        return records.first { record in
            record.content.fileType.isTextLike
                && record.content.filename.caseInsensitiveCompare(filename) == .orderedSame
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
        coreContextRecordIDs: [String],
        mergeStrategy: String,
        conflictRecordID: String?,
        conflictScore: Double?
    ) -> String {
        let keyActions = actions.filter(isCoreActionWorthPersisting)
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
