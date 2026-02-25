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

    private func skillDirectory(for userID: String) -> URL {
        AppConfig.shared.skillsPath.appendingPathComponent(userID, isDirectory: true)
    }

    private func skillFileURL(skillID: String, userID: String) -> URL {
        skillDirectory(for: userID).appendingPathComponent("\(skillID).md", isDirectory: false)
    }

    private func ensureSkillDirectory(for userID: String) throws {
        try fileManager.createDirectory(at: skillDirectory(for: userID), withIntermediateDirectories: true)
    }

    private func writeSkill(_ skill: ProjectSkill, to url: URL) throws {
        let markdown = buildSkillMarkdown(skill: skill)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
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
        ).filter { $0.pathExtension.lowercased() == "md" }

        var skills: [ProjectSkill] = []
        for fileURL in fileURLs {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let fallbackID = fileURL.deletingPathExtension().lastPathComponent
            guard let skill = parseSkillMarkdown(text, fallbackID: fallbackID) else {
                continue
            }
            skills.append(skill)
        }
        return skills
    }

    private func buildSkillMarkdown(skill: ProjectSkill) -> String {
        let triggerHint = compactText(skill.triggerHint, fallback: "-")
        let description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(empty)"
            : skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionBlock: String
        let actionName: String
        switch skill.action {
        case .llmPrompt(let systemPrompt, let userPromptTemplate, let model):
            actionName = "llmPrompt"
            actionBlock = """
            ### llmPrompt
            #### Model
            `\(compactText(model, fallback: AppConfig.defaultLLMModelID))`

            #### System Prompt
            \(fencedCodeBlock(language: "text", content: systemPrompt))

            #### User Prompt Template
            \(fencedCodeBlock(language: "text", content: userPromptTemplate))
            """
        case .shellCommand(let command):
            actionName = "shellCommand"
            actionBlock = """
            ### shellCommand
            #### Command
            \(fencedCodeBlock(language: "bash", content: command))
            """
        case .createRecord(let filenameTemplate, let contentTemplate):
            actionName = "createRecord"
            actionBlock = """
            ### createRecord
            #### Filename Template
            `\(compactText(filenameTemplate, fallback: "skill-note-{{date}}.txt"))`

            #### Content Template
            \(fencedCodeBlock(language: "text", content: contentTemplate))
            """
        case .appendToRecord(let recordRef, let contentTemplate):
            actionName = "appendToRecord"
            actionBlock = """
            ### appendToRecord
            #### Record Ref
            `\(compactText(recordRef, fallback: "TODAY"))`

            #### Content Template
            \(fencedCodeBlock(language: "text", content: contentTemplate))
            """
        }

        return """
        # \(skill.name)

        - id: `\(skill.id)`
        - enabled: `\(skill.isEnabled ? "yes" : "no")`
        - trigger_hint: \(triggerHint)
        - created_at: \(iso8601(skill.createdAt))
        - updated_at: \(iso8601(skill.updatedAt))
        - action: \(actionName)

        ## Description
        \(description)

        ## Action
        \(actionBlock)
        """
    }

    private func parseSkillMarkdown(_ text: String, fallbackID: String) -> ProjectSkill? {
        let lines = text.components(separatedBy: .newlines)
        let metadata = parseMetadata(lines)

        let name = extractTitle(lines) ?? fallbackID
        let id = metadata["id"].flatMap(normalizeMetadataValue) ?? fallbackID
        let isEnabledRaw = metadata["enabled"].flatMap(normalizeMetadataValue)?.lowercased() ?? "yes"
        let isEnabled = ["yes", "true", "1", "on"].contains(isEnabledRaw)
        let triggerHint = metadata["trigger_hint"].flatMap(normalizeMetadataValue) ?? ""

        let descriptionBlock = extractSectionBody(lines, heading: "## Description")
        let description: String
        if descriptionBlock.trimmingCharacters(in: .whitespacesAndNewlines) == "(empty)" {
            description = ""
        } else {
            description = descriptionBlock
        }

        let createdAt = metadata["created_at"]
            .flatMap(normalizeMetadataValue)
            .flatMap(parseISO8601Date)
            ?? Date()
        let updatedAt = metadata["updated_at"]
            .flatMap(normalizeMetadataValue)
            .flatMap(parseISO8601Date)
            ?? createdAt

        let actionName = metadata["action"].flatMap(normalizeMetadataValue)?.lowercased() ?? ""
        let action: ProjectSkill.SkillAction
        if actionName.contains("llmprompt") {
            let model = extractInlineValue(lines, heading: "#### Model") ?? AppConfig.defaultLLMModelID
            let systemPrompt = extractFencedOrTextValue(lines, heading: "#### System Prompt")
            let userPromptTemplate = extractFencedOrTextValue(lines, heading: "#### User Prompt Template")
            action = .llmPrompt(systemPrompt: systemPrompt, userPromptTemplate: userPromptTemplate, model: model)
        } else if actionName.contains("shellcommand") {
            let command = extractFencedOrTextValue(lines, heading: "#### Command")
            action = .shellCommand(command: command)
        } else if actionName.contains("createrecord") {
            let filenameTemplate = extractInlineValue(lines, heading: "#### Filename Template") ?? "skill-note-{{date}}.txt"
            let contentTemplate = extractFencedOrTextValue(lines, heading: "#### Content Template")
            action = .createRecord(filenameTemplate: filenameTemplate, contentTemplate: contentTemplate)
        } else if actionName.contains("appendtorecord") {
            let recordRef = extractInlineValue(lines, heading: "#### Record Ref") ?? "TODAY"
            let contentTemplate = extractFencedOrTextValue(lines, heading: "#### Content Template")
            action = .appendToRecord(recordRef: recordRef, contentTemplate: contentTemplate)
        } else {
            return nil
        }

        return ProjectSkill(
            id: id,
            name: name,
            description: description,
            triggerHint: triggerHint == "-" ? "" : triggerHint,
            action: action,
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func parseMetadata(_ lines: [String]) -> [String: String] {
        var metadata: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { continue }
            let payload = String(trimmed.dropFirst(2))
            guard let split = payload.firstIndex(of: ":") else { continue }
            let key = String(payload[..<split]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(payload[payload.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            metadata[key] = value
        }
        return metadata
    }

    private func extractTitle(_ lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("# ") {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func extractSectionBody(_ lines: [String], heading: String) -> String {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading }) else {
            return ""
        }
        var cursor = start + 1
        var collected: [String] = []
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") {
                break
            }
            collected.append(lines[cursor])
            cursor += 1
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeMetadataValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count >= 2 {
            let start = trimmed.index(after: trimmed.startIndex)
            let end = trimmed.index(before: trimmed.endIndex)
            let unwrapped = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return unwrapped.isEmpty ? nil : unwrapped
        }
        return trimmed
    }

    private func parseISO8601Date(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: raw) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func extractInlineValue(_ lines: [String], heading: String) -> String? {
        guard let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading }) else {
            return nil
        }
        var cursor = headingIndex + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                cursor += 1
                continue
            }
            if trimmed.hasPrefix("#### ") || trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") {
                return nil
            }
            return normalizeMetadataValue(trimmed) ?? trimmed
        }
        return nil
    }

    private func extractFencedOrTextValue(_ lines: [String], heading: String) -> String {
        guard let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading }) else {
            return ""
        }
        var cursor = headingIndex + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                cursor += 1
                continue
            }
            if let fence = codeFencePrefix(trimmed) {
                let block = readFencedBlock(lines, openingIndex: cursor, fence: fence)
                return block.content
            }
            if trimmed.hasPrefix("#### ") || trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") {
                return ""
            }
            return normalizeMetadataValue(trimmed) ?? trimmed
        }
        return ""
    }

    private func codeFencePrefix(_ line: String) -> String? {
        let prefix = line.prefix { $0 == "`" }
        return prefix.count >= 3 ? String(prefix) : nil
    }

    private func readFencedBlock(_ lines: [String], openingIndex: Int, fence: String) -> (content: String, nextIndex: Int) {
        var cursor = openingIndex + 1
        var collected: [String] = []
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == fence {
                return (collected.joined(separator: "\n"), cursor + 1)
            }
            collected.append(lines[cursor])
            cursor += 1
        }
        return (collected.joined(separator: "\n"), cursor)
    }

    private func fencedCodeBlock(language: String, content: String) -> String {
        let fence = content.contains("```") ? "````" : "```"
        return "\(fence)\(language)\n\(content)\n\(fence)"
    }

    private func compactText(_ value: String, fallback: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
