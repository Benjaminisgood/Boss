import SwiftUI

// MARK: - TaskEditorView (Boss Jobs 编辑器)
struct TaskEditorView: View {
    enum LayoutMode {
        case modal
        case inline
    }

    private enum TriggerKind: String, CaseIterable, Identifiable {
        case manual
        case heartbeat
        case cron
        case onRecordCreate
        case onRecordUpdate

        var id: String { rawValue }
    }

    @Binding private var isPresented: Bool
    private let layoutMode: LayoutMode
    private let onCancelInline: (() -> Void)?

    @State private var name = ""
    @State private var description = ""
    @State private var triggerKind: TriggerKind = .heartbeat
    @State private var heartbeatMinutes = "15"
    @State private var cronExpression = "*/30 * * * *"
    @State private var eventTagFilterText = ""

    @State private var instructionTemplate = """
请根据以下任务说明执行操作，并返回执行摘要：
- 任务名称：{{task_name}}
- 任务描述：{{task_description}}
- 触发记录ID：{{record_id}}
- 触发记录文件：{{record_filename}}
- 触发记录摘要：{{record_preview}}
"""
    @State private var instructionRecordRef = "EVENT_RECORD"
    @State private var includeCoreMemory = true
    @State private var includeSkillManifest = true
    @State private var isEnabled = true

    let onSave: (TaskItem) -> Void
    let existingTask: TaskItem?

    init(
        isPresented: Binding<Bool>,
        existingTask: TaskItem? = nil,
        onSave: @escaping (TaskItem) -> Void
    ) {
        self._isPresented = isPresented
        self.layoutMode = .modal
        self.onCancelInline = nil
        self.existingTask = existingTask
        self.onSave = onSave
    }

    init(
        layoutMode: LayoutMode = .inline,
        existingTask: TaskItem? = nil,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping (TaskItem) -> Void
    ) {
        self._isPresented = .constant(true)
        self.layoutMode = layoutMode
        self.onCancelInline = onCancel
        self.existingTask = existingTask
        self.onSave = onSave
    }

    private var editorTitle: String {
        existingTask == nil ? "新建任务" : "编辑任务"
    }

    private var isSaveDisabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instructionTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty || trimmedInstruction.isEmpty
    }

    var body: some View {
        Group {
            switch layoutMode {
            case .modal:
                modalBody
            case .inline:
                inlineBody
            }
        }
        .onAppear(perform: prepareForm)
        .onChange(of: existingTask?.id) { _, _ in
            prepareForm()
        }
    }

    private var modalBody: some View {
        NavigationStack {
            editorForm
                .navigationTitle(editorTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            dismissEditor()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveTask()
                        }
                        .disabled(isSaveDisabled)
                    }
                }
        }
        .frame(width: 760, height: 560)
    }

    private var inlineBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(editorTitle)
                    .font(.headline)
                Spacer()
                Button("取消") {
                    dismissEditor()
                }
                .buttonStyle(.bordered)
                Button("保存") {
                    saveTask()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            editorForm
        }
    }

    private var editorForm: some View {
        Form {
            Section {
                Text("Boss 任务只负责在触发条件满足时把自然语言 job 投递给 OpenClaw，不在本地执行操作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("基本信息") {
                TextField("任务名称", text: $name)
                    .font(.system(size: 14))
                TextEditor(text: $description)
                    .font(.system(size: 14))
                    .frame(minHeight: 68, maxHeight: 96)
                Toggle("启用", isOn: $isEnabled)
            }

            Section("触发条件（何时主动通信 OpenClaw）") {
                Picker("触发类型", selection: $triggerKind) {
                    Text("手动").tag(TriggerKind.manual)
                    Text("心跳轮询").tag(TriggerKind.heartbeat)
                    Text("定时 Cron").tag(TriggerKind.cron)
                    Text("记录创建").tag(TriggerKind.onRecordCreate)
                    Text("记录更新").tag(TriggerKind.onRecordUpdate)
                }
                .pickerStyle(.menu)

                if triggerKind == .heartbeat {
                    TextField("心跳间隔（分钟）", text: $heartbeatMinutes)
                        .font(.system(size: 13).monospaced())
                    Text("建议 >= 5 分钟，避免高频触发。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if triggerKind == .cron {
                    TextField("Cron 表达式（5段）", text: $cronExpression)
                        .font(.system(size: 13).monospaced())
                }

                if triggerKind == .onRecordCreate || triggerKind == .onRecordUpdate {
                    TextField("标签过滤（可选，逗号分隔 tagID）", text: $eventTagFilterText)
                        .font(.system(size: 13).monospaced())
                }
            }

            Section("OpenClaw Job 描述") {
                TextEditor(text: $instructionTemplate)
                    .font(.system(size: 13))
                    .frame(minHeight: 160, maxHeight: 240)

                TextField("附加说明来源记录（可选：EVENT_RECORD / 记录ID / 搜索词）", text: $instructionRecordRef)
                    .font(.system(size: 13).monospaced())

                Toggle("附带 Core 记忆上下文", isOn: $includeCoreMemory)
                Toggle("附带 Skills Manifest", isOn: $includeSkillManifest)
            }

            Section("模板变量") {
                Text("{{task_name}} / {{task_description}}")
                Text("{{record_id}} / {{record_filename}} / {{record_preview}} / {{record_text}}")
                Text("{{date}} / {{timestamp}}")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    private func saveTask() {
        let parsedTagFilter = parseTagFilter(eventTagFilterText)
        let trigger: TaskItem.Trigger
        switch triggerKind {
        case .manual:
            trigger = .manual
        case .heartbeat:
            let interval = max(1, Int(heartbeatMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 15)
            trigger = .heartbeat(intervalMinutes: interval)
        case .cron:
            let expr = cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            trigger = .cron(expression: expr.isEmpty ? "*/30 * * * *" : expr)
        case .onRecordCreate:
            trigger = .onRecordCreate(tagFilter: parsedTagFilter)
        case .onRecordUpdate:
            trigger = .onRecordUpdate(tagFilter: parsedTagFilter)
        }

        let action = TaskItem.TaskAction.openClawJob(
            instructionTemplate: instructionTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            instructionRecordRef: instructionRecordRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : instructionRecordRef.trimmingCharacters(in: .whitespacesAndNewlines),
            includeCoreMemory: includeCoreMemory,
            includeSkillManifest: includeSkillManifest
        )

        let now = Date()
        let nextRunAt = seedNextRun(trigger: trigger, from: now)
        let task = TaskItem(
            id: existingTask?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            templateID: existingTask?.templateID,
            trigger: trigger,
            action: action,
            isEnabled: isEnabled,
            lastRunAt: existingTask?.lastRunAt,
            nextRunAt: nextRunAt,
            createdAt: existingTask?.createdAt ?? now,
            outputTagID: existingTask?.outputTagID
        )

        onSave(task)
        dismissEditor()
    }

    private func dismissEditor() {
        if layoutMode == .modal {
            isPresented = false
            return
        }
        onCancelInline?()
    }

    private func prepareForm() {
        resetForm()
        loadExistingTaskIfNeeded()
    }

    private func resetForm() {
        name = ""
        description = ""
        triggerKind = .heartbeat
        heartbeatMinutes = "15"
        cronExpression = "*/30 * * * *"
        eventTagFilterText = ""
        instructionTemplate = """
请根据以下任务说明执行操作，并返回执行摘要：
- 任务名称：{{task_name}}
- 任务描述：{{task_description}}
- 触发记录ID：{{record_id}}
- 触发记录文件：{{record_filename}}
- 触发记录摘要：{{record_preview}}
"""
        instructionRecordRef = "EVENT_RECORD"
        includeCoreMemory = true
        includeSkillManifest = true
        isEnabled = true
    }

    private func loadExistingTaskIfNeeded() {
        guard let task = existingTask else { return }
        name = task.name
        description = task.description
        isEnabled = task.isEnabled

        switch task.trigger {
        case .manual:
            triggerKind = .manual
        case .heartbeat(let intervalMinutes):
            triggerKind = .heartbeat
            heartbeatMinutes = "\(intervalMinutes)"
        case .cron(let expression):
            triggerKind = .cron
            cronExpression = expression
        case .onRecordCreate(let tagFilter):
            triggerKind = .onRecordCreate
            eventTagFilterText = tagFilter.joined(separator: ",")
        case .onRecordUpdate(let tagFilter):
            triggerKind = .onRecordUpdate
            eventTagFilterText = tagFilter.joined(separator: ",")
        }

        switch task.action {
        case .openClawJob(let template, let recordRef, let includeCore, let includeManifest):
            instructionTemplate = template
            instructionRecordRef = recordRef ?? ""
            includeCoreMemory = includeCore
            includeSkillManifest = includeManifest

        case .claudeAPI(let systemPrompt, let userPromptTemplate, let model):
            instructionTemplate = """
迁移自旧任务动作（claudeAPI）：
model: \(model)
system:
\(systemPrompt)

user_template:
\(userPromptTemplate)
"""
            instructionRecordRef = ""
            includeCoreMemory = false
            includeSkillManifest = false

        case .shellCommand(let command):
            instructionTemplate = """
迁移自旧任务动作（shellCommand）：
请在外部执行以下命令并返回摘要。
\(command)
"""
            instructionRecordRef = ""
            includeCoreMemory = false
            includeSkillManifest = false

        case .createRecord(let title, let contentTemplate):
            instructionTemplate = """
迁移自旧任务动作（createRecord）：
请创建记录，标题：\(title)
内容模板：
\(contentTemplate)
"""
            instructionRecordRef = ""
            includeCoreMemory = false
            includeSkillManifest = false

        case .appendToRecord(let recordID, let contentTemplate):
            instructionTemplate = """
迁移自旧任务动作（appendToRecord）：
请向记录 \(recordID) 追加内容。
内容模板：
\(contentTemplate)
"""
            instructionRecordRef = ""
            includeCoreMemory = false
            includeSkillManifest = false
        }
    }

    private func parseTagFilter(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func seedNextRun(trigger: TaskItem.Trigger, from date: Date) -> Date? {
        switch trigger {
        case .manual, .onRecordCreate, .onRecordUpdate:
            return nil
        case .heartbeat(let intervalMinutes):
            return Calendar.current.date(byAdding: .minute, value: max(1, intervalMinutes), to: date)
        case .cron(let expression):
            return CronParser.nextDate(expression: expression, after: date)
        }
    }
}
