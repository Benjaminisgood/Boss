import Foundation

// MARK: - TaskRepository
final class TaskRepository {
    private let db = DatabaseManager.shared
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentUserID: String { AppConfig.shared.currentUserID }

    // MARK: - Tasks
    func createTask(_ task: TaskItem) throws {
        let triggerJSON = (try? encoder.encode(task.trigger)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let actionJSON  = (try? encoder.encode(task.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            INSERT INTO tasks (id, user_id, name, description, template_id, trigger_json, action_json,
            is_enabled, last_run_at, next_run_at, created_at, output_tag_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(task.id), .text(currentUserID), .text(task.name), .text(task.description),
                task.templateID.map { .text($0) } ?? .null,
                .text(triggerJSON), .text(actionJSON),
                .integer(task.isEnabled ? 1 : 0),
                task.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.nextRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(task.createdAt.timeIntervalSince1970),
                task.outputTagID.map { .text($0) } ?? .null
            ])
    }

    func fetchAllTasks() throws -> [TaskItem] {
        try db.read(
            "SELECT * FROM tasks WHERE user_id = ? ORDER BY created_at DESC",
            bindings: [.text(currentUserID)],
            map: mapTaskRow
        )
    }

    func updateTask(_ task: TaskItem) throws {
        let triggerJSON = (try? encoder.encode(task.trigger)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let actionJSON  = (try? encoder.encode(task.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.write("""
            UPDATE tasks SET name=?, description=?, template_id=?, trigger_json=?, action_json=?,
            is_enabled=?, last_run_at=?, next_run_at=?, output_tag_id=? WHERE id=? AND user_id=?
            """, bindings: [
                .text(task.name), .text(task.description),
                task.templateID.map { .text($0) } ?? .null,
                .text(triggerJSON), .text(actionJSON),
                .integer(task.isEnabled ? 1 : 0),
                task.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.nextRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.outputTagID.map { .text($0) } ?? .null,
                .text(task.id),
                .text(currentUserID)
            ])
    }

    func deleteTask(id: String) throws {
        try db.write("DELETE FROM tasks WHERE id = ? AND user_id = ?", bindings: [.text(id), .text(currentUserID)])
    }

    // MARK: - Skills
    func createSkill(_ skill: ProjectSkill) throws {
        try ensureSkillDirectory(for: currentUserID)
        let targetURL = skillFileURL(skillID: skill.id, userID: currentUserID)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw TaskRepositoryError.skillAlreadyExists(skill.id)
        }
        try writeSkill(skill, to: targetURL)
        scheduleSkillManifestRefresh()
    }

    func fetchAllSkills() throws -> [ProjectSkill] {
        try migrateLegacySkillsIfNeeded(for: currentUserID)
        return try loadSkills(for: currentUserID)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fetchEnabledSkills() throws -> [ProjectSkill] {
        try fetchAllSkills().filter(\.isEnabled)
    }

    func updateSkill(_ skill: ProjectSkill) throws {
        try ensureSkillDirectory(for: currentUserID)
        let targetURL = skillFileURL(skillID: skill.id, userID: currentUserID)
        try writeSkill(skill, to: targetURL)
        scheduleSkillManifestRefresh()
    }

    func deleteSkill(id: String) throws {
        let targetURL = skillFileURL(skillID: id, userID: currentUserID)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        scheduleSkillManifestRefresh()
    }

    // MARK: - Run Logs
    func insertLog(_ log: TaskItem.RunLog) throws {
        try db.write("""
            INSERT OR REPLACE INTO task_run_logs (id, user_id, task_id, started_at, finished_at, status, output, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(log.id), .text(currentUserID), .text(log.taskID), .real(log.startedAt.timeIntervalSince1970),
                log.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(log.status.rawValue), .text(log.output),
                log.error.map { .text($0) } ?? .null
            ])
    }

    func fetchLogs(taskID: String, limit: Int = 50) throws -> [TaskItem.RunLog] {
        try db.read("""
            SELECT * FROM task_run_logs WHERE task_id = ? AND user_id = ? ORDER BY started_at DESC LIMIT ?
            """, bindings: [.text(taskID), .text(currentUserID), .integer(limit)], map: mapLogRow)
    }

    // MARK: - Mappers
    private func mapTaskRow(_ row: [String: SQLValue]) -> TaskItem? {
        guard
            let id = row["id"]?.stringValue,
            let name = row["name"]?.stringValue,
            let triggerJSON = row["trigger_json"]?.stringValue?.data(using: .utf8),
            let actionJSON  = row["action_json"]?.stringValue?.data(using: .utf8),
            let trigger = try? decoder.decode(TaskItem.Trigger.self, from: triggerJSON),
            let action  = try? decoder.decode(TaskItem.TaskAction.self, from: actionJSON),
            let createdAt = row["created_at"]?.doubleValue
        else { return nil }
        return TaskItem(
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

    private func mapLogRow(_ row: [String: SQLValue]) -> TaskItem.RunLog? {
        guard
            let id = row["id"]?.stringValue,
            let taskID = row["task_id"]?.stringValue,
            let startedAt = row["started_at"]?.doubleValue,
            let statusRaw = row["status"]?.stringValue,
            let status = TaskItem.RunLog.RunStatus(rawValue: statusRaw)
        else { return nil }
        return TaskItem.RunLog(
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

    private func skillDirectory(for userID: String) -> URL {
        AppConfig.shared.skillsPath.appendingPathComponent(userID, isDirectory: true)
    }

    private func skillFileURL(skillID: String, userID: String) -> URL {
        skillDirectory(for: userID).appendingPathComponent("\(skillID).json", isDirectory: false)
    }

    private func ensureSkillDirectory(for userID: String) throws {
        try fileManager.createDirectory(at: skillDirectory(for: userID), withIntermediateDirectories: true)
    }

    private func writeSkill(_ skill: ProjectSkill, to url: URL) throws {
        let data = try encoder.encode(skill)
        try data.write(to: url, options: .atomic)
    }

    private func loadSkills(for userID: String) throws -> [ProjectSkill] {
        let directory = skillDirectory(for: userID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        var skills: [ProjectSkill] = []
        for fileURL in fileURLs {
            guard let data = try? Data(contentsOf: fileURL),
                  let skill = try? decoder.decode(ProjectSkill.self, from: data) else {
                continue
            }
            skills.append(skill)
        }
        return skills
    }

    private func migrateLegacySkillsIfNeeded(for userID: String) throws {
        if !(try loadSkills(for: userID)).isEmpty {
            return
        }
        guard try legacySkillsTableExists() else {
            return
        }

        let legacySkills = try db.read(
            "SELECT * FROM assistant_skills WHERE user_id = ? ORDER BY created_at DESC",
            bindings: [.text(userID)],
            map: mapSkillRow
        )
        guard !legacySkills.isEmpty else {
            return
        }

        try ensureSkillDirectory(for: userID)
        for skill in legacySkills {
            try writeSkill(skill, to: skillFileURL(skillID: skill.id, userID: userID))
        }
    }

    private func legacySkillsTableExists() throws -> Bool {
        let rows = try db.read(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='assistant_skills' LIMIT 1",
            map: { row in row["name"]?.stringValue }
        )
        return !rows.isEmpty
    }

    private func scheduleSkillManifestRefresh() {
        Task { @MainActor in
            SkillManifestService.shared.refreshManifestSilently()
        }
    }
}

private enum TaskRepositoryError: LocalizedError {
    case skillAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .skillAlreadyExists(let id):
            return "Skill 已存在：\(id)"
        }
    }
}

// MARK: - Skill Manifest
final class SkillManifestService {
    static let shared = SkillManifestService()

    private let taskRepo = TaskRepository()
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
        let skills = try taskRepo.fetchAllSkills()
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
        - task.run
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
        - task.run
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
