import Foundation
import Combine

// MARK: - RecordListViewModel
@MainActor
final class RecordListViewModel: ObservableObject {
    @Published var records: [Record] = []
    @Published var filter = RecordFilter()
    @Published var selectedRecordID: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    private let recordRepo = RecordRepository()
    private var cancellables = Set<AnyCancellable>()

    init() {
        $filter
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.loadRecords() }
            .store(in: &cancellables)
    }

    // MARK: - Load
    func loadRecords() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let result = try recordRepo.fetchAll(filter: filter)
                records = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - CRUD
    func importFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            do {
                var firstCreatedID: String?
                for url in urls {
                    let record = try recordRepo.createFileRecord(from: url, tags: [], visibility: .private)
                    if firstCreatedID == nil { firstCreatedID = record.id }
                    EventService.shared.triggerOnRecordCreate(record: record)
                }
                if let firstCreatedID {
                    selectedRecordID = firstCreatedID
                }
                loadRecords()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createTextRecord(text: String, filename: String = "text.txt") {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        Task {
            do {
                let record = try recordRepo.createTextRecord(
                    text: normalized,
                    filename: filename,
                    tags: [],
                    visibility: .private
                )
                EventService.shared.triggerOnRecordCreate(record: record)
                selectedRecordID = record.id
                loadRecords()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ record: Record) {
        try? recordRepo.delete(id: record.id)
        if selectedRecordID == record.id { selectedRecordID = nil }
        loadRecords()
    }

    func togglePin(_ record: Record) {
        var updated = record
        updated.isPinned.toggle()
        updated.updatedAt = Date()
        try? recordRepo.update(updated)
        loadRecords()
    }

    func toggleArchive(_ record: Record) {
        var updated = record
        updated.isArchived.toggle()
        updated.updatedAt = Date()
        try? recordRepo.update(updated)
        loadRecords()
    }

    func resetRecordFiltersKeepingSearch() {
        filter.tagIDs = []
        filter.tagMatchAny = false
        filter.fileTypes = []
        filter.dateRange = nil
        filter.showArchived = false
        filter.showOnlyPinned = false
        filter.showPinnedFirst = true
    }
}
