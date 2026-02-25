import Foundation
import Combine

// MARK: - TaskViewModel
@MainActor
final class TaskViewModel: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var selectedTaskID: String? = nil
    @Published var runLogs: [TaskItem.RunLog] = []
    @Published var isRunning = false
    @Published var errorMessage: String? = nil

    private let repo = TaskRepository()
    private let scheduler = SchedulerService.shared

    func loadTasks() {
        tasks = (try? repo.fetchAllTasks()) ?? []
    }

    func loadLogs(for taskID: String) {
        runLogs = (try? repo.fetchLogs(taskID: taskID)) ?? []
    }

    func createTask(_ task: TaskItem) {
        try? repo.createTask(task)
        loadTasks()
    }

    func deleteTask(_ task: TaskItem) {
        try? repo.deleteTask(id: task.id)
        loadTasks()
    }

    func toggleEnabled(_ task: TaskItem) {
        var updated = task
        updated.isEnabled.toggle()
        try? repo.updateTask(updated)
        loadTasks()
    }

    func runNow(_ task: TaskItem) {
        isRunning = true
        Task {
            let log = await scheduler.run(task: task)
            runLogs.insert(log, at: 0)
            isRunning = false
        }
    }
}
