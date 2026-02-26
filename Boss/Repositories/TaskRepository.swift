import Foundation

// MARK: - TaskRepository
final class TaskRepository {
    private let fileManager = FileManager.default
    private let taskEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let taskDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let logEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let logDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var currentUserID: String { AppConfig.shared.currentUserID }

    // MARK: - Tasks
    func createTask(_ task: TaskItem) throws {
        try ensureTaskDirectory(for: currentUserID)
        let targetURL = taskFileURL(taskID: task.id, userID: currentUserID)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw TaskRepositoryError.taskAlreadyExists(task.id)
        }
        try writeTask(task, to: targetURL)
        scheduleRuntimeDocRefresh()
    }

    func fetchAllTasks() throws -> [TaskItem] {
        try loadTasks(for: currentUserID)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func updateTask(_ task: TaskItem) throws {
        try ensureTaskDirectory(for: currentUserID)
        let targetURL = taskFileURL(taskID: task.id, userID: currentUserID)
        try writeTask(task, to: targetURL)
        scheduleRuntimeDocRefresh()
    }

    func deleteTask(id: String) throws {
        let targetURL = taskFileURL(taskID: id, userID: currentUserID)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        let taskLogDir = taskLogDirectory(taskID: id, userID: currentUserID)
        if fileManager.fileExists(atPath: taskLogDir.path) {
            try fileManager.removeItem(at: taskLogDir)
        }
        scheduleRuntimeDocRefresh()
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
        try ensureTaskLogDirectory(taskID: log.taskID, for: currentUserID)
        let targetURL = logFileURL(logID: log.id, taskID: log.taskID, userID: currentUserID)
        try writeLog(log, to: targetURL)
    }

    func fetchLogs(taskID: String, limit: Int = 50) throws -> [TaskItem.RunLog] {
        let logs = try loadLogs(taskID: taskID, for: currentUserID)
            .sorted { $0.startedAt > $1.startedAt }
        guard limit > 0 else { return [] }
        return Array(logs.prefix(limit))
    }

    private func tasksRootDirectory() -> URL {
        AppConfig.shared.dataPath.appendingPathComponent("tasks", isDirectory: true)
    }

    private func taskDirectory(for userID: String) -> URL {
        tasksRootDirectory().appendingPathComponent(userID, isDirectory: true)
    }

    private func taskFileURL(taskID: String, userID: String) -> URL {
        taskDirectory(for: userID).appendingPathComponent("\(taskID).json", isDirectory: false)
    }

    private func taskLogsDirectory(for userID: String) -> URL {
        taskDirectory(for: userID).appendingPathComponent("logs", isDirectory: true)
    }

    private func taskLogDirectory(taskID: String, userID: String) -> URL {
        taskLogsDirectory(for: userID).appendingPathComponent(taskID, isDirectory: true)
    }

    private func logFileURL(logID: String, taskID: String, userID: String) -> URL {
        taskLogDirectory(taskID: taskID, userID: userID).appendingPathComponent("\(logID).json", isDirectory: false)
    }

    private func ensureTaskDirectory(for userID: String) throws {
        try fileManager.createDirectory(at: taskDirectory(for: userID), withIntermediateDirectories: true)
    }

    private func ensureTaskLogDirectory(taskID: String, for userID: String) throws {
        try fileManager.createDirectory(at: taskLogDirectory(taskID: taskID, userID: userID), withIntermediateDirectories: true)
    }

    private func loadTasks(for userID: String) throws -> [TaskItem] {
        let directory = taskDirectory(for: userID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        var tasks: [TaskItem] = []
        for url in fileURLs {
            do {
                let task = try readTask(from: url)
                tasks.append(task)
            } catch {
                throw TaskRepositoryError.invalidTaskFile(url.lastPathComponent, error.localizedDescription)
            }
        }
        return tasks
    }

    private func writeTask(_ task: TaskItem, to url: URL) throws {
        let data = try taskEncoder.encode(task)
        try data.write(to: url, options: .atomic)
    }

    private func readTask(from url: URL) throws -> TaskItem {
        let data = try Data(contentsOf: url)
        return try taskDecoder.decode(TaskItem.self, from: data)
    }

    private func loadLogs(taskID: String, for userID: String) throws -> [TaskItem.RunLog] {
        let directory = taskLogDirectory(taskID: taskID, userID: userID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        var logs: [TaskItem.RunLog] = []
        for url in urls {
            guard let log = try? readLog(from: url) else {
                continue
            }
            logs.append(log)
        }
        return logs
    }

    private func writeLog(_ log: TaskItem.RunLog, to url: URL) throws {
        let data = try logEncoder.encode(log)
        try data.write(to: url, options: .atomic)
    }

    private func readLog(from url: URL) throws -> TaskItem.RunLog {
        let data = try Data(contentsOf: url)
        return try logDecoder.decode(TaskItem.RunLog.self, from: data)
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

    private func scheduleRuntimeDocRefresh() {
        Task { @MainActor in
            AssistantRuntimeDocService.shared.refreshSilently()
        }
    }
}

private enum TaskRepositoryError: LocalizedError {
    case taskAlreadyExists(String)
    case skillAlreadyExists(String)
    case invalidTaskFile(String, String)

    var errorDescription: String? {
        switch self {
        case .taskAlreadyExists(let id):
            return "任务已存在：\(id)"
        case .skillAlreadyExists(let id):
            return "Skill 已存在：\(id)"
        case .invalidTaskFile(let filename, let reason):
            return "任务文件损坏：\(filename)（\(reason)）"
        }
    }
}

// MARK: - Skill Manifest
final class SkillManifestService {
    static let shared = SkillManifestService()

    private let taskRepo = TaskRepository()
    private let tagRepo = TagRepository()
    private let recordRepo = RecordRepository()
    private let fileManager = FileManager.default
    private let manifestFilename = "assistant-skill-manifest.md"
    private let skillTagPrimaryName = "SkillPack"
    private let skillTagAliases = ["技能包", "skill package", "skills"]

    private init() {}

    func refreshManifestSilently() {
        _ = try? refreshManifest()
        AssistantRuntimeDocService.shared.refreshSilently()
    }

    @discardableResult
    func refreshManifest() throws -> String? {
        let skills = try taskRepo.fetchAllSkills()
        let skillTag = try ensureSkillTag()
        let manifestText = buildManifestText(skills: skills)

        if let existed = try findManifestRecord(tagID: skillTag.id), existed.content.fileType.isTextLike {
            _ = try recordRepo.updateTextContent(recordID: existed.id, text: manifestText)
            try exportToFile(markdown: manifestText)
            return existed.id
        }

        let created = try recordRepo.createTextRecord(
            text: manifestText,
            filename: manifestFilename,
            tags: [skillTag.id],
            visibility: .private
        )
        try exportToFile(markdown: manifestText)
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

    private func exportToFile(markdown: String) throws {
        let docsDir = AppConfig.shared.dataPath
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        try fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let target = docsDir.appendingPathComponent(manifestFilename, isDirectory: false)
        try markdown.write(to: target, atomically: true, encoding: .utf8)
    }
}

// MARK: - Assistant Runtime Docs
final class AssistantRuntimeDocService {
    static let shared = AssistantRuntimeDocService()

    private let tagRepo = TagRepository()
    private let recordRepo = RecordRepository()
    private let fileManager = FileManager.default
    private let docsTagPrimaryName = "AssistantDocs"
    private let docsTagAliases = ["assistant docs", "openclaw docs", "运行时文档"]
    private let docFilename = "assistant-openclaw-bridge.md"
    private let interfaceDocFilename = "assistant-interface-catalog.md"

    private init() {}

    func refreshSilently() {
        _ = try? refresh()
    }

    func syncExportsIntoRecordsSilently() {
        _ = try? syncExportsIntoRecords()
    }

    @discardableResult
    func refresh() throws -> String? {
        let docsTag = try ensureDocsTag()
        let runtimeMarkdown = buildDocMarkdown()
        let interfaceMarkdown = buildInterfaceCatalogMarkdown()

        let recordID: String
        if let existing = try findDocRecord(tagID: docsTag.id), existing.content.fileType.isTextLike {
            _ = try recordRepo.updateTextContent(recordID: existing.id, text: runtimeMarkdown)
            recordID = existing.id
        } else {
            let created = try recordRepo.createTextRecord(
                text: runtimeMarkdown,
                filename: docFilename,
                tags: [docsTag.id],
                visibility: .private
            )
            recordID = created.id
        }

        try exportToFile(markdown: runtimeMarkdown, filename: docFilename)
        try exportToFile(markdown: interfaceMarkdown, filename: interfaceDocFilename)
        return recordID
    }

    @discardableResult
    func syncExportsIntoRecords() throws -> Int {
        let docsDir = AppConfig.shared.dataPath
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        guard fileManager.fileExists(atPath: docsDir.path) else { return 0 }

        let docsTag = try ensureDocsTag()
        let urls = try fileManager.contentsOfDirectory(
            at: docsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }

        var syncedCount = 0
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let filename = url.lastPathComponent
            if let record = try findDocRecordByFilename(tagID: docsTag.id, filename: filename),
               record.content.fileType.isTextLike {
                let current = (try? recordRepo.loadTextContent(record: record, maxBytes: 1_000_000)) ?? ""
                if current != text {
                    _ = try recordRepo.updateTextContent(recordID: record.id, text: text)
                }
                syncedCount += 1
                continue
            }

            _ = try recordRepo.createTextRecord(
                text: text,
                filename: filename,
                tags: [docsTag.id],
                visibility: .private
            )
            syncedCount += 1
        }
        return syncedCount
    }

    private func ensureDocsTag() throws -> Tag {
        let allTags = try tagRepo.fetchAll()
        let candidates = Set(([docsTagPrimaryName] + docsTagAliases).map { normalizeTagName($0) })
        if let existed = allTags.first(where: { candidates.contains(normalizeTagName($0.name)) }) {
            return existed
        }
        let tag = Tag(name: docsTagPrimaryName, color: "#5E5CE6", icon: "book.closed")
        try tagRepo.create(tag)
        return tag
    }

    private func normalizeTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func findDocRecord(tagID: String) throws -> Record? {
        try findDocRecordByFilename(tagID: tagID, filename: docFilename)
    }

    private func findDocRecordByFilename(tagID: String, filename: String) throws -> Record? {
        var filter = RecordFilter()
        filter.tagIDs = [tagID]
        filter.tagMatchAny = true
        let rows = try recordRepo.fetchAll(filter: filter)
        return rows.first { $0.content.filename.caseInsensitiveCompare(filename) == .orderedSame }
    }

    private func buildDocMarkdown() -> String {
        let config = AppConfig.shared
        let endpoint = config.openClawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayStatus = config.openClawRelayEnabled ? "enabled" : "disabled"
        let manifest = SkillManifestService.shared.loadManifestText()
        let tasksPath = config.dataPath
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(config.currentUserID, isDirectory: true)
            .path

        return """
        # Boss Assistant Runtime Handbook
        generated_at: \(iso8601(Date()))

        ## 1. Current Mode
        - assistant_mode: conversation_only
        - local_execution: disabled
        - primary_strategy: RAG from Core memory
        - boss_jobs_mode: heartbeat_to_openclaw
        - openclaw_relay: \(relayStatus)
        - openclaw_endpoint: \(endpoint.isEmpty ? "(not configured)" : endpoint)
        - task_storage: \(tasksPath)
        - task_file_format: json (one file per task)

        ## 2. Architecture
        1. User sends natural language request.
        2. Boss retrieves Core memory and related context.
        3. Boss generates a conversational answer (no write/delete/execute action).
        4. If relay enabled, Boss forwards context + interface catalog + skill manifest to OpenClaw.
        5. External runtime executes operations through Boss interfaces and skills.

        ## 3. Boss Jobs (Heartbeat -> OpenClaw)
        - Jobs are configured as natural-language task descriptions.
        - Trigger conditions supported:
          - manual
          - heartbeat(interval_minutes)
          - cron(expression)
          - on_record_create(tag_filter)
          - on_record_update(tag_filter)
        - When triggered, Boss sends an `openclaw.task` payload with:
          - task metadata
          - resolved instruction text
          - optional event_record context
          - optional core_context and skills_manifest
        - Boss does not execute shell/LLM/write actions locally in this path.

        ## 4. Boss Interface Catalog
        \(BossInterfaceCatalog.markdownTable())

        ## 5. Skill Manifest Snapshot
        \(manifest)

        ## 6. External Runtime Contract (OpenClaw)
        - Endpoint receives `POST application/json`.
        - Payload contains:
          - request_id / source / request
          - mode = conversation_only
          - core_context (retrieved snippets)
          - interfaces (Boss interface catalog)
          - skills_manifest (markdown snapshot)
        - Job payload (主动任务) contains:
          - mode = boss_job_heartbeat
          - job_type = openclaw.task
          - task / trigger / instruction
          - optional event_record
        - Suggested response shape:
          - status: string
          - message: string
          - handoff_id: string (optional)

        ## 7. Operator Notes
        - Boss 内置助理不直接执行操作，确保对话与执行职责分离。
        - Boss Jobs 负责主动触发 OpenClaw（类似外部 jobs，但归属 Boss 大脑配置）。
        - 记录、任务、技能等底层接口仍可被外部 Runtime 调用。
        - 文档在技能变更和助理会话时自动刷新。
        """
    }

    private func buildInterfaceCatalogMarkdown() -> String {
        let config = AppConfig.shared
        let endpoint = config.openClawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayStatus = config.openClawRelayEnabled ? "enabled" : "disabled"
        let specsJSON = encodeInterfaceSpecsAsJSON()

        return """
        # Boss Interface Catalog
        generated_at: \(iso8601(Date()))
        relay_status: \(relayStatus)
        endpoint: \(endpoint.isEmpty ? "(not configured)" : endpoint)

        ## Interfaces (Markdown Table)
        \(BossInterfaceCatalog.markdownTable())

        ## Interfaces (JSON)
        ```json
        \(specsJSON)
        ```
        """
    }

    private func encodeInterfaceSpecsAsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard
            let data = try? encoder.encode(BossInterfaceCatalog.specs),
            let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    private func docsExportDirectory() -> URL {
        AppConfig.shared.dataPath
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
    }

    private func exportToFile(markdown: String, filename: String) throws {
        let docsDir = docsExportDirectory()
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let target = docsDir.appendingPathComponent(filename, isDirectory: false)
        try markdown.write(to: target, atomically: true, encoding: .utf8)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Onboarding Templates
final class OnboardingTemplateService {
    static let shared = OnboardingTemplateService()

    private let taskRepo = TaskRepository()
    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
    private let coreTagPrimaryName = "Core"
    private let coreTagAliases = ["持久记忆", "core memory", "memory core"]
    private let auditTagPrimaryName = "AuditLog"
    private let auditTagAliases = ["audit", "audit log", "审计"]

    private init() {}

    func bootstrapCurrentUserSilently() {
        _ = try? bootstrapCurrentUser()
    }

    @discardableResult
    func bootstrapCurrentUser() throws -> Bool {
        let existingTasks = try taskRepo.fetchAllTasks()
        let existingSkills = try taskRepo.fetchAllSkills()
        let isInitialBootstrap = existingTasks.isEmpty && existingSkills.isEmpty
        let userID = AppConfig.shared.currentUserID
        let now = Date()
        var changed = false

        if existingSkills.isEmpty {
            for skill in sampleSkills(now: now) {
                try taskRepo.createSkill(skill)
            }
            changed = true
        }

        if existingTasks.isEmpty {
            for task in sampleTasks(now: now, userID: userID) {
                try taskRepo.createTask(task)
            }
            changed = true
        }

        if isInitialBootstrap {
            if try ensureQuickStartRecords(now: now) {
                changed = true
            }
        }

        if try ensureAssistantMemoryAndAuditSeeds(now: now) {
            changed = true
        }

        SkillManifestService.shared.refreshManifestSilently()
        AssistantRuntimeDocService.shared.refreshSilently()
        if isInitialBootstrap {
            AssistantRuntimeDocService.shared.syncExportsIntoRecordsSilently()
        }
        return changed
    }

    // MARK: - Samples
    private func sampleSkills(now: Date) -> [ProjectSkill] {
        [
            ProjectSkill(
                id: "tpl-skill-meeting-brief",
                name: "模板：会议纪要整理",
                description: "将输入内容整理成结构化会议纪要，输出行动项、负责人和截止时间。",
                triggerHint: "会议, 纪要, 总结",
                action: .llmPrompt(
                    systemPrompt: "你是会议纪要助手，输出必须结构化且可执行。",
                    userPromptTemplate: """
将以下内容整理为会议纪要：
{{input}}

要求输出：
1) 会议主题与结论
2) 行动项列表（负责人/截止日期）
3) 风险与待确认问题
""",
                    model: AppConfig.defaultLLMModelID
                ),
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            ),
            ProjectSkill(
                id: "tpl-skill-task-breakdown",
                name: "模板：任务拆解助手",
                description: "把目标拆成可执行任务清单，包含优先级和预估耗时。",
                triggerHint: "任务拆解, 计划, roadmap",
                action: .llmPrompt(
                    systemPrompt: "你是项目管理助手，输出任务拆解要可落地。",
                    userPromptTemplate: """
目标：
{{input}}

请输出：
- 里程碑
- 每个里程碑下的任务列表
- 每项任务优先级（P0/P1/P2）
- 预估耗时
""",
                    model: AppConfig.defaultLLMModelID
                ),
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            ),
            ProjectSkill(
                id: "tpl-skill-daily-note",
                name: "模板：日报记录器",
                description: "将输入自动写入日报草稿，便于后续汇总。",
                triggerHint: "日报, daily, 工作记录",
                action: .createRecord(
                    filenameTemplate: "daily-{{date}}.md",
                    contentTemplate: """
# 日报草稿 {{date}}

## 输入摘要
{{input}}
"""
                ),
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            )
        ]
    }

    private func sampleTasks(now: Date, userID: String) -> [TaskItem] {
        let safeUserID = userID.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression)
        return [
            TaskItem(
                id: "tpl-\(safeUserID)-task-heartbeat-focus",
                name: "模板任务：心跳工作巡检",
                description: "每 30 分钟主动向 OpenClaw 发送工作巡检任务，帮助持续推进。",
                trigger: .heartbeat(intervalMinutes: 30),
                action: .openClawJob(
                    instructionTemplate: """
请做一次工作巡检并给出下一步建议：
- 当前任务：{{task_name}}
- 描述：{{task_description}}
- 日期：{{date}}

要求：
1) 判断当前最关键的 1-3 项动作
2) 输出可执行步骤（按优先级）
3) 标注风险与阻塞
""",
                    instructionRecordRef: nil,
                    includeCoreMemory: true,
                    includeSkillManifest: true
                ),
                isEnabled: true,
                lastRunAt: nil,
                nextRunAt: Calendar.current.date(byAdding: .minute, value: 30, to: now),
                createdAt: now
            ),
            TaskItem(
                id: "tpl-\(safeUserID)-task-on-create-classify",
                name: "模板任务：新记录分类建议",
                description: "当有新记录创建时，把记录上下文发送给 OpenClaw 做分类和后续动作建议。",
                trigger: .onRecordCreate(tagFilter: []),
                action: .openClawJob(
                    instructionTemplate: """
检测到新记录创建，请完成分类与处理建议：
- 记录ID：{{record_id}}
- 文件名：{{record_filename}}
- 摘要：{{record_preview}}
- 原文片段：{{record_text}}

请返回：
1) 推荐标签
2) 是否需要创建跟进任务
3) 一句话处理建议
""",
                    instructionRecordRef: "EVENT_RECORD",
                    includeCoreMemory: true,
                    includeSkillManifest: false
                ),
                isEnabled: true,
                lastRunAt: nil,
                nextRunAt: nil,
                createdAt: now
            ),
            TaskItem(
                id: "tpl-\(safeUserID)-task-evening-wrapup",
                name: "模板任务：晚间收尾汇总",
                description: "工作日 18:30 自动触发，生成当日收尾建议并准备次日重点。",
                trigger: .cron(expression: "30 18 * * 1-5"),
                action: .openClawJob(
                    instructionTemplate: """
请生成今日收尾汇总：
- 任务名称：{{task_name}}
- 日期：{{date}}

请输出：
1) 今日完成要点
2) 未完成事项及原因
3) 明日优先事项（最多 3 条）
""",
                    instructionRecordRef: nil,
                    includeCoreMemory: true,
                    includeSkillManifest: true
                ),
                isEnabled: true,
                lastRunAt: nil,
                nextRunAt: CronParser.nextDate(expression: "30 18 * * 1-5", after: now),
                createdAt: now
            )
        ]
    }

    // MARK: - Quick Start Records
    private func ensureQuickStartRecords(now: Date) throws -> Bool {
        let quickStartTagID = try ensureQuickStartTagID()
        var changed = false

        let records = try recordRepo.fetchAll()
        if !records.contains(where: { $0.content.filename.caseInsensitiveCompare("boss-quickstart.md") == .orderedSame }) {
            let text = """
# Boss 快速上手

欢迎使用 Boss。当前已内置示例 Skills 与 Boss Jobs，帮助你快速上手。

## 1) 配置 OpenClaw
在设置页「任务与助理 -> OpenClaw 协同」填写：
- Endpoint
- Token（可选）
- 启用转发

## 2) 体验示例任务
打开「任务管理」，你会看到：
- 模板任务：心跳工作巡检
- 模板任务：新记录分类建议
- 模板任务：晚间收尾汇总

这些任务会在触发条件满足时，自动把自然语言任务说明发送给 OpenClaw。

## 3) 体验示例技能
打开「技能管理」，你会看到内置模板：
- 会议纪要整理
- 任务拆解助手
- 日报记录器

技能清单会自动汇总到 `assistant-skill-manifest.md`。

## 4) 查看自动文档
系统会自动生成并同步：
- `assistant-skill-manifest.md`
- `assistant-openclaw-bridge.md`
- `assistant-interface-catalog.md`

它们既在目录 `data/exports/docs/`，也会同步到记录中，便于直接浏览。

generated_at: \(iso8601(now))
"""
            _ = try recordRepo.createTextRecord(
                text: text,
                filename: "boss-quickstart.md",
                tags: [quickStartTagID],
                visibility: .private
            )
            changed = true
        }

        if !records.contains(where: { $0.content.filename.caseInsensitiveCompare("boss-template-reference.md") == .orderedSame }) {
            let text = """
# Boss 模板参考

## Task 模板建议
- 心跳任务：用于持续巡检与推进
- 事件任务：用于新记录/更新后的自动联动
- 定时任务：用于固定周期汇总

## Skill 模板建议
- `llmPrompt`：用于分析/总结/拆解
- `createRecord`：用于形成结构化沉淀
- `appendToRecord`：用于增量更新固定记录

## 推荐实践
1. 任务说明尽量写成可执行的自然语言步骤。
2. 在任务说明中使用模板变量（如 `{{record_id}}`）。
3. 对关键任务开启 Core 上下文，保证决策有记忆支撑。
4. 定期查看运行日志，优化说明词和触发策略。

generated_at: \(iso8601(now))
"""
            _ = try recordRepo.createTextRecord(
                text: text,
                filename: "boss-template-reference.md",
                tags: [quickStartTagID],
                visibility: .private
            )
            changed = true
        }

        return changed
    }

    private func ensureQuickStartTagID() throws -> String {
        let tags = try tagRepo.fetchAll()
        if let existing = tags.first(where: { normalizeTagName($0.name) == "quickstart" }) {
            return existing.id
        }
        let tag = Tag(name: "QuickStart", color: "#0A84FF", icon: "lightbulb")
        try tagRepo.create(tag)
        return tag.id
    }

    private func ensureAssistantMemoryAndAuditSeeds(now: Date) throws -> Bool {
        let coreTagID = try ensureTagID(
            primaryName: coreTagPrimaryName,
            aliases: coreTagAliases,
            color: "#0A84FF",
            icon: "brain.head.profile"
        )
        let auditTagID = try ensureTagID(
            primaryName: auditTagPrimaryName,
            aliases: auditTagAliases,
            color: "#FF9F0A",
            icon: "text.append"
        )

        let records = try recordRepo.fetchAll()
        var changed = false

        if !records.contains(where: { $0.content.filename.caseInsensitiveCompare("assistant-core-preferences.md") == .orderedSame }) {
            let text = """
# Assistant Core Preferences

> 这是一份初始化模板，请按你的偏好修改；后续助理会将其中关键信息作为长期记忆参考。

## 角色定位（Role）
- 期望助理扮演：Boss 项目执行助理
- 关注目标：优先推进可落地结果，减少空泛讨论

## 语气与风格（Tone）
- 语气：直接、专业、简洁
- 回复长度：默认短；复杂问题给结构化步骤
- 风格偏好：先结论，后细节；尽量附可执行清单

## 协作约定（Working Rules）
1. 遇到不确定的信息先明确假设。
2. 涉及高风险操作先提示影响面。
3. 输出里尽量包含下一步建议（可选）。

generated_at: \(iso8601(now))
"""
            _ = try recordRepo.createTextRecord(
                text: text,
                filename: "assistant-core-preferences.md",
                tags: [coreTagID],
                visibility: .private
            )
            changed = true
        }

        if !records.contains(where: { $0.content.filename.caseInsensitiveCompare("assistant-audit-bootstrap.md") == .orderedSame }) {
            let text = """
# Assistant Audit Bootstrap

request_id: bootstrap-\(UUID().uuidString.lowercased())
status: ok
source: system.init
started_at: \(iso8601(now))
finished_at: \(iso8601(now))
intent: bootstrap.seed
planner_source: system
planner_note: 初始化已创建 Core / Audit 标签与模板记录。
confirmation_required: no
core_memory_record_id: -

## Actions
- create.tag:Core
- create.tag:AuditLog
- create.record:assistant-core-preferences.md
- create.record:assistant-audit-bootstrap.md

## Notes
- 本记录用于演示审计结构，后续会话将持续追加到 `assistant-audit-YYYY-MM-DD.txt`。
"""
            _ = try recordRepo.createTextRecord(
                text: text,
                filename: "assistant-audit-bootstrap.md",
                tags: [auditTagID],
                visibility: .private
            )
            changed = true
        }

        return changed
    }

    private func ensureTagID(primaryName: String, aliases: [String], color: String, icon: String) throws -> String {
        let tags = try tagRepo.fetchAll()
        let candidates = Set(([primaryName] + aliases).map { normalizeTagName($0) })
        if let existing = tags.first(where: { candidates.contains(normalizeTagName($0.name)) }) {
            return existing.id
        }
        let tag = Tag(name: primaryName, color: color, icon: icon)
        try tagRepo.create(tag)
        return tag.id
    }

    private func normalizeTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
