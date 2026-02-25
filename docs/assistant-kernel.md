# Boss 助理使用说明与底层逻辑

## 1. 功能概览

Boss 内置了一个“轻量助理内核”（Assistant Kernel），目标是把自然语言请求转成可执行的内部工具调用，并自动完成上下文读取、风险控制、记忆沉淀与审计记录。

当前能力包括：
- 自然语言解析与规划（优先 LLM，失败回退规则解析）
- Core 记忆上下文装配（按相关性排序）
- 工具调用执行（检索、追加、改写、删除、运行 Agent、总结）
- Skill 技能包体系（独立存储、可执行、可供 LLM 规划）
- 高风险动作二次确认（带 dry-run 影响范围预览）
- Core/Audit 自动写回（可追踪）
- Core 冲突检测与合并策略（`#MERGE:overwrite|keep|versioned`）

---

## 2. 使用入口

### 2.1 App 内使用

入口在 Agent 窗口：
- 打开 Agent 管理界面
- 点击脑图标按钮（"打开项目助理"）
- 在 Assistant Console 输入自然语言请求并执行

界面会展示：
- 回复正文
- intent / planner / tool plan
- confirmation token（如有）
- core memory 记录 ID、audit log 记录 ID

高风险请求（例如删除、改写、agent.run）会先返回确认令牌；需再次提交：
- `#CONFIRM:<token>`

### 2.2 CLI 使用

命令：

```bash
boss assistant ask <request> [--source <source>] [--json]
boss assistant confirm <token> [--source <source>] [--json]
```

示例：

```bash
boss assistant ask "搜索 Swift 并发"
boss assistant ask "把 <record-id> 改写为：新内容" --json
boss assistant confirm <token> --json
```

你也可以直接把确认令牌作为请求：

```bash
boss assistant ask "#CONFIRM:<token>" --source runtime --json
```

---

## 3. 配置与依赖

### 3.1 存储路径

CLI 存储路径优先级：
1. `--storage` / `-s`
2. 环境变量 `BOSS_STORAGE_PATH`
3. `UserDefaults(suiteName: "com.boss.app")` 的 `storagePath`
4. 默认 `~/Library/Application Support/Boss`

### 3.2 LLM 模型与 API Key

App 内在“设置 -> Agent”可配置：
- 模型（`provider:model`，如 `openai:gpt-4.1`、`aliyun:qwen-max`）
- Claude/OpenAI/阿里云 API Key

CLI 的 API Key 读取优先级：
- Claude: `BOSS_CLAUDE_API_KEY` -> `CLAUDE_API_KEY` -> app defaults `claudeAPIKey`
- OpenAI: `BOSS_OPENAI_API_KEY` -> `OPENAI_API_KEY` -> app defaults `openAIAPIKey`
- 阿里云: `BOSS_ALIYUN_API_KEY` -> `DASHSCOPE_API_KEY` -> app defaults `aliyunAPIKey`

支持 provider：
- `claude`
- `openai`
- `aliyun`

---

## 4. 工具清单（类 MCP 风格）

助理规划阶段只产生工具调用（tool calls），然后由执行器分发执行。

| 工具名 | 必需参数 | 风险级别 | 说明 |
|---|---|---|---|
| `assistant.help` | 无 | low | 返回能力说明 |
| `core.summarize` | 无 | low | 总结 Core 记忆 |
| `skills.catalog` | 无 | low | 读取 Skill 清单与基础接口文档 |
| `record.search` | `query` | low | 检索记录 |
| `record.create` | `content`（可选 `filename`） | low | 创建文本记录（支持日期命名） |
| `agent.run` | `agent_ref` | high | 运行 Agent 任务（按 ID/名称解析） |
| `skill.run` | `skill_ref`（可选 `input`） | medium | 运行已注册 Skill（按 ID/名称解析） |
| `record.delete` | `record_id` | high | 删除记录 |
| `record.append` | `record_id`,`content` | medium | 追加文本 |
| `record.replace` | `record_id`,`content` | high | 覆写文本 |

说明：
- `high` 风险工具会触发二次确认。
- `agent.run` 当前按高风险处理。
- `skill.run` 的行为由 Skill 配置定义（LLM / Shell / Record 操作）。

### 4.1 Skill 存储与 Manifest

- Skill 本体存储在 SQLite 表：`assistant_skills`
- 系统会自动维护一份聚合文档记录：`assistant-skill-manifest.md`
- 该记录会打 `SkillPack` 标签，供助理规划和外部阅读接口复用

---

## 5. 请求生命周期（底层执行链路）

一次请求的主流程：
1. 清洗请求文本，生成 `request_id`。
2. 确保系统标签存在：`Core`、`AuditLog`。
3. 加载 Core 上下文：按请求 token 与记录内容相关性打分排序。
4. 检测是否是确认请求（`#CONFIRM:<token>`）：
   - 命中有效 token：直接复用待确认工具调用执行
   - 无效/过期/来源不匹配：返回确认失败
5. 规划工具调用：
   - 优先 LLM Planner 输出 JSON（`calls[]`）
   - 兼容旧协议（`intent/query/record_id/content`）
   - 失败回退规则解析器
   - 对“日期语义写操作”（例如“向明天日志追加”）允许规则覆盖，避免被错误降级为纯检索
6. 参数守卫（最小澄清）：
   - 若缺少关键参数（如 `record_id/content/agent_ref`），优先返回单条精准问题
   - 即使 LLM 生成了写操作，如果原请求关键信息缺失，也会强制回退澄清
7. 风险闸门：
   - 高风险先生成 dry-run 影响范围预览
   - 返回确认 token（TTL 5 分钟）
8. 工具执行：串行执行 tool calls，聚合回复、动作轨迹、关联记录 ID。
9. 写回：
   - Core Memory Snapshot（结构化文本）
   - Assistant Audit Log（全链路审计）
10. 返回结果：reply + 元信息字段。

---

## 6. 规划协议（LLM Planner）

Planner 需要输出 JSON，字段：
- `calls`: `[{"name": string, "arguments": object}]`
- `clarify_question`: string（无法执行时给出澄清问题）
- `tool_plan`: string[]（简短步骤）
- `note`: string

关键约束：
- 只允许使用注册工具名。
- 无法执行时应返回 `clarify_question` 且 `calls` 为空。
- 系统会对参数进行二次 materialize 与补全（例如从请求中抽取 `record_id`、`content`、`agent_ref`）。
- 对 LLM 返回的占位符参数（如 `<RESULT_OF_SEARCH>`）会尝试回填真实引用并在执行前再次校验。

---

## 7. 最小澄清策略

当检测到关键信息缺失时，仅提一条高价值问题，避免追问风暴。

典型场景：
- 删除但无 `record_id` -> 请提供目标记录 ID
- 追加缺 `record_id` 或 `content` -> 精准提示补齐缺失项
- 改写缺 `record_id` 或 `content` -> 精准提示补齐缺失项
- 新建缺 `content` -> 仅追问“要写入什么内容”
- `agent.run` 缺 `agent_ref` -> 提供任务 ID 或任务名

补强策略：
- 若请求本身关键信息缺失，但 LLM 生成了写操作调用，系统会优先澄清，不执行。

### 7.1 日期语义（today/tomorrow）

- `record_id` 不再只接受 UUID，也支持日期引用：
  - `TODAY` / `今天`
  - `TOMORROW` / `明天`
  - `DAY_AFTER_TOMORROW` / `后天`
  - 明确日期（如 `2026-02-26`）
- `record.append` 在日期引用找不到目标记录时，可自动创建当日/次日文本记录并继续追加。

---

## 8. 高风险确认与 Dry-run

### 8.1 触发条件

任一 tool call 风险级别为 `high` 即触发确认。

### 8.2 确认信息

返回内容包含：
- Dry-run 预览（影响范围）
- 确认 token
- 过期时间（默认 5 分钟）

### 8.3 确认执行

方式一：
- 在请求中发送 `#CONFIRM:<token>`

方式二（CLI）：
- `boss assistant confirm <token> [--source <source>] [--json]`

### 8.4 存储差异

- App：待确认请求保存在进程内 `ConfirmationStore`（actor + 内存字典）
- CLI：待确认请求持久化到 SQLite 表 `assistant_pending_confirms`（支持跨进程确认）

两者都校验：
- token 是否存在且未过期
- `source` 是否匹配（若设置）

---

## 9. Core 记忆与 Audit 审计

每次请求都会尝试写两类结构化文本记录：
- Core Memory Snapshot（标签：`Core`）
- Assistant Audit Log（标签：`AuditLog`）

写回内容包含：
- request/source/intent/planner/tool plan
- confirmation 状态
- action trace
- related records
- core context records
- 冲突检测与合并策略元数据

### 9.1 冲突检测与合并

检测逻辑：
- 对比“新请求 + 新回复”与既有 Core 记录的语义相似度
- 命中冲突后默认策略：`versioned`

可显式指定：
- `#MERGE:overwrite`（覆盖旧 Core）
- `#MERGE:keep`（保留旧 Core，不新建）
- `#MERGE:versioned`（新增版本，默认）

---

## 10. `agent.run` 解析与执行

`agent.run` 的 `agent_ref` 支持：
- 任务 ID 精确匹配
- 任务名精确匹配
- 任务名包含匹配

执行器行为：
- 解析任务后调用调度器运行
- 成功返回任务输出摘要
- 失败返回错误信息

Dry-run 阶段会提前提示：
- 将运行哪个任务
- 或任务不存在

---

## 11. 返回字段说明（CLI `--json` / App 元信息）

关键字段：
- `request_id`: 本次请求唯一 ID
- `intent`: 解析后动作描述
- `planner_source`: 规划来源（`llm:*` / `rule` / `confirmation-token`）
- `planner_note`: 规划备注/回退原因
- `tool_plan`: 步骤计划
- `confirmation_required`: 是否需确认
- `confirmation_token` / `confirmation_expires_at`: 确认信息
- `reply`: 回复正文
- `actions`: 动作轨迹（可用于排障）
- `related_record_ids`: 关联记录
- `core_context_record_ids`: 参与上下文的 Core 记录
- `core_memory_record_id`: 本次写回的 Core 记录 ID
- `audit_record_id`: 本次审计记录 ID
- `succeeded`: 请求处理结果

常见 action 示例：
- `plan:llm:aliyun:qwen-max`
- `clarify.ask`
- `confirm.required:<token>`
- `dryrun.preview:1`
- `tool.execute:record.replace`
- `memory.write:<record-id>`
- `audit.write:<record-id>`

---

## 12. 故障排查

### 12.1 提示缺 API Key

症状：
- `Missing Claude/OpenAI/阿里云 API key`

处理：
- App 设置里补充 API Key
- 或设置 CLI 环境变量（见上文优先级）

### 12.2 确认令牌失效

症状：
- 提示“确认令牌无效、来源不匹配或已过期”

处理：
- 重新发起原高风险请求，拿新 token
- 确认 `--source` 与初次请求一致

### 12.3 追加/改写失败

常见原因：
- 记录不存在
- 目标记录不是文本类型

处理：
- 先 `record.search` 或通过界面确认记录 ID 和类型

### 12.4 `agent.run` 未找到任务

处理：
- 先 `boss agent list` 获取真实任务 ID/名称
- 优先用 ID 调用

---

## 13. 扩展开发建议（保持 App/CLI 一致）

若你要新增工具（例如 `record.bulk_edit`）：
1. 在 App/CLI 的 tool spec 都注册（名称、必填参数、风险级别）。
2. 在 LLM materialize/legacy intent 兼容层补参数映射。
3. 在 `intent(from call:)` 与执行器里落地真实行为。
4. 加入 dry-run 预览（若中高风险）。
5. 补充最小澄清规则（关键参数缺失时）。
6. 确认 Core/Audit 字段可追踪。
7. 同步更新 CLI `--json` 文档字段说明。

这样可以保证“助理调度能力、风控、审计”在 App 与 CLI 路径完全对齐。
