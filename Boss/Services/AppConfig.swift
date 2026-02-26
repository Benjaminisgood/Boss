import Foundation
import Combine

// MARK: - AppConfig (配置系统，单例)
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Key {
        static let dataPath = "dataPath"
        static let databasePath = "databasePath"
        static let skillsPath = "skillsPath"
        static let tasksPath = "tasksPath"
        static let storagePath = "storagePath"
        static let theme = "theme"
        static let editorFontSize = "editorFontSize"
        static let showLineNumbers = "showLineNumbers"
        static let currentUserID = "currentUserID"
        static let claudeAPIKey = "claudeAPIKey"
        static let openAIAPIKey = "openAIAPIKey"
        static let aliyunAPIKey = "aliyunAPIKey"
        static let claudeModel = "claudeModel"
        static let openClawEndpoint = "openClawEndpoint"
        static let openClawAPIKey = "openClawAPIKey"
        static let openClawRelayEnabled = "openClawRelayEnabled"
    }

    struct LLMModelOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let defaultLLMModelID = "claude:claude-sonnet-4-6"
    static let defaultUserID = "default"
    static let llmModelOptions: [LLMModelOption] = [
        .init(id: "claude:claude-sonnet-4-6", label: "Claude Sonnet 4.6"),
        .init(id: "claude:claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
        .init(id: "claude:claude-opus-4-6", label: "Claude Opus 4.6"),
        .init(id: "openai:gpt-4.1", label: "OpenAI GPT-4.1"),
        .init(id: "openai:gpt-4.1-mini", label: "OpenAI GPT-4.1 Mini"),
        .init(id: "openai:gpt-4o", label: "OpenAI GPT-4o"),
        .init(id: "openai:gpt-4o-mini", label: "OpenAI GPT-4o Mini"),
        .init(id: "aliyun:qwen-plus", label: "阿里云 Qwen Plus"),
        .init(id: "aliyun:qwen-max", label: "阿里云 Qwen Max"),
        .init(id: "aliyun:qwen-turbo", label: "阿里云 Qwen Turbo")
    ]

    // MARK: - Properties
    @Published var dataPath: URL {
        didSet {
            defaults.set(dataPath.path, forKey: Key.dataPath)
            defaults.set(dataPath.path, forKey: Key.storagePath) // legacy key for compatibility
        }
    }
    @Published var databasePath: URL {
        didSet { defaults.set(databasePath.path, forKey: Key.databasePath) }
    }
    @Published var skillsPath: URL {
        didSet { defaults.set(skillsPath.path, forKey: Key.skillsPath) }
    }
    @Published var tasksPath: URL {
        didSet { defaults.set(tasksPath.path, forKey: Key.tasksPath) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }
    @Published var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize) }
    }
    @Published var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) }
    }
    @Published var currentUserID: String {
        didSet { defaults.set(currentUserID, forKey: Key.currentUserID) }
    }
    @Published var claudeAPIKey: String {
        didSet { defaults.set(claudeAPIKey, forKey: Key.claudeAPIKey) }
    }
    @Published var openAIAPIKey: String {
        didSet { defaults.set(openAIAPIKey, forKey: Key.openAIAPIKey) }
    }
    @Published var aliyunAPIKey: String {
        didSet { defaults.set(aliyunAPIKey, forKey: Key.aliyunAPIKey) }
    }
    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Key.claudeModel) }
    }
    @Published var openClawEndpoint: String {
        didSet { defaults.set(openClawEndpoint, forKey: Key.openClawEndpoint) }
    }
    @Published var openClawAPIKey: String {
        didSet { defaults.set(openClawAPIKey, forKey: Key.openClawAPIKey) }
    }
    @Published var openClawRelayEnabled: Bool {
        didSet { defaults.set(openClawRelayEnabled, forKey: Key.openClawRelayEnabled) }
    }

    enum AppTheme: String, CaseIterable {
        case system, light, dark
    }

    private init() {
        let defaultPaths = Self.defaultPaths()
        let legacyStoragePath = Self.normalizedPath(defaults.string(forKey: Key.storagePath))
        let storedDataPath = Self.normalizedPath(defaults.string(forKey: Key.dataPath))
        let storedDatabasePath = Self.normalizedPath(defaults.string(forKey: Key.databasePath))
        let storedSkillsPath = Self.normalizedPath(defaults.string(forKey: Key.skillsPath))
        let storedTasksPath = Self.normalizedPath(defaults.string(forKey: Key.tasksPath))

        if let storedDataPath {
            dataPath = URL(fileURLWithPath: storedDataPath, isDirectory: true)
        } else if let legacyStoragePath {
            // Legacy compatibility: old "storagePath" was the data root.
            dataPath = URL(fileURLWithPath: legacyStoragePath, isDirectory: true)
        } else {
            dataPath = defaultPaths.data
        }

        if let storedDatabasePath {
            databasePath = URL(fileURLWithPath: storedDatabasePath, isDirectory: true)
        } else if storedDataPath == nil, let legacyStoragePath {
            // Keep existing installs working without forcing a data move.
            databasePath = URL(fileURLWithPath: legacyStoragePath, isDirectory: true)
        } else {
            databasePath = defaultPaths.database
        }

        if let storedSkillsPath {
            skillsPath = URL(fileURLWithPath: storedSkillsPath, isDirectory: true)
        } else if storedDataPath == nil, let legacyStoragePath {
            skillsPath = URL(fileURLWithPath: legacyStoragePath, isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
        } else {
            skillsPath = defaultPaths.skills
        }

        if let storedTasksPath {
            tasksPath = URL(fileURLWithPath: storedTasksPath, isDirectory: true)
        } else if let storedDataPath {
            tasksPath = URL(fileURLWithPath: storedDataPath, isDirectory: true)
                .appendingPathComponent("tasks", isDirectory: true)
        } else if let legacyStoragePath {
            tasksPath = URL(fileURLWithPath: legacyStoragePath, isDirectory: true)
                .appendingPathComponent("tasks", isDirectory: true)
        } else {
            tasksPath = defaultPaths.tasks
        }

        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        editorFontSize = defaults.double(forKey: Key.editorFontSize).nonZero ?? 14
        showLineNumbers = defaults.bool(forKey: Key.showLineNumbers)
        currentUserID = Self.normalizeUserID(defaults.string(forKey: Key.currentUserID))
        claudeAPIKey = defaults.string(forKey: Key.claudeAPIKey) ?? ""
        openAIAPIKey = defaults.string(forKey: Key.openAIAPIKey) ?? ""
        aliyunAPIKey = defaults.string(forKey: Key.aliyunAPIKey) ?? ""
        claudeModel = Self.normalizeModelID(defaults.string(forKey: Key.claudeModel))
        openClawEndpoint = defaults.string(forKey: Key.openClawEndpoint) ?? ""
        openClawAPIKey = defaults.string(forKey: Key.openClawAPIKey) ?? ""
        openClawRelayEnabled = defaults.object(forKey: Key.openClawRelayEnabled) as? Bool ?? false
        defaults.set(dataPath.path, forKey: Key.dataPath)
        defaults.set(databasePath.path, forKey: Key.databasePath)
        defaults.set(skillsPath.path, forKey: Key.skillsPath)
        defaults.set(tasksPath.path, forKey: Key.tasksPath)
        defaults.set(dataPath.path, forKey: Key.storagePath)
        defaults.set(currentUserID, forKey: Key.currentUserID)
        defaults.set(claudeModel, forKey: Key.claudeModel)
        defaults.set(openClawEndpoint, forKey: Key.openClawEndpoint)
        defaults.set(openClawAPIKey, forKey: Key.openClawAPIKey)
        defaults.set(openClawRelayEnabled, forKey: Key.openClawRelayEnabled)

        if !ensureStorageDirectories() {
            let fallback = Self.defaultPaths()
            dataPath = fallback.data
            databasePath = fallback.database
            skillsPath = fallback.skills
            tasksPath = fallback.tasks
            _ = ensureStorageDirectories()
        }
    }

    // Backward-compatible alias for older callsites.
    var storagePath: URL {
        get { dataPath }
        set { dataPath = newValue }
    }

    var databaseFileURL: URL {
        databasePath.appendingPathComponent("boss.sqlite")
    }

    @discardableResult
    func ensureStorageDirectories() -> Bool {
        let fm = FileManager.default
        let dirs = [
            dataPath,
            dataPath.appendingPathComponent("records", isDirectory: true),
            dataPath.appendingPathComponent("attachments", isDirectory: true),
            dataPath.appendingPathComponent("exports", isDirectory: true),
            dataPath.appendingPathComponent("exports", isDirectory: true)
                .appendingPathComponent("docs", isDirectory: true),
            databasePath,
            skillsPath,
            tasksPath
        ]
        for dir in dirs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return true
    }

    private static func defaultPaths() -> (data: URL, database: URL, skills: URL, tasks: URL) {
        let root = defaultRootURL()
        let data = root.appendingPathComponent("data", isDirectory: true)
        return (
            data: data,
            database: root.appendingPathComponent("database", isDirectory: true),
            skills: root.appendingPathComponent("skills", isDirectory: true),
            tasks: data.appendingPathComponent("tasks", isDirectory: true)
        )
    }

    private static func defaultRootURL() -> URL {
        let fm = FileManager.default
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent("Boss", isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Boss", isDirectory: true)
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeModelID(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return defaultLLMModelID }
        if value.contains(":") { return value }
        let lower = value.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return "openai:\(value)"
        }
        if lower.hasPrefix("qwen") {
            return "aliyun:\(value)"
        }
        return "claude:\(value)"
    }

    static func normalizeUserID(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return defaultUserID }
        return value.lowercased()
    }

    func setCurrentUser(_ userID: String) {
        currentUserID = Self.normalizeUserID(userID)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
