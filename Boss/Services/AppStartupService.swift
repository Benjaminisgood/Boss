import Foundation

final class AppStartupService {
    static let shared = AppStartupService()

    private let lock = NSLock()
    private var bootstrapped = false

    private init() {}

    func bootstrapIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }

        if bootstrapped {
            try ensureCurrentUserExists()
            return
        }

        AppConfig.shared.ensureStorageDirectories()
        try DatabaseManager.shared.setup()
        try ensureCurrentUserExists()

        OnboardingTemplateService.shared.bootstrapCurrentUserSilently()
        SkillManifestService.shared.refreshManifestSilently()
        AssistantRuntimeDocService.shared.refreshSilently()

        bootstrapped = true
    }

    private func ensureCurrentUserExists() throws {
        let repo = UserRepository()
        try repo.ensureDefaultUserExists()
        _ = try repo.ensureUserExists(id: AppConfig.shared.currentUserID, fallbackName: "用户")
    }
}
