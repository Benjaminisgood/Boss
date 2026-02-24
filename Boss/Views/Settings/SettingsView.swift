import SwiftUI
import UniformTypeIdentifiers

// MARK: - SettingsView
struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var showPathPicker = false

    var body: some View {
        TabView {
            GeneralSettingsTab(config: config, showPathPicker: $showPathPicker)
                .tabItem { Label("通用", systemImage: "gear") }

            EditorSettingsTab(config: config)
                .tabItem { Label("编辑器", systemImage: "text.cursor") }

            AgentSettingsTab(config: config)
                .tabItem { Label("Agent", systemImage: "cpu") }
        }
        .frame(width: 500, height: 320)
        .fileImporter(isPresented: $showPathPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                config.storagePath = url
                config.ensureStorageDirectories()
                try? DatabaseManager.shared.setup()
            }
        }
    }
}

// MARK: - General Tab
struct GeneralSettingsTab: View {
    @ObservedObject var config: AppConfig
    @Binding var showPathPicker: Bool

    var body: some View {
        Form {
            Section("存储") {
                LabeledContent("数据路径") {
                    HStack {
                        Text(config.storagePath.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundColor(.secondary)
                        Button("更改...") { showPathPicker = true }
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

// MARK: - Agent Tab
struct AgentSettingsTab: View {
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
