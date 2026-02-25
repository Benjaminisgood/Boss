import SwiftUI
import Combine

enum WorkspaceSection: Hashable {
    case records
    case fileTypes
    case tags
    case assistant
}

// MARK: - ContentView (主窗口三栏布局)
struct ContentView: View {
    @StateObject private var listVM = RecordListViewModel()
    @StateObject private var workspaceVM = WorkspaceOverviewViewModel()
    @StateObject private var assistantState = AssistantWorkspaceState()
    @State private var workspaceSection: WorkspaceSection = .records

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(workspaceSection: $workspaceSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            switch workspaceSection {
            case .records:
                RecordListView(listVM: listVM)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 380)
            case .fileTypes:
                FileTypeManagementListView(vm: workspaceVM)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 420)
            case .tags:
                TagManagementListView(vm: workspaceVM)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 420)
            case .assistant:
                AssistantInputColumnView(state: assistantState)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 520)
            }
        } detail: {
            switch workspaceSection {
            case .records:
                RecordDetailView(recordID: listVM.selectedRecordID)
            case .fileTypes:
                FileTypeManagementDetailView(vm: workspaceVM)
            case .tags:
                TagManagementDetailView(vm: workspaceVM)
            case .assistant:
                AssistantOutputColumnView(state: assistantState)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle("Boss")
        .frame(minWidth: 980, minHeight: 560)
        .onAppear {
            listVM.resetRecordFiltersKeepingSearch()
            listVM.loadRecords()
            workspaceVM.load()
        }
        .onChange(of: workspaceSection) { _, section in
            switch section {
            case .records:
                listVM.resetRecordFiltersKeepingSearch()
            case .fileTypes, .tags:
                workspaceVM.load()
            case .assistant:
                break
            }
        }
    }
}

// MARK: - Workspace Overview ViewModel
@MainActor
final class WorkspaceOverviewViewModel: ObservableObject {
    @Published private(set) var records: [Record] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var tagTree: [TagTreeNode] = []
    @Published var selectedFileType: Record.FileType?
    @Published var selectedTagID: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let recordRepo = RecordRepository()
    private let tagRepo = TagRepository()

    func load() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let fetchedRecords = try recordRepo.fetchAll()
                let fetchedTags = try tagRepo.fetchAll()
                let fetchedTagTree = try tagRepo.buildTree()

                records = fetchedRecords
                tags = fetchedTags
                tagTree = fetchedTagTree
                ensureSelections()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addTag(_ tag: Tag) {
        do {
            try tagRepo.create(tag)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateTag(_ tag: Tag) {
        do {
            try tagRepo.update(tag)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTag(id: String) {
        do {
            try tagRepo.delete(id: id)
            if selectedTagID == id {
                selectedTagID = nil
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fileTypeCount(_ type: Record.FileType) -> Int {
        records.filter { $0.content.fileType == type }.count
    }

    func fileTypeBytes(_ type: Record.FileType) -> Int {
        records
            .filter { $0.content.fileType == type }
            .reduce(0) { $0 + $1.content.sizeBytes }
    }

    func records(for type: Record.FileType) -> [Record] {
        records
            .filter { $0.content.fileType == type }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var selectedTag: Tag? {
        guard let selectedTagID else { return nil }
        return tags.first { $0.id == selectedTagID }
    }

    func parentTagName(for tag: Tag) -> String? {
        guard let parentID = tag.parentID else { return nil }
        return tags.first { $0.id == parentID }?.name
    }

    func directRecordCount(tagID: String) -> Int {
        records.filter { $0.tags.contains(tagID) }.count
    }

    func aggregateRecordCount(tagID: String) -> Int {
        records(forTagID: tagID, includeDescendants: true).count
    }

    func descendantTagCount(tagID: String) -> Int {
        descendantTagIDs(parentID: tagID, in: tagTree).count
    }

    func records(forTagID tagID: String, includeDescendants: Bool) -> [Record] {
        let ids: Set<String> = {
            if includeDescendants {
                return Set([tagID] + descendantTagIDs(parentID: tagID, in: tagTree))
            }
            return Set([tagID])
        }()

        return records
            .filter { !Set($0.tags).isDisjoint(with: ids) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func ensureSelections() {
        if selectedFileType == nil {
            selectedFileType = Record.FileType.allCases.first { fileTypeCount($0) > 0 } ?? Record.FileType.allCases.first
        }

        if let selectedTagID, tags.contains(where: { $0.id == selectedTagID }) {
            return
        }
        selectedTagID = tags.first?.id
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

// MARK: - File Type Management
private struct FileTypeManagementListView: View {
    @ObservedObject var vm: WorkspaceOverviewViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件类型")
                    .font(.headline)
                Spacer()
                Button {
                    vm.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新统计")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Record.FileType.allCases, id: \.self) { type in
                        Button {
                            vm.selectedFileType = type
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: type.icon)
                                    .foregroundColor(.secondary)
                                Text(type.displayName)
                                Spacer()
                                Text("\(vm.fileTypeCount(type))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .foregroundColor(vm.selectedFileType == type ? .accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }

            if let errorMessage = vm.errorMessage, !errorMessage.isEmpty {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(8)
            }
        }
    }
}

private struct FileTypeManagementDetailView: View {
    @ObservedObject var vm: WorkspaceOverviewViewModel

    var body: some View {
        Group {
            if let type = vm.selectedFileType {
                let records = vm.records(for: type)
                let totalCount = vm.records.count
                let ratio = totalCount == 0 ? 0 : Int((Double(records.count) / Double(totalCount) * 100).rounded())
                let totalBytes = vm.fileTypeBytes(type)
                let latestUpdate = records.first?.updatedAt

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: type.icon)
                                .foregroundColor(.secondary)
                            Text(type.displayName)
                                .font(.title2.weight(.semibold))
                            Spacer()
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            OverviewStatCard(title: "记录数", value: "\(records.count)")
                            OverviewStatCard(title: "占比", value: "\(ratio)%")
                            OverviewStatCard(
                                title: "总大小",
                                value: ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
                            )
                            OverviewStatCard(
                                title: "最近更新",
                                value: latestUpdate.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "-"
                            )
                        }

                        Divider()

                        Text("最近记录")
                            .font(.headline)

                        if records.isEmpty {
                            Text("该类型暂无记录")
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(Array(records.prefix(30)), id: \.id) { record in
                                OverviewRecordRow(record: record)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                OverviewPlaceholderView(
                    systemImage: "square.grid.2x2",
                    title: "选择一个文件类型",
                    subtitle: "在中间列查看并选择文件类型后，这里会显示该类型的概览统计。"
                )
            }
        }
    }
}

// MARK: - Tag Management
private struct TagManagementListView: View {
    @ObservedObject var vm: WorkspaceOverviewViewModel
    @State private var isAddingTag = false
    @State private var editingTag: Tag? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("标签管理")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingTag = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    vm.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新统计")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if flattenedTagNodes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tag")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("还没有标签")
                        .foregroundColor(.secondary)
                    Button("新建标签") {
                        isAddingTag = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(flattenedTagNodes) { item in
                        Button {
                            vm.selectedTagID = item.node.tag.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.node.tag.icon)
                                    .foregroundColor(item.node.tag.swiftUIColor)
                                Text(item.node.tag.name)
                                Spacer()
                                Text("\(item.node.recordCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, CGFloat(item.depth) * 14)
                            .padding(.vertical, 2)
                            .foregroundColor(vm.selectedTagID == item.node.tag.id ? .accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑标签") {
                                editingTag = item.node.tag
                            }
                            Button("删除标签", role: .destructive) {
                                vm.deleteTag(id: item.node.tag.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            if let errorMessage = vm.errorMessage, !errorMessage.isEmpty {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .sheet(isPresented: $isAddingTag) {
            TagEditorView(
                isPresented: $isAddingTag,
                allTags: vm.tags
            ) {
                vm.addTag($0)
            }
        }
        .sheet(item: $editingTag) { tag in
            TagEditorView(
                isPresented: Binding(
                    get: { editingTag != nil },
                    set: { shown in
                        if !shown {
                            editingTag = nil
                        }
                    }
                ),
                allTags: vm.tags,
                existingTag: tag
            ) {
                vm.updateTag($0)
            }
        }
    }

    private var flattenedTagNodes: [FlattenedTagNode] {
        flatten(vm.tagTree, depth: 0)
    }

    private func flatten(_ nodes: [TagTreeNode], depth: Int) -> [FlattenedTagNode] {
        nodes.flatMap { node in
            [FlattenedTagNode(node: node, depth: depth)] + flatten(node.children, depth: depth + 1)
        }
    }
}

private struct TagManagementDetailView: View {
    @ObservedObject var vm: WorkspaceOverviewViewModel

    var body: some View {
        Group {
            if let tag = vm.selectedTag {
                let directCount = vm.directRecordCount(tagID: tag.id)
                let aggregateCount = vm.aggregateRecordCount(tagID: tag.id)
                let descendantCount = vm.descendantTagCount(tagID: tag.id)
                let records = vm.records(forTagID: tag.id, includeDescendants: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: tag.icon)
                                .foregroundColor(tag.swiftUIColor)
                            Text(tag.name)
                                .font(.title2.weight(.semibold))
                            Spacer()
                        }

                        if let parentName = vm.parentTagName(for: tag) {
                            Text("父标签：\(parentName)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            OverviewStatCard(title: "直接关联记录", value: "\(directCount)")
                            OverviewStatCard(title: "含子标签记录", value: "\(aggregateCount)")
                            OverviewStatCard(title: "子标签数量", value: "\(descendantCount)")
                            OverviewStatCard(
                                title: "最近更新",
                                value: records.first.map { RelativeDateTimeFormatter().localizedString(for: $0.updatedAt, relativeTo: Date()) } ?? "-"
                            )
                        }

                        Divider()

                        Text("命中记录")
                            .font(.headline)

                        if records.isEmpty {
                            Text("该标签暂无关联记录")
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(Array(records.prefix(30)), id: \.id) { record in
                                OverviewRecordRow(record: record)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                OverviewPlaceholderView(
                    systemImage: "tag",
                    title: "选择一个标签",
                    subtitle: "在中间列查看并选择标签后，这里会显示该标签的概览统计。"
                )
            }
        }
    }
}

private struct FlattenedTagNode: Identifiable {
    let node: TagTreeNode
    let depth: Int
    var id: String { node.id }
}

// MARK: - Shared Workspace Components
private struct OverviewStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OverviewRecordRow: View {
    let record: Record

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.content.fileType.icon)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.content.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(record.preview.isEmpty ? "-" : record.preview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(record.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct OverviewPlaceholderView: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
