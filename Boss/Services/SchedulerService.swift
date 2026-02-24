import Foundation
import Combine

// MARK: - SchedulerService (定时任务调度器)
final class SchedulerService: ObservableObject {
    static let shared = SchedulerService()

    private let agentRepo = AgentRepository()
    private var timer: Timer?
    private let checkInterval: TimeInterval = 60 // 每60秒检查一次

    @Published var isRunning = false

    private init() {}

    // MARK: - Lifecycle
    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkAndRunDueTasks()
        }
        timer?.tolerance = 10
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: - Check Due Tasks
    private func checkAndRunDueTasks() {
        guard let tasks = try? agentRepo.fetchAllTasks() else { return }
        let now = Date()
        for task in tasks where task.isEnabled {
            if let nextRun = task.nextRunAt, nextRun <= now {
                Task { await run(task: task) }
            }
        }
    }

    // MARK: - Run Task
    @discardableResult
    func run(task: AgentTask) async -> AgentTask.RunLog {
        var log = AgentTask.RunLog(
            taskID: task.id,
            startedAt: Date(),
            status: .running,
            output: ""
        )
        try? agentRepo.insertLog(log)

        do {
            let output = try await execute(action: task.action, task: task)
            log.output = output
            log.status = .success
        } catch {
            log.error = error.localizedDescription
            log.status = .failed
        }

        log.finishedAt = Date()
        try? agentRepo.insertLog(log) // upsert via replace
        updateNextRunTime(task: task)
        return log
    }

    // MARK: - Execute Action
    private func execute(action: AgentTask.AgentAction, task: AgentTask) async throws -> String {
        switch action {
        case .createRecord(let title, let template):
            let filename = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "agent-log.txt" : "\(title).txt"
            let record = try RecordRepository().createTextRecord(text: template, filename: filename, tags: [], visibility: .private)
            return "Created record: \(record.id)"

        case .appendToRecord(let recordID, let template):
            let repo = RecordRepository()
            guard let record = try repo.fetchByID(recordID) else {
                throw SchedulerError.recordNotFound(recordID)
            }
            guard record.content.fileType.isTextLike else {
                throw SchedulerError.recordNotText(recordID)
            }
            let current = try repo.loadTextContent(record: record)
            let nextText = current + "\n\n---\n\n" + template
            _ = try repo.updateTextContent(recordID: recordID, text: nextText)
            return "Appended to record: \(recordID)"

        case .shellCommand(let command):
            return try await runShell(command: command)

        case .claudeAPI(let system, let userPrompt, let model):
            return try await callLLMAPI(system: system, userPrompt: userPrompt, modelIdentifier: model)
        }
    }

    private func runShell(command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private enum LLMProvider: String {
        case claude
        case openai
        case aliyun
    }

    private func callLLMAPI(system: String, userPrompt: String, modelIdentifier: String) async throws -> String {
        let resolved = parseModelIdentifier(modelIdentifier)
        switch resolved.provider {
        case .claude:
            return try await callClaudeAPI(system: system, userPrompt: userPrompt, model: resolved.model)
        case .openai:
            return try await callOpenAIAPI(system: system, userPrompt: userPrompt, model: resolved.model)
        case .aliyun:
            return try await callAliyunAPI(system: system, userPrompt: userPrompt, model: resolved.model)
        }
    }

    private func parseModelIdentifier(_ identifier: String) -> (provider: LLMProvider, model: String) {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return (.claude, "claude-sonnet-4-6") }

        if let separator = raw.firstIndex(of: ":"), separator > raw.startIndex, separator < raw.index(before: raw.endIndex) {
            let providerRaw = String(raw[..<separator]).lowercased()
            let model = String(raw[raw.index(after: separator)...])
            if let provider = LLMProvider(rawValue: providerRaw) {
                return (provider, model)
            }
        }

        let lower = raw.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return (.openai, raw)
        }
        if lower.hasPrefix("qwen") {
            return (.aliyun, raw)
        }
        return (.claude, raw)
    }

    private func callClaudeAPI(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.claudeAPIKey
        guard !apiKey.isEmpty else {
            throw SchedulerError.missingAPIKey(provider: "Claude")
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
            throw SchedulerError.invalidResponse
        }

        let texts = content.compactMap { item in
            item["text"] as? String
        }
        guard !texts.isEmpty else {
            throw SchedulerError.invalidResponse
        }
        return texts.joined(separator: "\n")
    }

    private func callOpenAIAPI(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw SchedulerError.missingAPIKey(provider: "OpenAI")
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

    private func callAliyunAPI(system: String, userPrompt: String, model: String) async throws -> String {
        let apiKey = AppConfig.shared.aliyunAPIKey
        guard !apiKey.isEmpty else {
            throw SchedulerError.missingAPIKey(provider: "阿里云")
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
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SchedulerError.apiError(message)
        }
        return data
    }

    private func parseOpenAICompatibleText(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw SchedulerError.invalidResponse
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

        throw SchedulerError.invalidResponse
    }

    // MARK: - Cron Next Run
    private func updateNextRunTime(task: AgentTask) {
        guard case .cron(let expr) = task.trigger else { return }
        var updated = task
        updated.lastRunAt = Date()
        updated.nextRunAt = CronParser.nextDate(expression: expr, after: Date())
        try? agentRepo.updateTask(updated)
    }
}

// MARK: - Errors
enum SchedulerError: LocalizedError {
    case recordNotFound(String)
    case recordNotText(String)
    case missingAPIKey(provider: String)
    case apiError(String)
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .recordNotFound(let id): return "Record not found: \(id)"
        case .recordNotText(let id): return "Record is not text-like: \(id)"
        case .missingAPIKey(let provider): return "Missing \(provider) API key"
        case .apiError(let message): return "API error: \(message)"
        case .invalidResponse: return "Invalid API response"
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
               matchesField(components[4], value: weekday == 1 ? 7 : weekday - 1, min: 1, max: 7) // 转换为 1-7 (1=周一)
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
        
        // 处理步长: */5 或 1-10/2
        if field.contains("/") {
            let parts = field.split(separator: "/")
            guard parts.count == 2, let step = Int(parts[1]) else {
                return false
            }
            
            if parts[0] == "*" {
                return value % step == 0
            }
            
            if parts[0].contains("-") {
                let range = parts[0].split(separator: "-")
                guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]) else {
                    return false
                }
                if value < start || value > end {
                    return false
                }
                return (value - start) % step == 0
            }
        }
        
        // 处理具体值
        if let fieldValue = Int(field) {
            return value == fieldValue
        }
        
        return false
    }
}
