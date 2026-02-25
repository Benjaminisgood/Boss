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

    // MARK: - Skills
    func createSkill(_ skill: ProjectSkill) throws {
        let actionJSON = (try? encoder.encode(skill.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            INSERT INTO assistant_skills (id, name, description, trigger_hint, action_json, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(skill.id),
                .text(skill.name),
                .text(skill.description),
                .text(skill.triggerHint),
                .text(actionJSON),
                .integer(skill.isEnabled ? 1 : 0),
                .real(skill.createdAt.timeIntervalSince1970),
                .real(skill.updatedAt.timeIntervalSince1970)
            ])
        scheduleSkillManifestRefresh()
    }

    func fetchAllSkills() throws -> [ProjectSkill] {
        try db.read("SELECT * FROM assistant_skills ORDER BY created_at DESC", bindings: [], map: mapSkillRow)
    }

    func fetchEnabledSkills() throws -> [ProjectSkill] {
        try db.read(
            "SELECT * FROM assistant_skills WHERE is_enabled = 1 ORDER BY created_at DESC",
            bindings: [],
            map: mapSkillRow
        )
    }

    func updateSkill(_ skill: ProjectSkill) throws {
        let actionJSON = (try? encoder.encode(skill.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            UPDATE assistant_skills SET
            name = ?, description = ?, trigger_hint = ?, action_json = ?, is_enabled = ?, updated_at = ?
            WHERE id = ?
            """, bindings: [
                .text(skill.name),
                .text(skill.description),
                .text(skill.triggerHint),
                .text(actionJSON),
                .integer(skill.isEnabled ? 1 : 0),
                .real(skill.updatedAt.timeIntervalSince1970),
                .text(skill.id)
            ])
        scheduleSkillManifestRefresh()
    }

    func deleteSkill(id: String) throws {
        try db.write("DELETE FROM assistant_skills WHERE id = ?", bindings: [.text(id)])
        scheduleSkillManifestRefresh()
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

    private func mapSkillRow(_ row: [String: SQLValue]) -> ProjectSkill? {
        guard
            let id = row["id"]?.stringValue,
            let name = row["name"]?.stringValue,
            let triggerHint = row["trigger_hint"]?.stringValue,
            let actionJSON = row["action_json"]?.stringValue?.data(using: .utf8),
            let action = try? decoder.decode(ProjectSkill.SkillAction.self, from: actionJSON),
            let createdAt = row["created_at"]?.doubleValue,
            let updatedAt = row["updated_at"]?.doubleValue
        else { return nil }

        return ProjectSkill(
            id: id,
            name: name,
            description: row["description"]?.stringValue ?? "",
            triggerHint: triggerHint,
            action: action,
            isEnabled: row["is_enabled"]?.intValue == 1,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func scheduleSkillManifestRefresh() {
        Task { @MainActor in
            SkillManifestService.shared.refreshManifestSilently()
        }
    }
}

// MARK: - Skill Manifest
final class SkillManifestService {
    static let shared = SkillManifestService()

    private let agentRepo = AgentRepository()
    private let tagRepo = TagRepository()
    private let recordRepo = RecordRepository()
    private let manifestFilename = "assistant-skill-manifest.md"
    private let skillTagPrimaryName = "SkillPack"
    private let skillTagAliases = ["技能包", "skill package", "skills"]

    private init() {}

    func refreshManifestSilently() {
        _ = try? refreshManifest()
    }

    @discardableResult
    func refreshManifest() throws -> String? {
        let skills = try agentRepo.fetchAllSkills()
        let skillTag = try ensureSkillTag()
        let manifestText = buildManifestText(skills: skills)

        if let existed = try findManifestRecord(tagID: skillTag.id), existed.content.fileType.isTextLike {
            _ = try recordRepo.updateTextContent(recordID: existed.id, text: manifestText)
            return existed.id
        }

        let created = try recordRepo.createTextRecord(
            text: manifestText,
            filename: manifestFilename,
            tags: [skillTag.id],
            visibility: .private
        )
        return created.id
    }

    func loadManifestText() -> String {
        do {
            let skillTag = try ensureSkillTag()
            if let existed = try findManifestRecord(tagID: skillTag.id) {
                return (try? recordRepo.loadTextContent(record: existed, maxBytes: 800_000)) ?? buildManifestFallbackText()
            }
            _ = try refreshManifest()
            if let created = try findManifestRecord(tagID: skillTag.id) {
                return (try? recordRepo.loadTextContent(record: created, maxBytes: 800_000)) ?? buildManifestFallbackText()
            }
        } catch {
            return buildManifestFallbackText()
        }
        return buildManifestFallbackText()
    }

    private func ensureSkillTag() throws -> Tag {
        let allTags = try tagRepo.fetchAll()
        let candidates = Set(([skillTagPrimaryName] + skillTagAliases).map { normalizeTagName($0) })
        if let existed = allTags.first(where: { candidates.contains(normalizeTagName($0.name)) }) {
            return existed
        }
        let tag = Tag(name: skillTagPrimaryName, color: "#34C759", icon: "sparkles.rectangle.stack")
        try tagRepo.create(tag)
        return tag
    }

    private func normalizeTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func findManifestRecord(tagID: String) throws -> Record? {
        var filter = RecordFilter()
        filter.tagIDs = [tagID]
        filter.tagMatchAny = true
        let candidates = try recordRepo.fetchAll(filter: filter)
        return candidates.first { $0.content.filename.caseInsensitiveCompare(manifestFilename) == .orderedSame }
    }

    private func buildManifestText(skills: [ProjectSkill]) -> String {
        let rows = skills.map { skill in
            """
            ## \(skill.name)
            - id: \(skill.id)
            - enabled: \(skill.isEnabled ? "yes" : "no")
            - trigger_hint: \(skill.triggerHint.isEmpty ? "-" : skill.triggerHint)
            - description: \(skill.description.isEmpty ? "-" : skill.description)
            - action: \(describeAction(skill.action))
            - updated_at: \(iso8601(skill.updatedAt))
            """
        }.joined(separator: "\n\n")

        return """
        # Assistant Skill Manifest
        generated_at: \(iso8601(Date()))
        skills_total: \(skills.count)

        ## Base Interfaces
        - assistant.help
        - core.summarize
        - record.search
        - record.create
        - record.append
        - record.replace
        - record.delete
        - agent.run
        - skill.run
        - skills.catalog

        ## Skills
        \(rows.isEmpty ? "- (empty)" : rows)
        """
    }

    private func describeAction(_ action: ProjectSkill.SkillAction) -> String {
        switch action {
        case .llmPrompt(_, _, let model):
            return "llmPrompt(model=\(model))"
        case .shellCommand(let command):
            return "shellCommand(\(command))"
        case .createRecord(let filenameTemplate, _):
            return "createRecord(filenameTemplate=\(filenameTemplate))"
        case .appendToRecord(let recordRef, _):
            return "appendToRecord(recordRef=\(recordRef))"
        }
    }

    private func buildManifestFallbackText() -> String {
        """
        # Assistant Skill Manifest
        generated_at: \(iso8601(Date()))
        skills_total: 0

        ## Base Interfaces
        - assistant.help
        - core.summarize
        - record.search
        - record.create
        - record.append
        - record.replace
        - record.delete
        - agent.run
        - skill.run
        - skills.catalog

        ## Skills
        - (empty)
        """
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
