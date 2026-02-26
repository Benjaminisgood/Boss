import SwiftUI
import UniformTypeIdentifiers

enum StoragePathTarget {
    case data
    case database
    case skills
    case tasks
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
                .tabItem { Label("任务与助理", systemImage: "cpu") }
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
        case .tasks:
            config.tasksPath = url
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

    var body: some View {
        Form {
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
                LabeledContent("任务路径") {
                    HStack {
                        Text(config.tasksPath.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundColor(.secondary)
                        Button("更改...") { pickPath(.tasks) }
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

            Section("OpenClaw 协同") {
                Toggle("启用 OpenClaw 转发", isOn: $config.openClawRelayEnabled)
                TextField("OpenClaw Endpoint (https://...)", text: $config.openClawEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                APIKeyField(label: "OpenClaw Token", placeholder: "Bearer Token (optional)", value: $config.openClawAPIKey)
                Text("启用后，助理会把请求、Core 检索上下文、Skill 与接口说明转发给 OpenClaw。Boss Jobs（任务）也会在触发时主动投递自然语言任务说明；Boss 本地不直接执行操作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
