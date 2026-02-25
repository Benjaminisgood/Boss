import SwiftUI

@main
struct BossApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var config = AppConfig.shared

    var body: some Scene {
        // 主窗口
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
        .commands {
            AppCommands()
        }

        // Agent 视图 (独立窗口)
        Window("Agent 任务", id: "agent") {
            AgentView()
                .frame(minWidth: 700, minHeight: 400)
                .preferredColorScheme(colorScheme)
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])

        // 设置
        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch config.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            AppConfig.shared.ensureStorageDirectories()
            try DatabaseManager.shared.setup()
            SchedulerService.shared.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "启动失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SchedulerService.shared.stop()
        DatabaseManager.shared.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 允许后台运行（定时任务继续）
    }
}

// MARK: - Menu Commands
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建记录") {
                // 通过 NotificationCenter 触发，避免跨 View 持有 VM
                NotificationCenter.default.post(name: .createNewRecord, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("导入文件...") {
                NotificationCenter.default.post(name: .importFiles, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let createNewRecord = Notification.Name("com.boss.createNewRecord")
    static let importFiles = Notification.Name("com.boss.importFiles")
}
