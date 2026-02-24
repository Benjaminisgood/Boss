import Foundation

// MARK: - AgentRepository
final class AgentRepository {
    private let db = DatabaseManager.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Tasks
    func createTask(_ task: AgentTask) throws {
        let triggerJSON = (try? encoder.encode(task.trigger)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let actionJSON  = (try? encoder.encode(task.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            INSERT INTO agent_tasks (id, name, description, template_id, trigger_json, action_json,
            is_enabled, last_run_at, next_run_at, created_at, output_tag_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(task.id), .text(task.name), .text(task.description),
                task.templateID.map { .text($0) } ?? .null,
                .text(triggerJSON), .text(actionJSON),
                .integer(task.isEnabled ? 1 : 0),
                task.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.nextRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(task.createdAt.timeIntervalSince1970),
                task.outputTagID.map { .text($0) } ?? .null
            ])
    }

    func fetchAllTasks() throws -> [AgentTask] {
        try db.read("SELECT * FROM agent_tasks ORDER BY created_at DESC", bindings: [], map: mapTaskRow)
    }

    func updateTask(_ task: AgentTask) throws {
        let triggerJSON = (try? encoder.encode(task.trigger)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let actionJSON  = (try? encoder.encode(task.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            UPDATE agent_tasks SET name=?, description=?, template_id=?, trigger_json=?, action_json=?,
            is_enabled=?, last_run_at=?, next_run_at=?, output_tag_id=? WHERE id=?
            """, bindings: [
                .text(task.name), .text(task.description),
                task.templateID.map { .text($0) } ?? .null,
                .text(triggerJSON), .text(actionJSON),
                .integer(task.isEnabled ? 1 : 0),
                task.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.nextRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.outputTagID.map { .text($0) } ?? .null,
                .text(task.id)
            ])
    }

    func deleteTask(id: String) throws {
        try db.write("DELETE FROM agent_tasks WHERE id = ?", bindings: [.text(id)])
    }

    // MARK: - Run Logs
    func insertLog(_ log: AgentTask.RunLog) throws {
        try db.write("""
            INSERT OR REPLACE INTO agent_run_logs (id, task_id, started_at, finished_at, status, output, error)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(log.id), .text(log.taskID), .real(log.startedAt.timeIntervalSince1970),
                log.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(log.status.rawValue), .text(log.output),
                log.error.map { .text($0) } ?? .null
            ])
    }

    func fetchLogs(taskID: String, limit: Int = 50) throws -> [AgentTask.RunLog] {
        try db.read("""
            SELECT * FROM agent_run_logs WHERE task_id = ? ORDER BY started_at DESC LIMIT ?
            """, bindings: [.text(taskID), .integer(limit)], map: mapLogRow)
    }

    // MARK: - Mappers
    private func mapTaskRow(_ row: [String: SQLValue]) -> AgentTask? {
        guard
            let id = row["id"]?.stringValue,
            let name = row["name"]?.stringValue,
            let triggerJSON = row["trigger_json"]?.stringValue?.data(using: .utf8),
            let actionJSON  = row["action_json"]?.stringValue?.data(using: .utf8),
            let trigger = try? decoder.decode(AgentTask.Trigger.self, from: triggerJSON),
            let action  = try? decoder.decode(AgentTask.AgentAction.self, from: actionJSON),
            let createdAt = row["created_at"]?.doubleValue
        else { return nil }
        return AgentTask(
            id: id, name: name,
            description: row["description"]?.stringValue ?? "",
            templateID: row["template_id"]?.stringValue,
            trigger: trigger, action: action,
            isEnabled: row["is_enabled"]?.intValue == 1,
            lastRunAt: row["last_run_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            nextRunAt: row["next_run_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            createdAt: Date(timeIntervalSince1970: createdAt),
            outputTagID: row["output_tag_id"]?.stringValue
        )
    }

    private func mapLogRow(_ row: [String: SQLValue]) -> AgentTask.RunLog? {
        guard
            let id = row["id"]?.stringValue,
            let taskID = row["task_id"]?.stringValue,
            let startedAt = row["started_at"]?.doubleValue,
            let statusRaw = row["status"]?.stringValue,
            let status = AgentTask.RunLog.RunStatus(rawValue: statusRaw)
        else { return nil }
        return AgentTask.RunLog(
            id: id, taskID: taskID,
            startedAt: Date(timeIntervalSince1970: startedAt),
            finishedAt: row["finished_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            status: status,
            output: row["output"]?.stringValue ?? "",
            error: row["error"]?.stringValue
        )
    }
}
