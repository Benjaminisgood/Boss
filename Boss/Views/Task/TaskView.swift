import SwiftUI
import Combine

// MARK: - TaskView (任务管理界面)
struct TaskView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = TaskViewModel()
    @State private var showNewTask = false

    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        NavigationSplitView {
            List(vm.tasks, selection: $vm.selectedTaskID) { task in
                TaskRowView(task: task, vm: vm)
                    .tag(task.id)
            }
            .navigationTitle("任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showsCloseButton {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showNewTask = true } label: {
                        Image(systemName: "plus")
                    }
                    .help("新增任务")
                }
            }
        } detail: {
            if let id = vm.selectedTaskID, let task = vm.tasks.first(where: { $0.id == id }) {
                TaskDetailView(task: task, vm: vm)
            } else {
                Text("选择或创建任务").foregroundColor(.secondary)
            }
        }
        .onAppear { vm.loadTasks() }
        .sheet(isPresented: $showNewTask) {
            TaskEditorView(isPresented: $showNewTask) {
                vm.createTask($0)
            }
        }
    }
}

// MARK: - Task Row
struct TaskRowView: View {
    let task: TaskItem
    @ObservedObject var vm: TaskViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(task.name).fontWeight(.medium)
                Text(task.description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { _ in vm.toggleEnabled(task) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

// MARK: - Task Detail
struct TaskDetailView: View {
    let task: TaskItem
    @ObservedObject var vm: TaskViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("任务信息") {
                LabeledContent("名称", value: task.name)
                LabeledContent("描述", value: task.description)
                LabeledContent("状态", value: task.isEnabled ? "启用" : "停用")
                if let last = task.lastRunAt {
                    LabeledContent("上次运行", value: last.formatted())
                }
                if let next = task.nextRunAt {
                    LabeledContent("下次运行", value: next.formatted())
                }
            }

            Button {
                vm.runNow(task)
                vm.loadLogs(for: task.id)
            } label: {
                Label(vm.isRunning ? "运行中..." : "立即运行", systemImage: "play.fill")
            }
            .disabled(vm.isRunning)
            .buttonStyle(.borderedProminent)

            GroupBox("运行日志") {
                if vm.runLogs.isEmpty {
                    Text("暂无日志").foregroundColor(.secondary)
                } else {
                    Table(vm.runLogs) {
                        TableColumn("时间") { log in
                            Text(log.startedAt.formatted(date: .omitted, time: .standard))
                        }
                        TableColumn("状态") { log in
                            Text(log.status.rawValue)
                                .foregroundColor(log.status == .success ? .green : .red)
                        }
                        TableColumn("输出") { log in
                            Text(log.output.prefix(100))
                                .font(.caption.monospaced())
                        }
                    }
                    .frame(height: 200)
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle(task.name)
        .onAppear { vm.loadLogs(for: task.id) }
    }
}

// MARK: - Skill Library
@MainActor
final class SkillLibraryViewModel: ObservableObject {
    @Published var skills: [ProjectSkill] = []
    @Published var selectedSkillID: String? = nil

    private let repo = TaskRepository()

    func loadSkills() {
        skills = (try? repo.fetchAllSkills()) ?? []
        if selectedSkillID == nil {
            selectedSkillID = skills.first?.id
        }
    }

    func createSkill(_ skill: ProjectSkill) {
        try? repo.createSkill(skill)
        loadSkills()
        selectedSkillID = skill.id
    }

    func updateSkill(_ skill: ProjectSkill) {
        var updated = skill
        updated.updatedAt = Date()
        try? repo.updateSkill(updated)
        loadSkills()
        selectedSkillID = skill.id
    }

    func toggleEnabled(_ skill: ProjectSkill) {
        var updated = skill
        updated.isEnabled.toggle()
        updated.updatedAt = Date()
        try? repo.updateSkill(updated)
        loadSkills()
    }

    func deleteSkill(_ skill: ProjectSkill) {
        try? repo.deleteSkill(id: skill.id)
        loadSkills()
        if selectedSkillID == skill.id {
            selectedSkillID = skills.first?.id
        }
    }
}

struct SkillLibraryView: View {
    @StateObject private var vm = SkillLibraryViewModel()
    @State private var showNewSkill = false
    @State private var editingSkill: ProjectSkill? = nil

    var body: some View {
        NavigationSplitView {
            List(vm.skills, selection: $vm.selectedSkillID) { skill in
                SkillRowView(skill: skill, onToggle: { vm.toggleEnabled(skill) })
                    .tag(skill.id)
                    .contextMenu {
                        Button("编辑 Skill") {
                            editingSkill = skill
                        }
                        Button("删除 Skill", role: .destructive) {
                            vm.deleteSkill(skill)
                        }
                    }
            }
            .navigationTitle("项目 Skill")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewSkill = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("新增 Skill")
                }
            }
        } detail: {
            if let id = vm.selectedSkillID, let skill = vm.skills.first(where: { $0.id == id }) {
                SkillDetailView(skill: skill, onEdit: {
                    editingSkill = skill
                })
            } else {
                Text("选择或创建 Skill")
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { vm.loadSkills() }
        .sheet(isPresented: $showNewSkill) {
            ProjectSkillEditorView(isPresented: $showNewSkill) { skill in
                vm.createSkill(skill)
            }
        }
        .sheet(item: $editingSkill) { skill in
            ProjectSkillEditorView(
                isPresented: Binding(
                    get: { editingSkill != nil },
                    set: { shown in
                        if !shown { editingSkill = nil }
                    }
                ),
                existingSkill: skill
            ) { updatedSkill in
                vm.updateSkill(updatedSkill)
            }
        }
    }
}

struct SkillRowView: View {
    let skill: ProjectSkill
    let onToggle: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .fontWeight(.medium)
                    if !skill.isEnabled {
                        Text("停用")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { skill.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

struct SkillDetailView: View {
    let skill: ProjectSkill
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(skill.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("编辑") {
                        onEdit()
                    }
                }

                GroupBox("基本信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("状态", value: skill.isEnabled ? "启用" : "停用")
                        LabeledContent("触发提示", value: skill.triggerHint.isEmpty ? "-" : skill.triggerHint)
                        LabeledContent("创建时间", value: skill.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("更新时间", value: skill.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if !skill.description.isEmpty {
                    GroupBox("说明") {
                        Text(skill.description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("执行动作") {
                    Text(skillActionSummary(skill.action))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(skill.name)
    }

    private func skillActionSummary(_ action: ProjectSkill.SkillAction) -> String {
        switch action {
        case .llmPrompt(_, _, let model):
            return "LLM 调用（model: \(model)）"
        case .shellCommand(let command):
            return "Shell 命令\n\(command)"
        case .createRecord(let filenameTemplate, let contentTemplate):
            return "创建文本记录\nfilename_template: \(filenameTemplate)\ncontent_template: \(contentTemplate)"
        case .appendToRecord(let recordRef, let contentTemplate):
            return "追加到文本记录\nrecord_ref: \(recordRef)\ncontent_template: \(contentTemplate)"
        }
    }
}

// MARK: - Project Skill Editor
struct ProjectSkillEditorView: View {
    private enum ActionKind: String, CaseIterable, Identifiable {
        case llmPrompt
        case shellCommand
        case createRecord
        case appendToRecord

        var id: String { rawValue }
    }

    @Binding var isPresented: Bool
    let existingSkill: ProjectSkill?
    let onSave: (ProjectSkill) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var triggerHint = ""
    @State private var isEnabled = true

    @State private var actionKind: ActionKind = .llmPrompt
    @State private var model = AppConfig.shared.claudeModel
    @State private var systemPrompt = "你是该技能的执行助手。"
    @State private var userPromptTemplate = "{{input}}"
    @State private var shellCommand = ""
    @State private var filenameTemplate = "skill-note-{{date}}.txt"
    @State private var contentTemplate = "{{input}}"
    @State private var appendRecordRef = "TODAY"

    init(
        isPresented: Binding<Bool>,
        existingSkill: ProjectSkill? = nil,
        onSave: @escaping (ProjectSkill) -> Void
    ) {
        self._isPresented = isPresented
        self.existingSkill = existingSkill
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
                Section {
                    Text("定义 Skill 的触发场景和执行动作。关闭窗口会放弃未保存修改。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("基本信息") {
                    TextField("Skill 名称", text: $name)
                        .font(.system(size: 14))
                    TextEditor(text: $description)
                        .font(.system(size: 14))
                        .frame(minHeight: 72, maxHeight: 96)
                    TextField("触发提示（关键词/场景）", text: $triggerHint)
                        .font(.system(size: 14))
                    Toggle("启用", isOn: $isEnabled)
                }

                Section("动作") {
                    Picker("动作类型", selection: $actionKind) {
                        Text("LLM 调用").tag(ActionKind.llmPrompt)
                        Text("Shell 命令").tag(ActionKind.shellCommand)
                        Text("创建记录").tag(ActionKind.createRecord)
                        Text("追加到记录").tag(ActionKind.appendToRecord)
                    }
                    .pickerStyle(.menu)

                    switch actionKind {
                    case .llmPrompt:
                        Picker("模型预设", selection: $model) {
                            ForEach(modelOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("模型 (provider:model)", text: $model)
                            .font(.system(size: 13).monospaced())

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 14))
                            .frame(minHeight: 86, maxHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if systemPrompt.isEmpty {
                                    Text("System Prompt")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 10)
                                }
                            }

                        TextEditor(text: $userPromptTemplate)
                            .font(.system(size: 14))
                            .frame(minHeight: 100, maxHeight: 120)
                            .overlay(alignment: .topLeading) {
                                if userPromptTemplate.isEmpty {
                                    Text("User Prompt Template")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 10)
                                }
                            }

                    case .shellCommand:
                        TextField("命令", text: $shellCommand)
                            .font(.system(size: 13).monospaced())

                    case .createRecord:
                        TextField("文件名模板", text: $filenameTemplate)
                            .font(.system(size: 13).monospaced())
                        TextEditor(text: $contentTemplate)
                            .font(.system(size: 14))
                            .frame(minHeight: 100, maxHeight: 120)

                    case .appendToRecord:
                        TextField("目标记录引用（UUID/TODAY/明天）", text: $appendRecordRef)
                            .font(.system(size: 13).monospaced())
                        TextEditor(text: $contentTemplate)
                            .font(.system(size: 14))
                            .frame(minHeight: 100, maxHeight: 120)
                    }
                }

                Section("模板变量") {
                    Text("{{input}} = 当前用户请求（或 tool 输入）")
                    Text("{{request}} = 原始请求全文")
                    Text("{{date}} = yyyy-MM-dd")
                    Text("{{timestamp}} = yyyyMMdd-HHmmss")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(existingSkill == nil ? "新增 Skill" : "编辑 Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveSkill()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 640, height: 430)
        .onAppear { loadExistingSkillIfNeeded() }
    }

    private func saveSkill() {
        let action: ProjectSkill.SkillAction
        switch actionKind {
        case .llmPrompt:
            action = .llmPrompt(
                systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                userPromptTemplate: userPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .shellCommand:
            action = .shellCommand(command: shellCommand.trimmingCharacters(in: .whitespacesAndNewlines))
        case .createRecord:
            action = .createRecord(
                filenameTemplate: filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
                contentTemplate: contentTemplate
            )
        case .appendToRecord:
            action = .appendToRecord(
                recordRef: appendRecordRef.trimmingCharacters(in: .whitespacesAndNewlines),
                contentTemplate: contentTemplate
            )
        }

        let now = Date()
        let skill = ProjectSkill(
            id: existingSkill?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            triggerHint: triggerHint.trimmingCharacters(in: .whitespacesAndNewlines),
            action: action,
            isEnabled: isEnabled,
            createdAt: existingSkill?.createdAt ?? now,
            updatedAt: now
        )

        onSave(skill)
        isPresented = false
    }

    private func loadExistingSkillIfNeeded() {
        guard let skill = existingSkill else { return }
        name = skill.name
        description = skill.description
        triggerHint = skill.triggerHint
        isEnabled = skill.isEnabled

        switch skill.action {
        case .llmPrompt(let system, let userTemplate, let savedModel):
            actionKind = .llmPrompt
            systemPrompt = system
            userPromptTemplate = userTemplate
            model = savedModel
        case .shellCommand(let command):
            actionKind = .shellCommand
            shellCommand = command
        case .createRecord(let savedFilenameTemplate, let savedContentTemplate):
            actionKind = .createRecord
            filenameTemplate = savedFilenameTemplate
            contentTemplate = savedContentTemplate
        case .appendToRecord(let recordRef, let savedContentTemplate):
            actionKind = .appendToRecord
            appendRecordRef = recordRef
            contentTemplate = savedContentTemplate
        }
    }
}

// MARK: - Assistant Workspace State
@MainActor
final class AssistantWorkspaceState: ObservableObject {
    @Published var source = "user"
    @Published var request = ""
    @Published var isRunning = false
    @Published var result: AssistantKernelResult?
    @Published var history: [AssistantHistoryItem] = []

    func runAssistant() {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isRunning = true
        let sourceValue = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "user" : source
        history.insert(.init(text: "REQ(\(sourceValue)): \(trimmed)"), at: 0)

        Task {
            let output = await AssistantKernelService.shared.handle(request: trimmed, source: sourceValue)
            await MainActor.run {
                result = output
                history.insert(.init(text: "RES: \(output.reply)"), at: 0)
                if history.count > 30 {
                    history = Array(history.prefix(30))
                }
                isRunning = false
            }
        }
    }

    func clearInput() {
        request = ""
    }
}

// MARK: - Assistant Workspace Columns
struct AssistantInputColumnView: View {
    @ObservedObject var state: AssistantWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("项目助理") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("中列输入任务，右列查看执行输出。高风险动作会返回确认令牌，需再发送 #CONFIRM:<token>。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("来源")
                        TextField("source", text: $state.source)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Text("需求输入")
                .fontWeight(.semibold)

            TextEditor(text: $state.request)
                .font(.system(size: 13))
                .frame(minHeight: 240)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Button("执行") {
                    state.runAssistant()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isRunning || state.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if state.isRunning {
                    ProgressView()
                }

                Spacer()

                Button("清空输入") {
                    state.clearInput()
                }
                .buttonStyle(.bordered)
            }

            if !state.history.isEmpty {
                GroupBox("最近请求") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(state.history) { item in
                                Text("[\(item.time)] \(item.text)")
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct AssistantOutputColumnView: View {
    @ObservedObject var state: AssistantWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("执行输出")
                .fontWeight(.semibold)

            GroupBox {
                ScrollView {
                    Text(state.result?.reply ?? "等待执行...")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 220)

            if let result = state.result {
                GroupBox("元信息") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("intent: \(result.intent)")
                        Text("status: \(result.confirmationRequired ? "pending-confirmation" : (result.succeeded ? "success" : "failed"))")
                        Text("planner: \(result.plannerSource)")
                        if let plannerNote = result.plannerNote, !plannerNote.isEmpty {
                            Text("planner note: \(plannerNote)")
                        }
                        if !result.toolPlan.isEmpty {
                            Text("tool plan: \(result.toolPlan.joined(separator: " -> "))")
                        }
                        Text("confirmation required: \(result.confirmationRequired ? "yes" : "no")")
                        if let token = result.confirmationToken {
                            Text("confirmation token: \(token)")
                        }
                        if let expires = result.confirmationExpiresAt {
                            Text("confirmation expires: \(expires.formatted(date: .abbreviated, time: .standard))")
                        }
                        Text("core memory: \(result.coreMemoryRecordID ?? "-")")
                        Text("audit log: \(result.auditRecordID ?? "-")")
                        Text("related records: \(result.relatedRecordIDs.joined(separator: ", "))")
                    }
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Assistant Console Window (兼容独立窗口)
struct AssistantConsoleView: View {
    @StateObject private var state = AssistantWorkspaceState()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantInputColumnView(state: state)
            AssistantOutputColumnView(state: state)
        }
        .padding(14)
    }
}

struct AssistantHistoryItem: Identifiable {
    let id = UUID().uuidString
    let text: String
    let time: String

    init(text: String) {
        self.text = text
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.time = formatter.string(from: Date())
    }
}
