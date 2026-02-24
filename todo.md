# Boss（Benoss Swift 版本）实现计划

## 项目概述

基于 GitHub 项目 `Benjaminisgood/Benoss`，实现一个功能相似但完全本地存储（不使用 OSS）的纯 Swift 版本。

### 原始项目分析

原始项目是一个基于阿里云 OSS 的个人博客日志系统网站，使用 Python 开发。主要功能包括：

1. **记录（内容）管理**：每条记录绑定一个内容对象（文本或文件），创建、编辑、删除
2. **标签系统**：强大的标签系统实现关联记录
3. **文件存储**：使用阿里云 OSS 存储内容文件
4. **CLI 工具**：提供命令行接口进行操作
5. **Web 界面**：提供网页界面查看和管理内容

## Swift 版本实现计划

### 技术栈选择

- **语言**：最新版 Swift
- **存储**：本地文件系统 + SQLite（FTS5 全文搜索）
- **UI 框架**：SwiftUI
- **应用架构**：macOS 原生应用（三栏 NavigationSplitView）
- **命令行工具**：Swift Argument Parser（可选，后续添加）
- **无外部依赖**：使用系统内置 SQLite3

### 架构分层

```
Boss/
├── BossApp.swift              # App 入口、AppDelegate、菜单命令
├── ContentView.swift          # 主窗口三栏布局
├── Models/
│   ├── Record.swift           # 核心记录模型（Record + Content + FileType）+ RecordFilter
│   ├── Tag.swift              # 多级标签模型 + TagTreeNode
│   └── AgentTask.swift        # Agent 任务/触发器/动作/日志模型
├── Database/
│   ├── Schema.swift           # 建表 SQL（records/tags/record_tags/agent_tasks/fts5）
│   └── DatabaseManager.swift  # SQLite3 原生封装（WAL模式、并发安全）
├── Repositories/
│   ├── RecordRepository.swift # 文件记录 CRUD + 文件类型识别 + FTS 搜索
│   ├── TagRepository.swift    # Tag CRUD + 层级树构建
│   └── AgentRepository.swift  # AgentTask CRUD + RunLog
├── ViewModels/
│   ├── RecordListViewModel.swift   # 列表/过滤/搜索（防抖）
│   ├── RecordDetailViewModel.swift # 文件详情/文本类内容编辑/替换文件
│   └── AgentViewModel.swift        # Agent 管理/执行
├── Views/
│   ├── Sidebar/SidebarView.swift           # 左栏：可点击过滤（全部/类型/标签/归档/置顶）
│   ├── RecordList/RecordListView.swift     # 中栏：搜索/导入文件/新建文本记录
│   ├── RecordDetail/RecordDetailView.swift # 右栏：文件详情/文本编辑/图片预览/替换文件
│   ├── Agent/AgentView.swift               # Agent 管理窗口
│   └── Settings/SettingsView.swift         # 设置（存储/编辑器/Agent）
├── Services/
│   ├── AppConfig.swift          # 配置单例（UserDefaults）
│   ├── FileStorageService.swift # 本地文件存储（替代 OSS）
│   └── SchedulerService.swift   # 定时任务调度器（cron-like）
└── Utils/
    └── Extensions.swift         # Color+Hex、ContentType 扩展
```

### 核心功能模块

#### 1. 项目结构搭建

- [x] 创建 macOS 应用项目结构（所有 Swift 源文件已创建）
- [x] 在 Xcode 中创建 macOS App 项目（Bundle ID: com.boss.app，Swift 6）
- [x] 将 Boss/ 目录下所有 .swift 文件添加到 Xcode Target
- [x] 确认 SQLite3.tbd 已链接（系统框架，Xcode 默认包含）
- [x] 配置 Info.plist：NSSupportsAutomaticGraphicsSwitching=YES

#### 2. 本地存储系统

- [x] DatabaseManager：SQLite3 原生封装，WAL 模式，读写并发分离
- [x] Schema：records / tags / record_tags / agent_tasks / agent_run_logs / FTS5
- [x] FileStorageService：本地文件 copy/save/delete/export
- [x] AppConfig：存储路径、主题、编辑器字号、Claude API Key

#### 3. 功能强化与进化

- [x] Record CRUD（RecordRepository，记录=单文件内容）
- [x] 全文搜索（FTS5 虚拟表 + 自动触发器同步）
- [x] 标签过滤（多标签 AND 逻辑）
- [x] 时间范围筛选（RecordFilter.dateRange）
- [x] 多级标签系统（Tag.parentID + TagTreeNode）
- [x] 轻量 Agent 框架（AgentTask：manual/cron/事件触发）
- [x] 定时任务调度器（SchedulerService，每60s检查）
- [x] Claude API 调用实现（SchedulerService.execute case .claudeAPI）
- [x] 完整 cron 表达式解析（CronParser.nextDate）
- [x] 事件触发型 Agent（onRecordCreate/onRecordUpdate）

#### 4. macOS 应用界面

- [x] 三栏 NavigationSplitView（Sidebar + List + Detail）
- [x] 侧边栏：可点击过滤（标签树/文件类型/归档/置顶）
- [x] 中栏：搜索框（防抖）、记录列表、导入文件/新建文本
- [x] 右栏：文件详情、文本类内容编辑、图片预览、标签选择器、替换文件
- [ ] Agent 管理独立窗口（⌘⇧A 快捷键）
- [x] 设置面板（三 Tab：通用/编辑器/Agent）
- [x] Markdown 预览（可选：用 WebView 渲染）
- [x] 标签创建/编辑 UI（TagEditorView，已实现并接入 Sidebar）
- [ ] Agent 任务创建 UI（AgentTaskEditorView，已实现并接入 AgentView）
- [x] 深色模式适配（已通过 preferredColorScheme 支持）

#### 5. 命令行工具（可选后续）

- [ ] 实现记录管理命令（swift-argument-parser）
- [ ] agent 调用接口

#### 6. 配置系统

- [x] AppConfig 本地配置（UserDefaults）
- [x] 应用内配置界面（SettingsView）
- [x] 自定义存储路径

#### 7. 待实现 Stub 列表（供后续实现）

| 文件 | 位置 | 内容 |
|------|------|------|
| （无） | - | 当前无阻塞性 stub |

## 本轮修复与优化记录（2026-02-24）

- 修复编译错误：`AgentTaskEditorView` 未加入 Xcode target，现已纳入工程并可编译。
- 补齐遗漏源码到 `project.pbxproj`：`AgentTaskEditorView`、`TagEditorView`、`AttachmentDropDelegate`、`MarkdownPreviewView`、`EventService`。
- 重构 `AgentTaskEditorView`：修复类型设计和占位逻辑，支持多触发器/多动作的有效保存。
- 修复 `TagEditorView` 数据模型字段错误，并接入已有颜色扩展与父标签选择。
- 修复 `RecordDetailView` 视图结构错误（`VStack` + `onDrop` 语法）。
- 修复 `AttachmentDropDelegate` 与 `DropDelegate` 协议签名不匹配问题。
- 修复 `MarkdownPreviewView` 的 macOS `WKWebView` API 误用。
- 接入事件触发：记录创建/更新后触发 `EventService`，执行匹配的 Agent 任务。
- 验证结果：`xcodebuild -project Boss.xcodeproj -scheme Boss -configuration Debug -sdk macosx build` 构建通过。

## 本轮重构与优化记录（2026-02-24，非兼容）

- 依据 `Benjaminisgood/Benoss` 的核心结构重构为：`Record` 绑定单个 `Content`（`kind` + `file_type` + 文件元信息）。
- 记录模型彻底从“笔记正文 + 附件数组”切换为“文件记录”，支持文本、网页、图片、视频、音频、日志、数据库、压缩包、文档、其他文件分类。
- `RecordRepository` 重写：支持导入文件建记录、新建文本记录、文本内容写回、替换文件、FTS 搜索与标签过滤。
- `Schema` 重构并加入旧表检测后的非兼容迁移（自动重建记录相关表）。
- `FileStorageService` 重写为 `records/<recordID>/<filename>` 存储布局，补充 MIME/sha256/size 元信息采集。
- 侧边栏重写为显式可点击项，修复“点不了”的交互问题。
- 中栏重写：导入文件、多文件创建记录、新建文本记录。
- 右栏重写：文件元信息、可见性、标签、替换文件、文本类文件内置编辑、图片内置预览。
- Agent 调度适配新数据结构：`createRecord/appendToRecord` 改为文本文件记录操作。
- 验证结果：`xcodebuild -project Boss.xcodeproj -scheme Boss -configuration Debug -sdk macosx build` 构建通过。

## 本轮增量优化记录（2026-02-24）

- `cmd+N` 新建文本记录增加“按文件名后缀判定 file_type”：
  - 例如 `*.html` 会归类为 `web`，不再固定为 `text`。
  - 同时保留文本类文件可编辑能力（`text/web/log`）。
- 增加上传文件快捷键：
  - 新增 `⌘O` 触发“导入文件”。
  - 同时保留工具栏导入按钮。
- 标签补齐编辑能力：
  - 侧边栏标签项支持右键菜单（编辑/删除）。
  - 复用 `TagEditorView` 进行编辑。
- 标签嵌套语义优化：
  - 选择父标签时会匹配父标签及其所有子标签（ANY 匹配），嵌套关系不再只是展示。
- 修复“已归档显示全部”的过滤错误：
  - 归档视图现在仅显示 `is_archived=1` 记录。

## Xcode 项目创建步骤

1. Xcode → File → New → Project → macOS → App
2. Product Name: `Boss`, Bundle Identifier: `com.boss.app`
3. Interface: SwiftUI, Language: Swift
4. 取消 Include Tests（后续再加）
5. 保存到 `/Users/ben/Desktop/myapp/Boss/`
6. 将 `Boss/` 子目录中所有 .swift 文件拖入 Xcode Project Navigator
7. Build & Run（⌘R）

## 注意事项

- 确保代码结构清晰，遵循 Swift 最佳实践
- 实现错误处理和边界情况处理
- 优化文件操作性能（WAL + 并发读）
- 确保界面美观易用（macOS HIG 规范）
- 随时记录和修改这个 todo 清单
- 新项目 Boss 与 Benoss 是独立项目，无兼容需求

## 应用内部集成“轻量版 Agent 内核”助理。

首先，我可以对助理说：要做什么，或者由外部的openclaw之类的Runtime 层通过此Boss的接口向这个项目助理传达自然语言需求（如你所见，这个Boss项目的助理管理着我的几乎所有日志记录笔记等电子资产，且拥有学习重组二次输出新的ai资产的能力，是一个“学习/表达的另我”）。

Boss的项目助理会解析来自其他agent或者我的自然语言意图，查看项目里标有持久记忆Core标签的内容，看看有没有相关项目/上下文。

明确行为目的之后调用内部的一些接口，比如检索、删除记录、编辑内容等等。获取所需的信息或者执行对应的操作，达成对应的目的。

把关键结论/决策摘要 → 写回持久记忆（即带上Core标签）并且全过程写 Audit Log（审计），也是通过写txt文本并且加特殊标签
实现。

最后做出回答，即告知我或者返还外部发起调用的agent结果。

### 实现步骤（动态更新）

- [x] 明确助理内核目标与边界：自然语言输入、内部动作执行、Core 记忆回写、Audit 审计落盘。
- [x] 设计统一请求处理流：`request -> parseIntent -> loadCoreContext -> executeAction -> writeCoreMemory -> writeAudit -> reply`。
- [x] 实现 `AssistantKernelService`：支持 `search/delete/append/replace/summarize/help` 等轻量意图。
- [x] 实现 Core/Audit 标签自动创建与复用：`Core` / `AuditLog`。
- [x] 实现“关键结论写回 Core + 全过程写 Audit”的文本记录落盘（含关联记录 ID）。
- [x] 集成应用内入口：提供助理控制台窗口（输入自然语言、查看回答与执行轨迹）。
- [x] 集成外部调用入口：CLI 增加 `assistant ask`，便于 Runtime 层直接发起自然语言需求。
- [x] 端到端验证：App 构建、CLI 构建、真实请求执行、回写记录与标签检查。

### 第二版（动态更新）

- [x] App 助理接入 LLM Planner：优先按模型规划意图，失败回退规则解析。
- [x] App 助理实现高风险动作二次确认（`delete/replace`）：`#CONFIRM:<token>` 确认执行。
- [x] App 助理扩展元信息：`plannerSource/plannerNote/toolPlan/confirmation` 并写回 Core/Audit。
- [x] CLI 助理接入同等二次确认流：支持跨进程确认令牌持久化（`assistant_pending_confirms`）。
- [x] CLI 输出与 `--json` 补齐 v2 元信息字段。
- [x] 助理控制台补充 v2 元信息展示（规划来源、确认状态、确认令牌）。
- [ ] App + CLI 二次确认路径端到端验证并记录示例（CLI 已验证；App 待手动点击回归）。

CLI 验证记录：`assistant ask \"删除记录 <id>\" --json` 返回 `confirmation_token`，随后 `assistant confirm <token> --json` 成功执行删除并写回 Core/Audit。
