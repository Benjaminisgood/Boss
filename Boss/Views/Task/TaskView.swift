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
    let onEdit: (() -> Void)?

    init(task: TaskItem, vm: TaskViewModel, onEdit: (() -> Void)? = nil) {
        self.task = task
        self.vm = vm
        self.onEdit = onEdit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                if let onEdit {
                    Button("编辑任务") {
                        onEdit()
                    }
                    .buttonStyle(.bordered)
                }
            }

            GroupBox("任务信息") {
                LabeledContent("名称", value: task.name)
                LabeledContent("描述", value: task.description)
                LabeledContent("状态", value: task.isEnabled ? "启用" : "停用")
                LabeledContent("触发", value: triggerSummary(task.trigger))
                LabeledContent("动作", value: actionSummary(task.action))
                if let last = task.lastRunAt {
                    LabeledContent("上次运行", value: last.formatted())
                }
                if let next = task.nextRunAt {
                    LabeledContent("下次运行", value: next.formatted())
                }
            }

            if case .openClawJob(let template, let recordRef, let includeCore, let includeManifest) = task.action {
                GroupBox("OpenClaw Job") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("record ref: \(recordRef ?? "-")")
                        Text("include core: \(includeCore ? "yes" : "no")")
                        Text("include skills manifest: \(includeManifest ? "yes" : "no")")
                        Text("instruction:")
                        Text(shortText(template, limit: 380))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .onChange(of: task.id) { _, id in
            vm.loadLogs(for: id)
        }
    }

    private func triggerSummary(_ trigger: TaskItem.Trigger) -> String {
        switch trigger {
        case .manual:
            return "手动"
        case .heartbeat(let intervalMinutes):
            return "心跳 \(max(1, intervalMinutes)) 分钟"
        case .cron(let expression):
            return "Cron: \(expression)"
        case .onRecordCreate(let tagFilter):
            return tagFilter.isEmpty ? "记录创建" : "记录创建（tags: \(tagFilter.joined(separator: ","))）"
        case .onRecordUpdate(let tagFilter):
            return tagFilter.isEmpty ? "记录更新" : "记录更新（tags: \(tagFilter.joined(separator: ","))）"
        }
    }

    private func actionSummary(_ action: TaskItem.TaskAction) -> String {
        switch action {
        case .openClawJob:
            return "OpenClaw Job"
        case .createRecord:
            return "Legacy: createRecord（已停用）"
        case .appendToRecord:
            return "Legacy: appendToRecord（已停用）"
        case .shellCommand:
            return "Legacy: shellCommand（已停用）"
        case .claudeAPI:
            return "Legacy: claudeAPI（已停用）"
        }
    }

    private func shortText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "..."
    }
}

// MARK: - Skill Library
@MainActor
final class SkillLibraryViewModel: ObservableObject {
    @Published var skills: [ProjectSkill] = []
    @Published var selectedSkillID: String? = nil
    @Published var errorMessage: String? = nil

    private let repo = TaskRepository()

    func loadSkills() {
        do {
            let fetched = try repo.fetchAllSkills()
            skills = fetched
            if let selectedSkillID, !fetched.contains(where: { $0.id == selectedSkillID }) {
                self.selectedSkillID = fetched.first?.id
            } else if selectedSkillID == nil {
                selectedSkillID = fetched.first?.id
            }
            errorMessage = nil
        } catch {
            skills = []
            errorMessage = error.localizedDescription
        }
    }

    func createSkill(_ skill: ProjectSkill) {
        do {
            try repo.createSkill(skill)
            loadSkills()
            selectedSkillID = skill.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSkill(_ skill: ProjectSkill) {
        var updated = skill
        updated.updatedAt = Date()
        do {
            try repo.updateSkill(updated)
            loadSkills()
            selectedSkillID = skill.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleEnabled(_ skill: ProjectSkill) {
        var updated = skill
        updated.isEnabled.toggle()
        updated.updatedAt = Date()
        do {
            try repo.updateSkill(updated)
            loadSkills()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSkill(_ skill: ProjectSkill) {
        do {
            try repo.deleteSkill(id: skill.id)
            loadSkills()
            if selectedSkillID == skill.id {
                selectedSkillID = skills.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
    enum LayoutMode {
        case modal
        case inline
    }

    private enum ActionKind: String, CaseIterable, Identifiable {
        case llmPrompt
        case shellCommand
        case createRecord
        case appendToRecord

        var id: String { rawValue }
    }

    @Binding private var isPresented: Bool
    private let layoutMode: LayoutMode
    private let onCancelInline: (() -> Void)?
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
        self.layoutMode = .modal
        self.onCancelInline = nil
        self.existingSkill = existingSkill
        self.onSave = onSave
    }

    init(
        layoutMode: LayoutMode = .inline,
        existingSkill: ProjectSkill? = nil,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping (ProjectSkill) -> Void
    ) {
        self._isPresented = .constant(true)
        self.layoutMode = layoutMode
        self.onCancelInline = onCancel
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

    private var editorTitle: String {
        existingSkill == nil ? "新建技能" : "编辑技能"
    }

    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .onChange(of: existingSkill?.id) { _, _ in
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
                            saveSkill()
                        }
                        .disabled(isSaveDisabled)
                    }
                }
        }
        .frame(width: 640, height: 430)
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
                    saveSkill()
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
                Text("定义技能的触发场景和执行动作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("基本信息") {
                TextField("技能名称", text: $name)
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
        loadExistingSkillIfNeeded()
    }

    private func resetForm() {
        name = ""
        description = ""
        triggerHint = ""
        isEnabled = true
        actionKind = .llmPrompt
        model = AppConfig.shared.claudeModel
        systemPrompt = "你是该技能的执行助手。"
        userPromptTemplate = "{{input}}"
        shellCommand = ""
        filenameTemplate = "skill-note-{{date}}.txt"
        contentTemplate = "{{input}}"
        appendRecordRef = "TODAY"
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
                    Text("中列输入对话问题，右列查看回答与上下文元信息。Boss 内部不直接执行写操作，外部执行由 OpenClaw Runtime 负责。")
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
                Button("发送") {
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
            Text("对话输出")
                .fontWeight(.semibold)

            GroupBox {
                ScrollView {
                    Text(state.result?.reply ?? "等待回复...")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 220)

            if let result = state.result {
                GroupBox("元信息") {
                    VStack(alignment: .leading, spacing: 6) {
                        let relaySignals = result.actions.filter { $0.hasPrefix("openclaw.relay:") }
                        let relayStatus = relaySignals.last ?? "openclaw.relay:disabled"
                        Text("intent: \(result.intent)")
                        Text("status: \(result.succeeded ? "success" : "failed")")
                        Text("planner: \(result.plannerSource)")
                        Text("mode: conversation_only")
                        if let plannerNote = result.plannerNote, !plannerNote.isEmpty {
                            Text("planner note: \(plannerNote)")
                        }
                        if !result.toolPlan.isEmpty {
                            Text("tool plan: \(result.toolPlan.joined(separator: " -> "))")
                        }
                        Text("openclaw relay: \(relayStatus)")
                        Text("core context count: \(result.coreContextRecordIDs.count)")
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
