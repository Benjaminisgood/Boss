# Boss 架构升级 TODO（Conversation + OpenClaw Runtime）

last_updated: 2026-02-26
upgrade_mode: no-backward-compat
owner: Ben

## 0. 目标（强约束）

1. Boss 内置助理改为**纯对话**（只读 RAG，不在 Boss 内执行操作）。
2. 记录/任务/技能等后端能力接口**保留**，供外部 Runtime（如 OpenClaw）调用。
3. 打通 Boss -> OpenClaw 会话转发链路（请求 + Core 上下文 + Skill/接口说明）。
4. 工作任务升级为 Boss Jobs（心跳/事件触发 -> 主动通信 OpenClaw）。
5. 自动生成人类可读文档（架构手册 + 接口目录 + Skill 快照）。

## 1. 新架构定义（v4）

### 1.1 Assistant 层
- Boss Assistant 只做：
  - 用户请求理解
  - Core 记忆检索（RAG）
  - 对话回答
  - 可选 OpenClaw 协同转发
- Boss Assistant 不做：
  - record/task/skill 的写操作执行
  - 任何删除/改写确认流

### 1.2 Runtime 层（外部）
- OpenClaw 等外部 Runtime 负责：
  - 具体动作编排与执行
  - 调用 Boss 基础接口与 Skills
  - 返回执行状态给人类或上层系统

### 1.3 Boss Jobs 层（调度）
- Boss Jobs 由任务系统维护，但只做“触发 + 转发”：
  - heartbeat(intervalMinutes)
  - cron(expression)
  - onRecordCreate / onRecordUpdate（可选 tag filter）
- Job 内容由自然语言说明驱动，可引用记录文本作为补充上下文。
- Boss 触发时主动投递 OpenClaw，执行在外部完成。

### 1.4 文档层
- 自动产出：
  - `assistant-skill-manifest.md`（技能清单）
  - `assistant-openclaw-bridge.md`（运行时手册）
- 产出位置：
  - Boss 记录（可直接在主界面浏览）
  - `data/exports/docs/` 文件导出（给外部系统/人类快速查看）

## 2. 本轮已完成

- [x] 助理模式切换为 conversation-only（不执行写操作）。
- [x] RAG 主流程保留：Core 上下文检索 + 回答。
- [x] OpenClaw 协同转发：
  - [x] 新增配置项：endpoint / token / relay 开关。
  - [x] 转发 payload：request + core_context + interfaces + skills_manifest。
- [x] 自动文档系统：
  - [x] 新增 `AssistantRuntimeDocService` 自动生成运行时手册。
  - [x] 启动时自动刷新文档。
  - [x] 技能变更后自动刷新文档。
- [x] 设置页新增 OpenClaw 配置区。
- [x] 助理 UI 文案/元信息改为对话与协同语义（移除执行确认语义）。
- [x] 工作任务重构为 Boss Jobs：
  - [x] 新增 heartbeat 触发。
  - [x] 新增 openClawJob 动作（自然语言说明 + 可选记录引用）。
  - [x] 调度器改为仅 OpenClaw 转发（本地执行动作停用）。
  - [x] 记录事件触发可携带 event record 上下文。
- [x] 初始化模板（开箱即用）：
  - [x] 首次用户自动注入示例 Skills。
  - [x] 首次用户自动注入示例 Boss Jobs（heartbeat/cron/event）。
  - [x] 自动写入快速上手记录（QuickStart）。
- [x] 文档策略调整：
  - [x] 后续运行仅维护 `data/exports/docs/` 目录同步。
  - [x] 仅在用户初始化阶段将参考文档同步进记录（AssistantDocs）。

## 3. 保留但不由内置助理直接执行的能力

- [x] 记录相关接口（search/create/append/replace/delete）代码保留。
- [x] 任务执行能力代码保留（task.run 相关基础能力）。
- [x] Skill 系统（单 md 文件 + manifest）保留。
- [x] 这些能力默认由外部 Runtime（OpenClaw）调度调用。

## 4. 当前动态验证清单

- [x] Xcode 构建通过（Debug / macOS）。
- [ ] 手工联调：OpenClaw endpoint 正常返回 2xx 时，UI 显示 relay 成功状态。
- [ ] 手工联调：endpoint 不可用时，UI 显示 relay 失败且对话仍可完成。
- [ ] 手工联调：heartbeat 任务按间隔持续触发并更新 `nextRunAt`。
- [ ] 手工联调：record create/update 触发能把 event record 上下文传给 OpenClaw。
- [ ] 手工联调：新建用户时自动写入模板 skills/tasks 与 quickstart 记录。
- [ ] 手工联调：仅初始化阶段会将目录文档回灌到记录，后续刷新不再回写记录。
- [ ] 验证 `data/exports/docs/assistant-openclaw-bridge.md` 自动更新。
- [ ] 验证技能新增/编辑后，手册与 manifest 都会刷新。

## 5. 下一步（按优先级）

1. 补 OpenClaw 响应协议解析（status/message/handoff_id 标准字段展示）。
2. 为外部 Runtime 增加单独“接口发现”输出（JSON 目录接口）。
3. 增加 Boss Jobs 运行看板（按任务聚合的最近投递状态）。
4. 增加文档版本号与变更摘要（便于人类快速 diff）。
5. 将 Assistant 旧执行内核代码分层（保留为 Runtime API 层，不参与 UI 对话流程）。

## 6. 风险与约束

- 当前为直接升级，不做向后兼容。
- 旧确认令牌流程仍在代码中保留，但不应再由 UI 会话路径触发。
- 若 OpenClaw 未配置，Boss 仍可本地完成纯对话（RAG）。
