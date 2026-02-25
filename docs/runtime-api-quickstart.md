# Boss 助理外部 Runtime 对接（精简版）

## 1. 目标

本文面向外部 Runtime（如 OpenClaw 类调度层），给出最小可用接入协议。
推荐先走 CLI 方式对接，稳定后再做更深集成。

---

## 2. 最小调用面

## 2.1 发起请求

```bash
boss assistant ask "<自然语言请求>" [--source <source>] [--json]
```

建议固定：
- `--source runtime`
- `--json`（便于程序解析）

## 2.2 确认高风险动作

```bash
boss assistant confirm <token> [--source <source>] [--json]
```

等价写法：

```bash
boss assistant ask "#CONFIRM:<token>" [--source <source>] [--json]
```

---

## 3. 响应字段（接入方必读）

关键字段：
- `succeeded`: 本次请求处理是否成功
- `reply`: 助理返回文本
- `intent`: 最终执行意图（可用于观测）
- `planner_source`: `llm:*` / `rule` / `confirmation-token`
- `planner_note`: 规划说明（含回退/覆盖原因）
- `tool_plan`: 最终工具计划
- `confirmation_required`: 是否需要二次确认
- `confirmation_token`: 确认令牌（若需要）
- `confirmation_expires_at`: 过期时间（Unix 时间戳）
- `actions`: 动作轨迹（排障关键）
- `related_record_ids`: 受影响记录 ID

推荐接入逻辑：
1. 先判断 `confirmation_required`。
2. 若为 `true`，将 `reply + token + expires_at` 返回给上层审批。
3. 审批通过后再调用 `assistant confirm`。

---

## 4. 日期语义（today/tomorrow）

助理现在支持“日期引用”作为记录目标，不再只接受 UUID：
- `TODAY` / `今天`
- `TOMORROW` / `明天`
- `DAY_AFTER_TOMORROW` / `后天`
- 明确日期（如 `2026-02-26`）

行为约定：
- `record.append` 遇到日期引用且目标不存在时，可自动创建对应日期文本记录并继续追加。
- `record.create` 可直接新建“明天计划”等文本记录。
- 相对日期按运行环境本地时区解析。

### 4.1 为什么“今天/明天”有时会失效

常见根因通常是两类（可能同时存在）：
- 接口能力缺口：未提供 `record.create`，导致“明天计划”只能检索无法落盘。
- 规划层退化：LLM 先做 `record.search`，再给出占位符 `record_id`（如 `<RESULT_OF_SEARCH>`），未被二次纠偏。

当前内核优化后：
- 规划阶段会对日期写请求做规则纠偏，避免被降级为纯检索。
- 参数 materialize 会把占位符 `record_id` 回填为请求中的真实引用（如 `TODAY/明天/UUID`）。
- 执行阶段再做一次兜底校验，缺引用时返回明确错误而不是“找不到 `<RESULT_OF_SEARCH>`”。

---

## 5. 推荐请求模板

## 5.1 新建（日期驱动）

```text
为明天新建计划：完成周报并同步需求
```

## 5.2 追加到今天

```text
向 TODAY 追加：晚上复盘发布流程
```

## 5.3 高风险改写（需确认）

```text
把 <record-id> 改写为：<新内容>
```

---

## 6. 高风险确认流（时序）

1. Runtime 调 `assistant ask`。
2. 若响应 `confirmation_required=true`：
   - 暂停自动执行
   - 记录 `confirmation_token` 和 `expires_at`
   - 请求人工/策略确认
3. 确认后调用 `assistant confirm <token>`。
4. 读取最终响应并落库。

注意：
- `source` 必须与首次请求一致，否则确认会失效。
- token 过期后需重新发起原请求。

---

## 7. 接入伪代码

```text
resp = ask(request, source="runtime", json=true)
if resp.confirmation_required:
    decision = approve(resp)
    if decision:
        resp = confirm(resp.confirmation_token, source="runtime", json=true)
return resp
```

---

## 8. 错误处理建议

常见失败类型：
- 缺 API Key（LLM 不可用）
- 确认 token 无效/过期/来源不匹配
- 目标记录不存在或非文本类型（追加/改写）

建议：
- 对 `confirmation_required=true` 与 `succeeded=false` 分开处理。
- 保存 `actions` 作为诊断日志。
- 若 `planner_source=rule` 且 `planner_note` 提示 LLM 失败，可降级继续执行（系统已内置规则回退）。

---

## 9. 版本兼容建议

对接方应只依赖稳定字段：
- 必依赖：`reply`, `succeeded`, `confirmation_required`, `confirmation_token`, `actions`
- 软依赖：`intent`, `planner_note`, `tool_plan`

这样可兼容后续工具扩展（例如新增更多 `record.*` 能力）。
