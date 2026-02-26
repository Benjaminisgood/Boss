import Foundation
import Combine

// MARK: - SchedulerService (Boss Jobs 调度器)
final class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    private let taskRepo = TaskRepository()
    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
    private var timer: Timer?
    private let checkInterval: TimeInterval = 60
    private let coreTagPrimaryName = "Core"
    private let coreTagAliases = ["持久记忆", "core memory", "memory core"]

    @Published var isRunning = false

    private init() {}

    // MARK: - Lifecycle
    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkAndRunDueTasks()
        }
        if let timer {
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
        }
        checkAndRunDueTasks()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: - Check Due Tasks
    private func checkAndRunDueTasks() {
        guard let tasks = try? taskRepo.fetchAllTasks() else { return }
        let now = Date()
        for task in tasks where task.isEnabled {
            if task.nextRunAt == nil, let seeded = seedNextRunIfNeeded(task: task, now: now) {
                try? taskRepo.updateTask(seeded)
                continue
            }
            guard let nextRun = task.nextRunAt else { continue }
            if nextRun <= now {
                Task {
                    _ = await run(task: task, triggerReason: "scheduler.tick", eventRecord: nil)
                }
            }
        }
    }

    // MARK: - Run Task
    @discardableResult
    func run(
        task: TaskItem,
        triggerReason: String = "manual",
        eventRecord: Record? = nil
    ) async -> TaskItem.RunLog {
        var log = TaskItem.RunLog(
            taskID: task.id,
            startedAt: Date(),
            status: .running,
            output: ""
        )
        try? taskRepo.insertLog(log)

        do {
            let output = try await execute(
                action: task.action,
                task: task,
                triggerReason: triggerReason,
                eventRecord: eventRecord
            )
            log.output = output
            log.status = .success
        } catch {
            log.error = error.localizedDescription
            log.status = .failed
        }

        log.finishedAt = Date()
        try? taskRepo.insertLog(log)
        updateRunTimestamps(task: task, ranAt: log.finishedAt ?? Date())
        return log
    }

    // MARK: - Execute Action
    private func execute(
        action: TaskItem.TaskAction,
        task: TaskItem,
        triggerReason: String,
        eventRecord: Record?
    ) async throws -> String {
        switch action {
        case .openClawJob(
            let instructionTemplate,
            let instructionRecordRef,
            let includeCoreMemory,
            let includeSkillManifest
        ):
            return try await relayOpenClawJob(
                task: task,
                triggerReason: triggerReason,
                eventRecord: eventRecord,
                instructionTemplate: instructionTemplate,
                instructionRecordRef: instructionRecordRef,
                includeCoreMemory: includeCoreMemory,
                includeSkillManifest: includeSkillManifest
            )

        case .createRecord, .appendToRecord, .shellCommand, .claudeAPI:
            throw SchedulerError.localExecutionDisabled(
                "任务动作已切换为 OpenClaw Jobs；请改用 openClawJob（自然语言描述）。"
            )
        }
    }

    // MARK: - OpenClaw Relay
    private func relayOpenClawJob(
        task: TaskItem,
        triggerReason: String,
        eventRecord: Record?,
        instructionTemplate: String,
        instructionRecordRef: String?,
        includeCoreMemory: Bool,
        includeSkillManifest: Bool
    ) async throws -> String {
        let config = AppConfig.shared
        guard config.openClawRelayEnabled else {
            throw SchedulerError.openClawRelayDisabled
        }

        let endpoint = config.openClawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw SchedulerError.missingOpenClawEndpoint
        }

        var instruction = renderInstructionTemplate(
            instructionTemplate,
            task: task,
            eventRecord: eventRecord
        )
        if let appended = try resolveInstructionFromRecord(
            reference: instructionRecordRef,
            eventRecord: eventRecord
        ) {
            if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                instruction += "\n\n"
            }
            instruction += appended
        }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw SchedulerError.emptyInstruction
        }

        let coreContext: [[String: Any]]
        if includeCoreMemory {
            coreContext = try loadCoreContext(limit: 8)
        } else {
            coreContext = []
        }

        let triggerPayload: [String: Any] = [
            "kind": triggerReason,
            "fired_at": iso8601(Date()),
            "task_trigger": describeTrigger(task.trigger)
        ]

        var payload: [String: Any] = [
            "request_id": UUID().uuidString,
            "mode": "boss_job_heartbeat",
            "assistant_mode": "conversation_only",
            "job_type": "openclaw.task",
            "task": [
                "id": task.id,
                "name": task.name,
                "description": task.description,
                "enabled": task.isEnabled,
                "trigger": describeTrigger(task.trigger)
            ],
            "trigger": triggerPayload,
            "instruction": trimmedInstruction,
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
            "core_context": coreContext
        ]

        if includeSkillManifest {
            payload["skills_manifest"] = SkillManifestService.shared.loadManifestText()
        }

        if let eventRecord {
            payload["event_record"] = [
                "record_id": eventRecord.id,
                "filename": eventRecord.content.filename,
                "preview": shortText(eventRecord.preview, limit: 260),
                "updated_at": iso8601(eventRecord.updatedAt),
                "tags": eventRecord.tags
            ]
        }

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = config.openClawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200...299).contains(statusCode) else {
            let clipped = shortText(responseText, limit: 260)
            throw SchedulerError.apiError("OpenClaw HTTP \(statusCode): \(clipped)")
        }

        return "OpenClaw Job 已投递（\(statusCode)）。响应：\(shortText(responseText.isEmpty ? "ok" : responseText, limit: 260))"
    }

    private func renderInstructionTemplate(
        _ template: String,
        task: TaskItem,
        eventRecord: Record?
    ) -> String {
        var output = template
        let eventText = eventRecord.flatMap { try? loadRecordText($0, limit: 20_000) } ?? ""
        let replacements: [String: String] = [
            "{{task_name}}": task.name,
            "{{task_description}}": task.description,
            "{{date}}": dateString(Date()),
            "{{timestamp}}": timestampString(Date()),
            "{{record_id}}": eventRecord?.id ?? "",
            "{{record_filename}}": eventRecord?.content.filename ?? "",
            "{{record_preview}}": eventRecord?.preview ?? "",
            "{{record_text}}": eventText
        ]
        for (key, value) in replacements {
            output = output.replacingOccurrences(of: key, with: value)
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            任务名称：\(task.name)
            任务说明：\(task.description.isEmpty ? "-" : task.description)
            触发来源：\(describeTrigger(task.trigger))
            """
        }
        return output
    }

    private func resolveInstructionFromRecord(
        reference: String?,
        eventRecord: Record?
    ) throws -> String? {
        let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ref.isEmpty else { return nil }

        if ref.uppercased() == "EVENT_RECORD" {
            guard let eventRecord else { return nil }
            return try loadRecordText(eventRecord, limit: 60_000)
        }

        if let record = try recordRepo.fetchByID(ref) {
            return try loadRecordText(record, limit: 60_000)
        }

        var filter = RecordFilter()
        filter.searchText = ref
        let records = try recordRepo.fetchAll(filter: filter)
        if let first = records.first(where: { $0.content.filename == ref }) ?? records.first {
            return try loadRecordText(first, limit: 60_000)
        }
        throw SchedulerError.recordNotFound(ref)
    }

    private func loadRecordText(_ record: Record, limit: Int) throws -> String {
        guard record.content.fileType.isTextLike else {
            throw SchedulerError.recordNotText(record.id)
        }
        return try recordRepo.loadTextContent(record: record, maxBytes: limit)
    }

    private func loadCoreContext(limit: Int) throws -> [[String: Any]] {
        guard let coreTagID = try findTagID(primaryName: coreTagPrimaryName, aliases: coreTagAliases) else {
            return []
        }
        var filter = RecordFilter()
        filter.tagIDs = [coreTagID]
        filter.tagMatchAny = true
        filter.showArchived = true
        let records = try recordRepo.fetchAll(filter: filter)
        return records.prefix(limit).map { record in
            let snippet: String
            if record.content.fileType.isTextLike {
                let text = (try? recordRepo.loadTextContent(record: record, maxBytes: 80_000)) ?? record.preview
                snippet = shortText(text, limit: 400)
            } else {
                snippet = shortText(record.preview, limit: 220)
            }
            return [
                "record_id": record.id,
                "filename": record.content.filename,
                "snippet": snippet,
                "updated_at": iso8601(record.updatedAt)
            ]
        }
    }

    private func findTagID(primaryName: String, aliases: [String]) throws -> String? {
        let tags = try tagRepo.fetchAll()
        let names = Set(([primaryName] + aliases).map { normalizeTagName($0) })
        return tags.first(where: { names.contains(normalizeTagName($0.name)) })?.id
    }

    private func normalizeTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Schedule State
    private func updateRunTimestamps(task: TaskItem, ranAt: Date) {
        var updated = task
        updated.lastRunAt = ranAt
        switch task.trigger {
        case .manual, .onRecordCreate, .onRecordUpdate:
            updated.nextRunAt = nil
        case .cron(let expression):
            updated.nextRunAt = CronParser.nextDate(expression: expression, after: ranAt)
        case .heartbeat(let intervalMinutes):
            let safeInterval = max(1, intervalMinutes)
            updated.nextRunAt = Calendar.current.date(byAdding: .minute, value: safeInterval, to: ranAt)
        }
        try? taskRepo.updateTask(updated)
    }

    private func seedNextRunIfNeeded(task: TaskItem, now: Date) -> TaskItem? {
        var updated = task
        switch task.trigger {
        case .cron(let expression):
            updated.nextRunAt = CronParser.nextDate(expression: expression, after: now)
        case .heartbeat(let intervalMinutes):
            let safeInterval = max(1, intervalMinutes)
            updated.nextRunAt = Calendar.current.date(byAdding: .minute, value: safeInterval, to: now)
        case .manual, .onRecordCreate, .onRecordUpdate:
            return nil
        }
        return updated
    }

    private func describeTrigger(_ trigger: TaskItem.Trigger) -> String {
        switch trigger {
        case .manual:
            return "manual"
        case .heartbeat(let intervalMinutes):
            return "heartbeat/\(max(1, intervalMinutes))m"
        case .cron(let expression):
            return "cron/\(expression)"
        case .onRecordCreate(let tagFilter):
            return tagFilter.isEmpty ? "on_record_create" : "on_record_create(tags=\(tagFilter.joined(separator: ",")))"
        case .onRecordUpdate(let tagFilter):
            return tagFilter.isEmpty ? "on_record_update" : "on_record_update(tags=\(tagFilter.joined(separator: ",")))"
        }
    }

    private func shortText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "..."
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Errors
enum SchedulerError: LocalizedError {
    case openClawRelayDisabled
    case missingOpenClawEndpoint
    case emptyInstruction
    case localExecutionDisabled(String)
    case recordNotFound(String)
    case recordNotText(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .openClawRelayDisabled:
            return "OpenClaw relay disabled"
        case .missingOpenClawEndpoint:
            return "Missing OpenClaw endpoint"
        case .emptyInstruction:
            return "OpenClaw job instruction is empty"
        case .localExecutionDisabled(let detail):
            return detail
        case .recordNotFound(let id):
            return "Record not found: \(id)"
        case .recordNotText(let id):
            return "Record is not text-like: \(id)"
        case .apiError(let message):
            return "OpenClaw API error: \(message)"
        }
    }
}

// MARK: - CronParser (支持完整的 5 字段 cron 表达式)
struct CronParser {
    /// 返回 expression 之后下一次触发时间
    static func nextDate(expression: String, after date: Date) -> Date? {
        let components = expression.split(separator: " ").map(String.init)
        guard components.count == 5 else { return nil }

        let calendar = Calendar.current
        var currentDate = calendar.date(byAdding: .minute, value: 1, to: date) ?? date

        // 最多尝试 1000 次，避免无限循环
        for _ in 0..<1000 {
            if matches(expression: expression, date: currentDate) {
                return currentDate
            }
            currentDate = calendar.date(byAdding: .minute, value: 1, to: currentDate) ?? currentDate
        }

        return nil
    }

    /// 检查日期是否匹配 cron 表达式
    private static func matches(expression: String, date: Date) -> Bool {
        let components = expression.split(separator: " ").map(String.init)
        guard components.count == 5 else { return false }

        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)

        // 周几：1-7 (1=周日)
        let weekday = dateComponents.weekday ?? 1

        return matchesField(components[0], value: dateComponents.minute ?? 0, min: 0, max: 59) &&
               matchesField(components[1], value: dateComponents.hour ?? 0, min: 0, max: 23) &&
               matchesField(components[2], value: dateComponents.day ?? 1, min: 1, max: 31) &&
               matchesField(components[3], value: dateComponents.month ?? 1, min: 1, max: 12) &&
               matchesField(components[4], value: weekday == 1 ? 7 : weekday - 1, min: 1, max: 7)
    }

    /// 检查单个字段是否匹配
    private static func matchesField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        if field == "*" {
            return true
        }

        // 处理列表: 1,3,5
        if field.contains(",") {
            let values = field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return values.contains { $0 == "*" || matchesSingleField($0, value: value, min: min, max: max) }
        }

        return matchesSingleField(field, value: value, min: min, max: max)
    }

    /// 检查单个字段的单个部分是否匹配
    private static func matchesSingleField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        // 处理范围: 1-5
        if field.contains("-") {
            let range = field.split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]) else {
                return false
            }
            return value >= start && value <= end
        }

        // 处理步长: */5 或 1/5
        if field.contains("/") {
            let stepParts = field.split(separator: "/")
            guard stepParts.count == 2, let step = Int(stepParts[1]), step > 0 else {
                return false
            }

            if stepParts[0] == "*" {
                return (value - min) % step == 0
            } else if let start = Int(stepParts[0]) {
                return value >= start && (value - start) % step == 0
            }
            return false
        }

        // 处理单个值
        guard let intValue = Int(field) else { return false }
        return intValue >= min && intValue <= max && intValue == value
    }
}
