import Foundation
import Combine

// MARK: - RecordListViewModel
@MainActor
final class RecordListViewModel: ObservableObject {
    enum SidebarSelection: Hashable {
        case all
        case pinned
        case archived
        case fileType(Record.FileType)
        case tag(String)
    }

    @Published var records: [Record] = []
    @Published var filter = RecordFilter()
    @Published var selectedRecordID: String? = nil
    @Published var sidebarSelection: SidebarSelection = .all
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var tagTree: [TagTreeNode] = []

    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()
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
                tagTree = try tagRepo.buildTree()
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
                let inheritedTags = currentCreationTags()
                var firstCreatedID: String?
                for url in urls {
                    let record = try recordRepo.createFileRecord(from: url, tags: inheritedTags, visibility: .private)
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
                    tags: currentCreationTags(),
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

    // MARK: - Sidebar Filter
    func selectSidebar(_ selection: SidebarSelection) {
        sidebarSelection = selection
        switch selection {
        case .all:
            filter.tagIDs = []
            filter.tagMatchAny = false
            filter.fileTypes = []
            filter.showArchived = false
            filter.showOnlyPinned = false
            filter.showPinnedFirst = true
        case .pinned:
            filter.tagIDs = []
            filter.tagMatchAny = false
            filter.fileTypes = []
            filter.showArchived = false
            filter.showOnlyPinned = true
            filter.showPinnedFirst = true
        case .archived:
            filter.tagIDs = []
            filter.tagMatchAny = false
            filter.fileTypes = []
            filter.showArchived = true
            filter.showOnlyPinned = false
        case .fileType(let type):
            filter.tagIDs = []
            filter.tagMatchAny = false
            filter.fileTypes = [type]
            filter.showArchived = false
            filter.showOnlyPinned = false
        case .tag(let id):
            filter.tagIDs = Set([id] + descendantTagIDs(parentID: id, in: tagTree))
            filter.tagMatchAny = true
            filter.fileTypes = []
            filter.showArchived = false
            filter.showOnlyPinned = false
        }
    }

    // MARK: - Tag
    func addTag(_ tag: Tag) {
        try? tagRepo.create(tag)
        loadRecords()
    }

    func updateTag(_ tag: Tag) {
        try? tagRepo.update(tag)
        loadRecords()
    }

    func deleteTag(id: String) {
        try? tagRepo.delete(id: id)
        if case .tag(let selectedID) = sidebarSelection, selectedID == id {
            selectSidebar(.all)
        } else {
            loadRecords()
        }
    }

    private func currentCreationTags() -> [String] {
        if case .tag(let selectedID) = sidebarSelection {
            return [selectedID]
        }
        return Array(filter.tagIDs)
    }

    private func descendantTagIDs(parentID: String, in nodes: [TagTreeNode]) -> [String] {
        for node in nodes {
            if node.tag.id == parentID {
                return flattenChildrenIDs(node.children)
            }
            let nested = descendantTagIDs(parentID: parentID, in: node.children)
            if !nested.isEmpty {
                return nested
            }
        }
        return []
    }

    private func flattenChildrenIDs(_ nodes: [TagTreeNode]) -> [String] {
        nodes.flatMap { [$0.tag.id] + flattenChildrenIDs($0.children) }
    }
}
