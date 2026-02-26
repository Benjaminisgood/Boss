import Foundation

// MARK: - TaskItem (轻量 任务)
struct TaskItem: Identifiable, Codable {
    var id: String
    var name: String
    var description: String
    var templateID: String?     // 关联 Record(template)
    var trigger: Trigger
    var action: TaskAction
    var isEnabled: Bool
    var lastRunAt: Date?
    var nextRunAt: Date?
    var createdAt: Date
    var outputTagID: String?    // 执行结果写入带此标签的 Record

    // MARK: - Trigger
    enum Trigger: Codable {
        case manual
        case heartbeat(intervalMinutes: Int)
        case cron(expression: String)   // cron-like "0 9 * * 1" = 每周一9点
        case onRecordCreate(tagFilter: [String])
        case onRecordUpdate(tagFilter: [String])
    }

    // MARK: - Action
    enum TaskAction: Codable {
        case openClawJob(
            instructionTemplate: String,
            instructionRecordRef: String?,
            includeCoreMemory: Bool,
            includeSkillManifest: Bool
        )
        case createRecord(title: String, contentTemplate: String)
        case appendToRecord(recordID: String, contentTemplate: String)
        case shellCommand(command: String)
        case claudeAPI(systemPrompt: String, userPromptTemplate: String, model: String)
    }

    // MARK: - RunLog
    struct RunLog: Identifiable, Codable {
        var id: String = UUID().uuidString
        var taskID: String
        var startedAt: Date
        var finishedAt: Date?
        var status: RunStatus
        var output: String
        var error: String?

        enum RunStatus: String, Codable {
            case running, success, failed
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        templateID: String? = nil,
        trigger: Trigger = .manual,
        action: TaskAction,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        createdAt: Date = Date(),
        outputTagID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.templateID = templateID
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.outputTagID = outputTagID
    }
}

// MARK: - ProjectSkill (项目助理可调用技能包)
struct ProjectSkill: Identifiable, Codable, Hashable {
    enum SkillAction: Codable, Hashable {
        case llmPrompt(systemPrompt: String, userPromptTemplate: String, model: String)
        case shellCommand(command: String)
        case createRecord(filenameTemplate: String, contentTemplate: String)
        case appendToRecord(recordRef: String, contentTemplate: String)
    }

    var id: String
    var name: String
    var description: String
    var triggerHint: String
    var action: SkillAction
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        triggerHint: String = "",
        action: SkillAction,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.triggerHint = triggerHint
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
