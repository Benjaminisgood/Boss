import Foundation
import Combine

// MARK: - AgentViewModel
@MainActor
final class AgentViewModel: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var selectedTaskID: String? = nil
    @Published var runLogs: [AgentTask.RunLog] = []
    @Published var isRunning = false
    @Published var errorMessage: String? = nil

    private let repo = AgentRepository()
    private let scheduler = SchedulerService.shared

    func loadTasks() {
        tasks = (try? repo.fetchAllTasks()) ?? []
    }

    func loadLogs(for taskID: String) {
        runLogs = (try? repo.fetchLogs(taskID: taskID)) ?? []
    }

    func createTask(_ task: AgentTask) {
        try? repo.createTask(task)
        loadTasks()
    }

    func deleteTask(_ task: AgentTask) {
        try? repo.deleteTask(id: task.id)
        loadTasks()
    }

    func toggleEnabled(_ task: AgentTask) {
        var updated = task
        updated.isEnabled.toggle()
        try? repo.updateTask(updated)
        loadTasks()
    }

    func runNow(_ task: AgentTask) {
        isRunning = true
        Task {
            let log = await scheduler.run(task: task)
            runLogs.insert(log, at: 0)
            isRunning = false
        }
    }
}
