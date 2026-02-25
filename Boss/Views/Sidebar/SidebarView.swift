import SwiftUI

// MARK: - SidebarView (左栏：工作台导航)
struct SidebarView: View {
    @Binding var workspaceSection: WorkspaceSection

    var body: some View {
        List {
            Section("新建") {
                sidebarActionButton(label: "导入文件", systemImage: "square.and.arrow.down") {
                    triggerRecordAction(.importFiles)
                }
                sidebarActionButton(label: "新建文本记录", systemImage: "doc.badge.plus") {
                    triggerRecordAction(.createNewRecord)
                }
                sidebarActionButton(label: "任务", systemImage: "checklist") {
                    triggerRecordAction(.openTaskCenter)
                }
                sidebarActionButton(label: "新增 Skill", systemImage: "sparkles.rectangle.stack") {
                    triggerRecordAction(.createNewSkill)
                }
            }

            Section("工作台") {
                sidebarButton(
                    label: "所有记录",
                    systemImage: "tray.full",
                    selected: workspaceSection == .records
                ) {
                    workspaceSection = .records
                }

                sidebarButton(
                    label: "文件类型",
                    systemImage: "square.grid.2x2",
                    selected: workspaceSection == .fileTypes
                ) {
                    workspaceSection = .fileTypes
                }
                sidebarButton(
                    label: "标签管理",
                    systemImage: "tag",
                    selected: workspaceSection == .tags
                ) {
                    workspaceSection = .tags
                }
                sidebarButton(
                    label: "项目助理",
                    systemImage: "brain.head.profile",
                    selected: workspaceSection == .assistant
                ) {
                    workspaceSection = .assistant
                }
            }
        }
        .listStyle(.sidebar)
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

    private func sidebarActionButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func triggerRecordAction(_ name: Notification.Name) {
        workspaceSection = .records
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
