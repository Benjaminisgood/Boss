import SwiftUI

// MARK: - SidebarView (左栏：可点击过滤)
struct SidebarView: View {
    @ObservedObject var listVM: RecordListViewModel
    @Binding var workspaceSection: WorkspaceSection
    @State private var isAddingTag = false
    @State private var editingTag: Tag? = nil

    var body: some View {
        List {
            Section("工作台") {
                sidebarButton(
                    label: "记录管理",
                    systemImage: "tray.full",
                    selected: workspaceSection == .records && listVM.sidebarSelection == .all
                ) {
                    workspaceSection = .records
                    listVM.selectSidebar(.all)
                }

                sidebarButton(
                    label: "项目助理",
                    systemImage: "brain.head.profile",
                    selected: workspaceSection == .assistant
                ) {
                    workspaceSection = .assistant
                }
            }

            Section {
                sidebarButton(
                    label: "所有记录",
                    systemImage: "tray.full",
                    selected: workspaceSection == .records && listVM.sidebarSelection == .all
                ) {
                    workspaceSection = .records
                    listVM.selectSidebar(.all)
                }
            }

            Section("文件类型") {
                ForEach(Record.FileType.allCases, id: \.self) { type in
                    sidebarButton(
                        label: type.displayName,
                        systemImage: type.icon,
                        selected: workspaceSection == .records && listVM.sidebarSelection == .fileType(type)
                    ) {
                        workspaceSection = .records
                        listVM.selectSidebar(.fileType(type))
                    }
                }
            }

            Section("标签") {
                ForEach(listVM.tagTree) { node in
                    TagNodeButton(
                        node: node,
                        selectedTagID: currentSelectedTagID,
                        onSelect: {
                            workspaceSection = .records
                            listVM.selectSidebar(.tag($0))
                        },
                        onEdit: { editingTag = $0 },
                        onDelete: { listVM.deleteTag(id: $0) }
                    )
                }
                Button {
                    workspaceSection = .records
                    isAddingTag = true
                } label: {
                    Label("新建标签", systemImage: "plus")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section("其他") {
                sidebarButton(
                    label: "置顶优先",
                    systemImage: "pin",
                    selected: workspaceSection == .records && listVM.sidebarSelection == .pinned
                ) {
                    workspaceSection = .records
                    listVM.selectSidebar(.pinned)
                }
                sidebarButton(
                    label: "已归档",
                    systemImage: "archivebox",
                    selected: workspaceSection == .records && listVM.sidebarSelection == .archived
                ) {
                    workspaceSection = .records
                    listVM.selectSidebar(.archived)
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $isAddingTag) {
            TagEditorView(isPresented: $isAddingTag, allTags: flattenedTags(from: listVM.tagTree)) {
                listVM.addTag($0)
            }
        }
        .sheet(item: $editingTag) { tag in
            TagEditorView(
                isPresented: Binding(
                    get: { editingTag != nil },
                    set: { shown in
                        if !shown { editingTag = nil }
                    }
                ),
                allTags: flattenedTags(from: listVM.tagTree),
                existingTag: tag
            ) {
                listVM.updateTag($0)
            }
        }
    }

    private var currentSelectedTagID: String? {
        if workspaceSection == .records, case .tag(let id) = listVM.sidebarSelection {
            return id
        }
        return nil
    }

    private func sidebarButton(label: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .foregroundColor(selected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func flattenedTags(from nodes: [TagTreeNode]) -> [Tag] {
        nodes.flatMap { [$0.tag] + flattenedTags(from: $0.children) }
    }
}

private struct TagNodeButton: View {
    let node: TagTreeNode
    let selectedTagID: String?
    let onSelect: (String) -> Void
    let onEdit: (Tag) -> Void
    let onDelete: (String) -> Void
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onSelect(node.tag.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: node.tag.icon)
                        .foregroundColor(node.tag.swiftUIColor)
                    Text(node.tag.name)
                    Spacer()
                    if node.recordCount > 0 {
                        Text("\(node.recordCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, CGFloat(depth) * 14)
                .foregroundColor(node.tag.id == selectedTagID ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                Button("编辑标签") {
                    onEdit(node.tag)
                }
                Button("删除标签", role: .destructive) {
                    onDelete(node.tag.id)
                }
            }

            ForEach(node.children) { child in
                TagNodeButton(
                    node: child,
                    selectedTagID: selectedTagID,
                    onSelect: onSelect,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    depth: depth + 1
                )
            }
        }
    }
}
