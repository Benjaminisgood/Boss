import SwiftUI

// MARK: - AgentView (Agent 管理界面)
struct AgentView: View {
    @StateObject private var vm = AgentViewModel()
    @State private var showNewTask = false
    @State private var showAssistant = false

    var body: some View {
        NavigationSplitView {
            // Task List
            List(vm.tasks, selection: $vm.selectedTaskID) { task in
                AgentTaskRowView(task: task, vm: vm)
                    .tag(task.id)
            }
            .navigationTitle("Agent 任务")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showAssistant = true } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .help("打开项目助理")

                    Button { showNewTask = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let id = vm.selectedTaskID, let task = vm.tasks.first(where: { $0.id == id }) {
                AgentTaskDetailView(task: task, vm: vm)
            } else {
                Text("选择或创建任务").foregroundColor(.secondary)
            }
        }
        .onAppear { vm.loadTasks() }
        .sheet(isPresented: $showNewTask) {
            AgentTaskEditorView(isPresented: $showNewTask) {
                vm.createTask($0)
            }
        }
        .sheet(isPresented: $showAssistant) {
            AssistantConsoleView()
                .frame(width: 760, height: 600)
        }
    }
}

// MARK: - Task Row
struct AgentTaskRowView: View {
    let task: AgentTask
    @ObservedObject var vm: AgentViewModel

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
struct AgentTaskDetailView: View {
    let task: AgentTask
    @ObservedObject var vm: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 基本信息
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

            // 立即运行
            Button {
                vm.runNow(task)
                vm.loadLogs(for: task.id)
            } label: {
                Label(vm.isRunning ? "运行中..." : "立即运行", systemImage: "play.fill")
            }
            .disabled(vm.isRunning)
            .buttonStyle(.borderedProminent)

            // 运行日志
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

// MARK: - Assistant Console
struct AssistantConsoleView: View {
    @State private var source = "user"
    @State private var request = ""
    @State private var isRunning = false
    @State private var result: AssistantKernelResult?
    @State private var history: [AssistantHistoryItem] = []

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(alignment: .top, spacing: 12) {
                inputPanel
                outputPanel
            }
        }
        .padding(14)
    }

    private var header: some View {
        GroupBox("轻量助理内核") {
            VStack(alignment: .leading, spacing: 6) {
                Text("输入自然语言任务，助理会读取 Core 记忆并先由 LLM 规划工具调用（类 MCP），再执行内部动作并写入 Core/Audit。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("高风险工具调用（删除/改写）会先返回确认令牌，需再发送 `#CONFIRM:<token>` 才会执行。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack {
                    Text("来源")
                    TextField("source", text: $source)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("需求输入").fontWeight(.semibold)
            TextEditor(text: $request)
                .font(.system(size: 13))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Button("执行") {
                    runAssistant()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isRunning {
                    ProgressView()
                }

                Spacer()

                Button("清空输入") {
                    request = ""
                }
                .buttonStyle(.bordered)
            }

            if !history.isEmpty {
                GroupBox("最近请求") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(history) { item in
                                Text("[\(item.time)] \(item.text)")
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("执行输出").fontWeight(.semibold)
            GroupBox {
                ScrollView {
                    Text(result?.reply ?? "等待执行...")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 200)

            if let result {
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func runAssistant() {
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
}

private struct AssistantHistoryItem: Identifiable {
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
