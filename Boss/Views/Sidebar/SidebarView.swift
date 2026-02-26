import SwiftUI

// MARK: - SidebarView (左栏：工作台导航)
struct SidebarView: View {
    @Binding var workspaceSection: WorkspaceSection
    @ObservedObject private var config = AppConfig.shared
    @State private var users: [UserProfile] = []
    @State private var newUserName = ""
    @State private var userError: String? = nil
    private let userRepo = UserRepository()

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("新建") {
                    sidebarActionButton(label: "导入文件", systemImage: "square.and.arrow.down") {
                        triggerRecordAction(.importFiles)
                    }
                    sidebarActionButton(label: "新建文本", systemImage: "doc.badge.plus") {
                        triggerRecordAction(.createNewRecord)
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
                        label: "任务管理",
                        systemImage: "checklist",
                        selected: workspaceSection == .tasks
                    ) {
                        workspaceSection = .tasks
                    }
                    sidebarButton(
                        label: "技能管理",
                        systemImage: "sparkles.rectangle.stack",
                        selected: workspaceSection == .skills
                    ) {
                        workspaceSection = .skills
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("用户")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("当前用户", selection: Binding(
                    get: { config.currentUserID },
                    set: { config.setCurrentUser($0) }
                )) {
                    ForEach(users) { user in
                        Text(user.name).tag(user.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    TextField("新增用户", text: $newUserName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        createUser()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(newUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let userError, !userError.isEmpty {
                    Text(userError)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear(perform: reloadUsers)
        .onChange(of: config.currentUserID) {
            reloadUsers()
        }
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

    private func reloadUsers() {
        do {
            try userRepo.ensureDefaultUserExists()
            users = try userRepo.fetchAll()
            if users.isEmpty {
                users = [try userRepo.ensureUserExists(id: AppConfig.defaultUserID, fallbackName: "默认用户")]
            }
            if !users.contains(where: { $0.id == config.currentUserID }), let fallback = users.first {
                config.setCurrentUser(fallback.id)
            }
            userError = nil
        } catch {
            userError = error.localizedDescription
        }
    }

    private func createUser() {
        let name = newUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let created = try userRepo.create(name: name)
            newUserName = ""
            reloadUsers()
            config.setCurrentUser(created.id)
        } catch {
            userError = error.localizedDescription
        }
    }
}
