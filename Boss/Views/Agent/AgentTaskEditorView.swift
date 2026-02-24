import SwiftUI

// MARK: - AgentTaskEditorView (Agent 任务创建/编辑视图)
struct AgentTaskEditorView: View {
    private enum TriggerKind: String, CaseIterable, Identifiable {
        case manual, cron, onRecordCreate, onRecordUpdate
        var id: String { rawValue }
    }

    private enum ActionKind: String, CaseIterable, Identifiable {
        case claudeAPI, shellCommand, createRecord, appendToRecord
        var id: String { rawValue }
    }

    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var description = ""
    @State private var triggerKind: TriggerKind = .manual
    @State private var cronExpression = "* * * * *"
    @State private var actionKind: ActionKind = .claudeAPI
    @State private var systemPrompt = ""
    @State private var userPrompt = ""
    @State private var model = AppConfig.shared.claudeModel
    @State private var shellCommand = ""
    @State private var createTitle = ""
    @State private var actionTemplate = ""
    @State private var appendRecordID = ""
    @State private var isEnabled = true

    let onSave: (AgentTask) -> Void
    let existingTask: AgentTask?

    init(isPresented: Binding<Bool>, existingTask: AgentTask? = nil, onSave: @escaping (AgentTask) -> Void) {
        self._isPresented = isPresented
        self.existingTask = existingTask
        self.onSave = onSave
    }

    private var modelOptions: [AppConfig.LLMModelOption] {
        var options = AppConfig.llmModelOptions
        if !options.contains(where: { $0.id == model }) {
            options.insert(.init(id: model, label: "自定义: \(model)"), at: 0)
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("任务名称", text: $name)
                        .font(.system(size: 14))
                    TextEditor(text: $description)
                        .font(.system(size: 14))
                        .frame(height: 80)
                    Toggle("启用", isOn: $isEnabled)
                }
                
                Section("触发器") {
                    Picker("触发类型", selection: $triggerKind) {
                        Text("手动").tag(TriggerKind.manual)
                        Text("定时 (Cron)").tag(TriggerKind.cron)
                        Text("记录创建").tag(TriggerKind.onRecordCreate)
                        Text("记录更新").tag(TriggerKind.onRecordUpdate)
                    }
                    .font(.system(size: 14))

                    if triggerKind == .cron {
                        TextField("Cron 表达式", text: $cronExpression)
                            .font(.system(size: 14).monospaced())
                    }
                }

                Section("动作") {
                    Picker("动作类型", selection: $actionKind) {
                        Text("LLM API").tag(ActionKind.claudeAPI)
                        Text("Shell 命令").tag(ActionKind.shellCommand)
                        Text("创建记录").tag(ActionKind.createRecord)
                        Text("追加到记录").tag(ActionKind.appendToRecord)
                    }
                    .font(.system(size: 14))

                    if actionKind == .claudeAPI {
                        Picker("模型预设", selection: $model) {
                            ForEach(modelOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("模型 (provider:model)", text: $model)
                            .font(.system(size: 14).monospaced())
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 14))
                            .frame(height: 80)
                            .overlay(alignment: .topLeading) {
                                if systemPrompt.isEmpty {
                                    Text("System Prompt")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 10)
                                }
                            }
                        TextEditor(text: $userPrompt)
                            .font(.system(size: 14))
                            .frame(height: 120)
                            .overlay(alignment: .topLeading) {
                                if userPrompt.isEmpty {
                                    Text("User Prompt")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 10)
                                }
                            }
                    } else if actionKind == .shellCommand {
                        TextField("命令", text: $shellCommand)
                            .font(.system(size: 14).monospaced())
                    } else if actionKind == .createRecord {
                        TextField("记录标题", text: $createTitle)
                            .font(.system(size: 14))
                        TextEditor(text: $actionTemplate)
                            .font(.system(size: 14))
                            .frame(height: 100)
                    } else if actionKind == .appendToRecord {
                        TextField("目标记录 ID", text: $appendRecordID)
                            .font(.system(size: 14).monospaced())
                        TextEditor(text: $actionTemplate)
                            .font(.system(size: 14))
                            .frame(height: 100)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingTask == nil ? "新建 Agent 任务" : "编辑 Agent 任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveTask()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(width: 500, height: 600)
        .onAppear { loadExistingTaskIfNeeded() }
    }

    private func saveTask() {
        let trigger: AgentTask.Trigger
        switch triggerKind {
        case .manual: trigger = .manual
        case .cron: trigger = .cron(expression: cronExpression.trimmingCharacters(in: .whitespacesAndNewlines))
        case .onRecordCreate: trigger = .onRecordCreate(tagFilter: [])
        case .onRecordUpdate: trigger = .onRecordUpdate(tagFilter: [])
        }

        let action: AgentTask.AgentAction
        switch actionKind {
        case .claudeAPI:
            action = .claudeAPI(
                systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                userPromptTemplate: userPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .shellCommand:
            action = .shellCommand(command: shellCommand.trimmingCharacters(in: .whitespacesAndNewlines))
        case .createRecord:
            action = .createRecord(
                title: createTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                contentTemplate: actionTemplate
            )
        case .appendToRecord:
            action = .appendToRecord(
                recordID: appendRecordID.trimmingCharacters(in: .whitespacesAndNewlines),
                contentTemplate: actionTemplate
            )
        }

        let task = AgentTask(
            id: existingTask?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            templateID: existingTask?.templateID,
            trigger: trigger,
            action: action,
            isEnabled: isEnabled,
            lastRunAt: existingTask?.lastRunAt,
            nextRunAt: existingTask?.nextRunAt,
            createdAt: existingTask?.createdAt ?? Date(),
            outputTagID: existingTask?.outputTagID
        )
        
        onSave(task)
        isPresented = false
    }

    private func loadExistingTaskIfNeeded() {
        guard let task = existingTask else { return }
        name = task.name
        description = task.description
        isEnabled = task.isEnabled

        switch task.trigger {
        case .manual:
            triggerKind = .manual
        case .cron(let expr):
            triggerKind = .cron
            cronExpression = expr
        case .onRecordCreate:
            triggerKind = .onRecordCreate
        case .onRecordUpdate:
            triggerKind = .onRecordUpdate
        }

        switch task.action {
        case .claudeAPI(let system, let userTemplate, let selectedModel):
            actionKind = .claudeAPI
            systemPrompt = system
            userPrompt = userTemplate
            model = selectedModel
        case .shellCommand(let command):
            actionKind = .shellCommand
            shellCommand = command
        case .createRecord(let title, let contentTemplate):
            actionKind = .createRecord
            createTitle = title
            actionTemplate = contentTemplate
        case .appendToRecord(let recordID, let contentTemplate):
            actionKind = .appendToRecord
            appendRecordID = recordID
            actionTemplate = contentTemplate
        }
    }
}
