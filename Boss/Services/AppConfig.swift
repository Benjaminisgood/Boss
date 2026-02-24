import Foundation
import Combine

// MARK: - AppConfig (配置系统，单例)
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Key {
        static let storagePath = "storagePath"
        static let theme = "theme"
        static let editorFontSize = "editorFontSize"
        static let showLineNumbers = "showLineNumbers"
        static let claudeAPIKey = "claudeAPIKey"
        static let openAIAPIKey = "openAIAPIKey"
        static let aliyunAPIKey = "aliyunAPIKey"
        static let claudeModel = "claudeModel"
    }

    struct LLMModelOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let defaultLLMModelID = "claude:claude-sonnet-4-6"
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
    @Published var storagePath: URL {
        didSet { defaults.set(storagePath.path, forKey: Key.storagePath) }
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

    enum AppTheme: String, CaseIterable {
        case system, light, dark
    }

    private init() {
        let defaultPath = Self.defaultStorageURL()
        if let storedPath = defaults.string(forKey: Key.storagePath), !storedPath.isEmpty {
            storagePath = URL(fileURLWithPath: storedPath, isDirectory: true)
        } else {
            storagePath = defaultPath
        }
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        editorFontSize = defaults.double(forKey: Key.editorFontSize).nonZero ?? 14
        showLineNumbers = defaults.bool(forKey: Key.showLineNumbers)
        claudeAPIKey = defaults.string(forKey: Key.claudeAPIKey) ?? ""
        openAIAPIKey = defaults.string(forKey: Key.openAIAPIKey) ?? ""
        aliyunAPIKey = defaults.string(forKey: Key.aliyunAPIKey) ?? ""
        claudeModel = Self.normalizeModelID(defaults.string(forKey: Key.claudeModel))
        defaults.set(claudeModel, forKey: Key.claudeModel)

        if !ensureStorageDirectories() {
            storagePath = defaultPath
            _ = ensureStorageDirectories()
        }
    }

    @discardableResult
    func ensureStorageDirectories() -> Bool {
        let fm = FileManager.default
        let dirs = [
            storagePath,
            storagePath.appendingPathComponent("records"),
            storagePath.appendingPathComponent("attachments"),
            storagePath.appendingPathComponent("exports")
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

    private static func defaultStorageURL() -> URL {
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
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
