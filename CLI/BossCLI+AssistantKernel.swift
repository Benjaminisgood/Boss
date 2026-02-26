import Foundation
import SQLite3

extension BossCLI {
    struct CLIAssistantResult {
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

    struct CLIAssistantContextItem {
        let id: String
        let filename: String
        let snippet: String
        let updatedAt: Double
        let score: Int
    }

    enum CLIAssistantIntent {
        case help
        case summarizeCore
        case answer(question: String)
        case skillsCatalog
        case skillRun(skillRef: String, input: String)
        case search(String)
        case create(filename: String, content: String)
        case taskRun(String)
        case delete(String)
        case append(recordID: String, content: String)
        case replace(recordID: String, content: String)
        case unknown(String)

        var description: String {
            switch self {
            case .help: return "help"
            case .summarizeCore: return "summarizeCore"
            case .answer(let question): return "answer(\(question))"
            case .skillsCatalog: return "skillsCatalog"
            case .skillRun(let skillRef, _): return "skillRun(\(skillRef))"
            case .search(let query): return "search(\(query))"
            case .create(let filename, _): return "create(\(filename))"
            case .taskRun(let ref): return "taskRun(\(ref))"
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

    enum CLIAssistantToolRiskLevel: String, Codable {
        case low
        case medium
        case high
    }

    struct CLIAssistantToolCall: Codable {
        let name: String
        let arguments: [String: String]

        init(name: String, arguments: [String: String] = [:]) {
            self.name = name
            self.arguments = arguments
        }
    }

    struct CLIAssistantToolSpec {
        let name: String
        let description: String
        let requiredArguments: [String]
        let riskLevel: CLIAssistantToolRiskLevel
    }

    struct CLIAssistantPlannedToolCalls {
        let calls: [CLIAssistantToolCall]
        let plannerSource: String
        let plannerNote: String?
        let toolPlan: [String]
        let clarifyQuestion: String?
    }

    struct CLIAssistantPendingIntent: Codable {
        let toolCalls: [CLIAssistantToolCall]
        let source: String
        let request: String
        let toolPlan: [String]
        let createdAt: Double
        let expiresAt: Double
    }

    enum CLIAssistantCoreMergeStrategy: String {
        case overwrite
        case keep
        case versioned
    }

    struct CLIAssistantCoreConflict {
        let recordID: String
        let score: Double
    }

    func runAssistantKernel(request: String, source: String) async throws -> CLIAssistantResult {
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
        var mergeStrategyUsed: CLIAssistantCoreMergeStrategy = .versioned
        let conflictRecordID: String? = nil
        let conflictScore: Double? = nil

        do {
            let coreTagID = try ensureTag(name: "Core", aliases: ["持久记忆", "core memory"], color: "#0A84FF", icon: "brain.head.profile")
            let auditTagID = try ensureTag(name: "AuditLog", aliases: ["audit", "audit log", "审计"], color: "#FF9F0A", icon: "doc.text.magnifyingglass")
            actions.append("tag.ensure:Core")
            actions.append("tag.ensure:AuditLog")

            let coreContext = try loadCoreContext(coreTagID: coreTagID, request: cleanedRequest, limit: 20)
            coreContextRecordIDs = coreContext.map { $0.id }
            actions.append("context.load:\(coreContext.count)")

            let confirmationAttempt = try consumePendingConfirmationIfProvided(request: cleanedRequest, source: source)
            if let token = confirmationAttempt.token, confirmationAttempt.toolCalls == nil {
                intentDescription = "confirm.invalid(\(token))"
                plannerSource = "confirmation-token"
                plannerNote = "确认令牌无效、来源不匹配或已过期。"
                toolPlan = ["validate-confirmation-token"]
                reply = "确认令牌无效、来源不匹配或已过期。请重新发起删除/改写请求获取新的确认令牌。"
                actions.append("confirm.invalid:\(token)")
                succeeded = false
            } else {
                let confirmedToolCalls = confirmationAttempt.toolCalls
                let planned: CLIAssistantPlannedToolCalls
                if let confirmedToolCalls {
                    planned = CLIAssistantPlannedToolCalls(
                        calls: confirmedToolCalls,
                        plannerSource: "confirmation-token",
                        plannerNote: "已使用确认令牌执行高风险动作。",
                        toolPlan: defaultAssistantToolPlan(for: confirmedToolCalls),
                        clarifyQuestion: nil
                    )
                    intentDescription = "\(describeAssistantToolCalls(confirmedToolCalls, fallbackRequest: cleanedRequest)) [confirmed]"
                    plannerSource = "confirmation-token"
                    plannerNote = "已使用确认令牌执行高风险动作。"
                    toolPlan = planned.toolPlan
                    if let token = confirmationAttempt.token {
                        actions.append("confirm.consume:\(token)")
                    }
                } else {
                    planned = try await planAssistantToolCalls(cleanedRequest, coreContext: coreContext)
                    intentDescription = describeAssistantToolCalls(planned.calls, fallbackRequest: cleanedRequest)
                    plannerSource = planned.plannerSource
                    plannerNote = planned.plannerNote
                    toolPlan = planned.toolPlan
                    actions.append("plan:\(plannerSource)")
                }

                if let clarify = planned.clarifyQuestion, planned.calls.isEmpty {
                    reply = clarify
                    actions.append("clarify.ask")
                    succeeded = true
                } else if requiresConfirmation(toolCalls: planned.calls) && confirmedToolCalls == nil {
                    let pending = try savePendingConfirmation(toolCalls: planned.calls, request: cleanedRequest, source: source, toolPlan: toolPlan)
                    confirmationRequired = true
                    confirmationToken = pending.token
                    confirmationExpiresAt = pending.expiresAt
                    relatedRecordIDs = relatedRecordIDsFromToolCalls(planned.calls)
                    let dryRunPreview = try buildAssistantDryRunPreview(toolCalls: planned.calls)
                    reply = buildAssistantConfirmationReply(toolCalls: planned.calls, token: pending.token, expiresAt: pending.expiresAt, dryRunPreview: dryRunPreview)
                    actions.append("confirm.required:\(pending.token)")
                    actions.append("dryrun.preview:\(planned.calls.count)")
                    succeeded = true
                } else {
                    let output = try await executeAssistantToolCalls(planned.calls, request: cleanedRequest, coreContext: coreContext)
                    reply = output.reply
                    actions.append(contentsOf: output.actions)
                    relatedRecordIDs = output.relatedRecordIDs
                    succeeded = true
                }
            }

            let explicitMergeStrategy = parseAssistantMergeStrategy(from: cleanedRequest)
            if let explicitMergeStrategy {
                actions.append("memory.merge.requested:\(explicitMergeStrategy.rawValue)")
            }
            mergeStrategyUsed = explicitMergeStrategy ?? .versioned
            actions.append("memory.merge.use:\(mergeStrategyUsed.rawValue)")

            let shouldWriteMemory = shouldPersistAssistantCoreMemory(
                request: cleanedRequest,
                reply: reply,
                actions: actions,
                relatedRecordIDs: relatedRecordIDs,
                confirmationRequired: confirmationRequired,
                succeeded: succeeded,
                explicitMergeStrategy: explicitMergeStrategy
            )
            if shouldWriteMemory {
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
                    coreContextRecordIDs: coreContextRecordIDs,
                    mergeStrategy: mergeStrategyUsed.rawValue,
                    conflictRecordID: conflictRecordID,
                    conflictScore: conflictScore
                )
                coreMemoryRecordID = try appendAssistantDailyRecord(
                    tagID: coreTagID,
                    prefix: "assistant-core",
                    entry: coreMemoryText
                )
                actions.append("memory.append:\(coreMemoryRecordID ?? "-")")
            } else {
                actions.append("memory.skip:low_signal")
            }

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
                confirmationExpiresAt: confirmationExpiresAt,
                mergeStrategy: mergeStrategyUsed.rawValue,
                conflictRecordID: conflictRecordID,
                conflictScore: conflictScore
            )
            auditRecordID = try appendAssistantDailyRecord(
                tagID: auditTagID,
                prefix: "assistant-audit",
                entry: auditText
            )
            actions.append("audit.append:\(auditRecordID ?? "-")")
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
                    confirmationExpiresAt: confirmationExpiresAt,
                    mergeStrategy: mergeStrategyUsed.rawValue,
                    conflictRecordID: conflictRecordID,
                    conflictScore: conflictScore
                )
                auditRecordID = try? appendAssistantDailyRecord(
                    tagID: auditTagID,
                    prefix: "assistant-audit",
                    entry: failedAudit
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

    struct CLIAssistantOutput {
        let reply: String
        let actions: [String]
        let relatedRecordIDs: [String]
    }

    func assistantToolSpecs() -> [CLIAssistantToolSpec] {
        [
            CLIAssistantToolSpec(name: "assistant.help", description: "输出助理能力说明", requiredArguments: [], riskLevel: .low),
            CLIAssistantToolSpec(name: "core.summarize", description: "总结 Core 持久记忆上下文", requiredArguments: [], riskLevel: .low),
            CLIAssistantToolSpec(name: "assistant.answer", description: "基于 Core/审计/技能上下文回答问题，参数 question", requiredArguments: ["question"], riskLevel: .low),
            CLIAssistantToolSpec(name: "skills.catalog", description: "读取 Skill 清单与基础接口文档", requiredArguments: [], riskLevel: .low),
            CLIAssistantToolSpec(name: "record.search", description: "检索记录，参数 query", requiredArguments: ["query"], riskLevel: .low),
            CLIAssistantToolSpec(name: "record.create", description: "创建文本记录，参数 content，可选 filename", requiredArguments: ["content"], riskLevel: .low),
            CLIAssistantToolSpec(name: "task.run", description: "运行已有任务，参数 task_ref（任务ID或任务名）", requiredArguments: ["task_ref"], riskLevel: .high),
            CLIAssistantToolSpec(name: "skill.run", description: "运行已注册 Skill，参数 skill_ref，可选 input", requiredArguments: ["skill_ref"], riskLevel: .medium),
            CLIAssistantToolSpec(name: "record.delete", description: "删除记录，参数 record_id", requiredArguments: ["record_id"], riskLevel: .high),
            CLIAssistantToolSpec(name: "record.append", description: "向文本记录追加内容，参数 record_id/content", requiredArguments: ["record_id", "content"], riskLevel: .medium),
            CLIAssistantToolSpec(name: "record.replace", description: "改写文本记录内容，参数 record_id/content", requiredArguments: ["record_id", "content"], riskLevel: .high)
        ]
    }

    func assistantToolSpec(named name: String) -> CLIAssistantToolSpec? {
        assistantToolSpecs().first { $0.name == name }
    }

    func defaultAssistantToolPlan(for calls: [CLIAssistantToolCall]) -> [String] {
        if calls.isEmpty {
            return ["fallback-search", "request-disambiguation"]
        }
        return calls.enumerated().map { index, call in
            "\(index + 1). \(call.name)"
        }
    }

    func overrideAssistantLLMPlannedCallsIfNeeded(request: String, plannedCalls: [CLIAssistantToolCall]) -> [CLIAssistantToolCall]? {
        let lower = request.lowercased()
        let hasWriteCall = plannedCalls.contains { call in
            ["record.create", "record.delete", "record.append", "record.replace"].contains(call.name)
        }
        let searchOnly = !plannedCalls.isEmpty && plannedCalls.allSatisfy { $0.name == "record.search" }
        if !hasWriteCall, (searchOnly || plannedCalls.isEmpty), shouldTreatAsAssistantQuestion(request) {
            return [CLIAssistantToolCall(name: "assistant.answer", arguments: ["question": request])]
        }
        guard !hasWriteCall, searchOnly || plannedCalls.isEmpty else {
            return nil
        }

        let payload = extractPayload(request)
        if containsAssistantKeyword(lower, keywords: ["追加", "append", "补充"]),
           !payload.isEmpty,
           let reference = extractRecordReference(request) {
            return [CLIAssistantToolCall(name: "record.append", arguments: ["record_id": reference, "content": payload])]
        }

        let createContent = extractCreateContent(request)
        if shouldCreateRecordIntent(lowerText: lower), !createContent.isEmpty {
            let filename = extractCreateFilename(request) ?? defaultCreateFilename(for: request)
            return [CLIAssistantToolCall(name: "record.create", arguments: ["filename": filename, "content": createContent])]
        }

        return nil
    }

}
