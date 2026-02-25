import SwiftUI
import UniformTypeIdentifiers

enum StoragePathTarget {
    case data
    case database
    case skills
}

// MARK: - SettingsView
struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var pathPickerTarget: StoragePathTarget? = nil

    var body: some View {
        TabView {
            GeneralSettingsTab(config: config, pickPath: { target in
                pathPickerTarget = target
            })
                .tabItem { Label("通用", systemImage: "gear") }

            EditorSettingsTab(config: config)
                .tabItem { Label("编辑器", systemImage: "text.cursor") }

            TaskSettingsTab(config: config)
                .tabItem { Label("任务", systemImage: "cpu") }
        }
        .frame(width: 500, height: 320)
        .fileImporter(isPresented: Binding(
            get: { pathPickerTarget != nil },
            set: { shown in
                if !shown {
                    pathPickerTarget = nil
                }
            }
        ), allowedContentTypes: [.folder], onCompletion: handlePathImport)
    }

    private func handlePathImport(_ result: Result<URL, Error>) {
        guard let target = pathPickerTarget else { return }
        defer { pathPickerTarget = nil }
        guard let url = try? result.get() else { return }

        switch target {
        case .data:
            config.dataPath = url
        case .database:
            config.databasePath = url
        case .skills:
            config.skillsPath = url
        }

        config.ensureStorageDirectories()
        try? DatabaseManager.shared.setup()
        SkillManifestService.shared.refreshManifestSilently()
    }
}

// MARK: - General Tab
struct GeneralSettingsTab: View {
    @ObservedObject var config: AppConfig
    let pickPath: (StoragePathTarget) -> Void
    @State private var users: [UserProfile] = []
    @State private var newUserName = ""
    @State private var userError: String? = nil
    private let userRepo = UserRepository()

    var body: some View {
        Form {
            Section("用户") {
                Picker("当前用户", selection: Binding(
                    get: { config.currentUserID },
                    set: { config.setCurrentUser($0) }
                )) {
                    ForEach(users) { user in
                        Text(user.name).tag(user.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    TextField("新用户名称", text: $newUserName)
                    Button("新增") {
                        createUser()
                    }
                    .disabled(newUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let userError, !userError.isEmpty {
                    Text(userError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("存储") {
                LabeledContent("数据路径") {
                    HStack {
                        Text(config.dataPath.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundColor(.secondary)
                        Button("更改...") { pickPath(.data) }
                    }
                }
                LabeledContent("数据库路径") {
                    HStack {
                        Text(config.databasePath.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundColor(.secondary)
                        Button("更改...") { pickPath(.database) }
                    }
                }
                LabeledContent("技能路径") {
                    HStack {
                        Text(config.skillsPath.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundColor(.secondary)
                        Button("更改...") { pickPath(.skills) }
                    }
                }
            }
            Section("外观") {
                Picker("主题", selection: $config.theme) {
                    ForEach(AppConfig.AppTheme.allCases, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: reloadUsers)
        .onChange(of: config.currentUserID) {
            reloadUsers()
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

// MARK: - Editor Tab
struct EditorSettingsTab: View {
    @ObservedObject var config: AppConfig

    var body: some View {
        Form {
            Slider(value: $config.editorFontSize, in: 10...24, step: 1) {
                Text("字体大小: \(Int(config.editorFontSize))pt")
            }
            Toggle("显示行号", isOn: $config.showLineNumbers)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Task Tab
struct TaskSettingsTab: View {
    @ObservedObject var config: AppConfig

    private var modelOptions: [AppConfig.LLMModelOption] {
        var options = AppConfig.llmModelOptions
        if !options.contains(where: { $0.id == config.claudeModel }) {
            options.insert(.init(id: config.claudeModel, label: "自定义: \(config.claudeModel)"), at: 0)
        }
        return options
    }

    var body: some View {
        Form {
            Section("模型") {
                Picker("模型", selection: $config.claudeModel) {
                    ForEach(modelOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)

                TextField("自定义模型 (provider:model)", text: $config.claudeModel)
                    .font(.system(size: 12).monospaced())
            }

            Section("API Keys") {
                APIKeyField(label: "Claude", placeholder: "Claude API Key", value: $config.claudeAPIKey)
                APIKeyField(label: "OpenAI", placeholder: "OpenAI API Key", value: $config.openAIAPIKey)
                APIKeyField(label: "阿里云百炼", placeholder: "DashScope API Key", value: $config.aliyunAPIKey)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct APIKeyField: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    @State private var isRevealed = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if isRevealed {
                    TextField(placeholder, text: $value)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(placeholder, text: $value)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }
        }
    }
}
