import Foundation
import Combine

// MARK: - RecordDetailViewModel
@MainActor
final class RecordDetailViewModel: ObservableObject {
    @Published var record: Record?
    @Published var allTags: [Tag] = []
    @Published var textContent: String = ""
    @Published var isDirty = false
    @Published var isSaving = false
    @Published var errorMessage: String? = nil

    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
    private var autosaveTask: Task<Void, Never>?

    var canEditTextContent: Bool {
        guard let record else { return false }
        return record.content.fileType.isTextLike || record.content.kind == .text
    }

    // MARK: - Load
    func load(id: String?) {
        guard let id else {
            record = nil
            textContent = ""
            return
        }
        Task {
            do {
                let loaded = try recordRepo.fetchByID(id)
                record = loaded
                allTags = (try? tagRepo.fetchAll()) ?? []
                if let loaded, loaded.content.fileType.isTextLike || loaded.content.kind == .text {
                    textContent = (try? recordRepo.loadTextContent(record: loaded)) ?? ""
                } else {
                    textContent = ""
                }
                isDirty = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Edit
    func updateTextContent(_ text: String) {
        textContent = text
        scheduleAutosave()
    }

    func toggleTag(_ tagID: String) {
        guard var r = record else { return }
        if r.tags.contains(tagID) {
            r.tags.removeAll { $0 == tagID }
        } else {
            r.tags.append(tagID)
        }
        record = r
        saveMetadata()
    }

    func updateVisibility(_ visibility: Record.Visibility) {
        guard var r = record else { return }
        r.visibility = visibility
        r.updatedAt = Date()
        record = r
        saveMetadata()
    }

    func replaceFile(url: URL) {
        guard let record else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let updated = try recordRepo.replaceFile(recordID: record.id, sourceURL: url)
                if let updated {
                    self.record = updated
                    if updated.content.fileType.isTextLike || updated.content.kind == .text {
                        self.textContent = (try? recordRepo.loadTextContent(record: updated)) ?? ""
                    } else {
                        self.textContent = ""
                    }
                    EventService.shared.triggerOnRecordUpdate(record: updated)
                }
                isDirty = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Save
    func saveNow() {
        autosaveTask?.cancel()
        save()
    }

    private func save() {
        guard let current = record else { return }
        guard canEditTextContent else {
            saveMetadata()
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let updated = try recordRepo.updateTextContent(recordID: current.id, text: textContent)
                if let updated {
                    self.record = updated
                    EventService.shared.triggerOnRecordUpdate(record: updated)
                }
                isDirty = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveMetadata() {
        guard var current = record else { return }
        current.updatedAt = Date()
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try recordRepo.update(current)
                EventService.shared.triggerOnRecordUpdate(record: current)
                isDirty = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleAutosave() {
        isDirty = true
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            save()
        }
    }
}
