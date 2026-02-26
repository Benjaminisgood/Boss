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
        do {
            let fetched = try repo.fetchAllTasks()
            tasks = fetched
            if let selectedTaskID, !fetched.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = fetched.first?.id
                runLogs = []
            } else if selectedTaskID == nil {
                self.selectedTaskID = fetched.first?.id
            }
            errorMessage = nil
        } catch {
            tasks = []
            errorMessage = error.localizedDescription
        }
    }

    func loadLogs(for taskID: String) {
        do {
            runLogs = try repo.fetchLogs(taskID: taskID)
            errorMessage = nil
        } catch {
            runLogs = []
            errorMessage = error.localizedDescription
        }
    }

    func createTask(_ task: TaskItem) {
        do {
            try repo.createTask(task)
            loadTasks()
            selectedTaskID = task.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateTask(_ task: TaskItem) {
        do {
            try repo.updateTask(task)
            loadTasks()
            selectedTaskID = task.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTask(_ task: TaskItem) {
        do {
            try repo.deleteTask(id: task.id)
            loadTasks()
            if selectedTaskID == task.id {
                selectedTaskID = tasks.first?.id
                runLogs = []
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleEnabled(_ task: TaskItem) {
        var updated = task
        updated.isEnabled.toggle()
        do {
            try repo.updateTask(updated)
            loadTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runNow(_ task: TaskItem) {
        isRunning = true
        Task {
            let log = await scheduler.run(task: task, triggerReason: "manual.run", eventRecord: nil)
            await MainActor.run {
                runLogs.insert(log, at: 0)
                loadTasks()
                isRunning = false
            }
        }
    }
}
