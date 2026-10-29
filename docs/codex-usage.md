# 本机 Codex 用量采集

Windows Agent 提供 `query.codex.usage` v1，参数固定为 `{}`，也加入 `query.all`。统计当前 Windows 用户在这台电脑上的 Codex 本地记录，不代表整个账号、其他电脑或云端任务的用量，也不是计费金额或套餐余额。

## 请求与 token 口径

- 调用数是**用户发送任务/消息的次数**，每次发送计 1 次，一次发送附带多张图片仍只计 1 次；同一轮处理中追加的新消息分别计数。内部多轮模型请求和工具调用不会增加调用数，未产生 token 的用户发送仍会计数。
- 优先读取主会话中用户消息的稳定 ID 和 `content_item_kinds` 元数据，仅统计 `user.*` 内容类别，排除自动附加的 AGENTS.md、环境、页面上下文及内部 subagent/guardian 消息。使用消息创建时间按设备时区归属日期，fork/归档中同一 ID 只计一次。
- 优先读取 JSONL 中 `token_usage_record.payload.usage`，按 `response_id` 去重；同一响应的后续用量更新覆盖较早记录，不增加请求数。不会把 `thread_token_usage` 或 `turn_token_usage` 累计值当成单次用量相加。
- `event_msg/token_count` 是兼容事件，可能与精确记录同时存在，并非额外消耗。两类累计状态分开处理；同一轮次、全部 Token 数字相同的事件与精确响应一一配对，配对后只计精确响应，最近时间的事件优先配对。每份精确响应的同一个用量版本最多匹配一条候选，避免两个真实请求恰好用量相同时被一起删掉。精确响应后续更正用量时也保留早期数字用于配对，不重复累计早期版本。没有配对的兼容事件才按估算补计。
- 会话恢复或切换轮次后重复出现、累计值未变化的兼容快照不计为新用量，即使其 `last_token_usage` 仍有总量或只包含零值细分字段。不能用精确记录的累计值覆盖兼容快照的上次状态，否则会把重复快照误判为新增。
- 包括本机日志中记录的后台/子任务模型请求。fork 中继承的记录及移到归档目录的记录不会重复计算。
- 旧版没有用户消息标记时，调用数回退到主会话的用户任务开始事件，按轮次 ID 去重并标明**估算**。旧版 token 则使用 `event_msg/token_count` 中变化的 `last_token_usage`；不会把这些 token 更新事件算作用户调用。
- 总 token 优先使用记录中的 `total_tokens`。输入包含缓存输入，输出包含推理输出，不能再把缓存和推理各加一次。只有总量、没有有效细分的旧记录仍计入总量，所在日期的 `breakdownAvailable` 为 false，手机隐藏该日无可靠依据的输入/输出明细。
- 按 **Agent 所在设备的本地时区**分组，显示今天及之前 6 个自然日。旧会话今天继续使用的请求归今天，不归会话创建日；没有请求的日期补零。
- `requestCountKind: "user_messages"` 明确标识用户调用口径。旧 Agent 没有这个标记时，手机不把旧的模型调用数展示为用户调用数，并提示更新 Agent。旧缓存迁移保留 token 历史，重新读取仍存在的日志以重建用户调用数。

## 当前处理中会话

只读查询 Codex `state_*.sqlite` 与 `thread_history_*.sqlite`，统计有 `inProgress` 且未完成轮次的会话，并检查对应 `thread-writer-locks` 的活跃文件锁；没有活跃 writer 的残留记录不计入。按会话去重，排除内部 subagent/guardian 会话。

这是未结束轮次的数量，包括等待输入或批准的轮次，并非正在进行网络请求的连接数。数据库或版本结构不支持读取时，`runningSessions` 为 null，显示“暂不可用”，不冒充 0。文件锁只用于探测，不修改 Codex 数据库或锁文件。

`runningSessionDetails` 与数量使用同一次检测结果，逐项返回 `title` 和 `projectName`。标题取会话显示名称 `name`，不使用可能包含整段首条请求的旧 `title` 字段；缺失时显示“未命名会话”。项目名取该会话工作目录的末级目录名（工作树可能显示工作树目录名），缺失时显示“未关联项目”，不假定等同于 Codex 自定义项目名称。排除内部会话时同时检查 `source` 和 `thread_source`。不返回内部会话 ID、完整工作目录或对话正文。

## 本地记录与刷新

- 默认读取 `%USERPROFILE%/.codex`，遵循进程的 `CODEX_HOME` 环境变量；扫描 `sessions` 和 `archived_sessions`。运行状态从版本号最高的本地元数据库读取。
- Agent 后台实例运行时每 60 秒采集一次；新查询最多复用 30 秒内的用量快照，处理中会话数及项目、标题每次查询时读取。首次导入较多历史日志可能需要数秒；查询超时可在后台导入完成后刷新。
- 采集文件为当前 Agent 配置目录中的 `codex-usage.json`，默认 `%LOCALAPPDATA%/Hako/codex-usage.json`；独立 `--data-dir` 使用自己的缓存。
- 缓存只保存 7 天内的消息/轮次/模型请求 ID、时间、token 数字和增量读取位置，不保存提示词、回答、工具结果、标题、账号或凭据。恢复时复用增量位置，避免重扫完整日志；未写完的最后一行下次重读。
- 第 5 版缓存保留两类用量候选与精确响应的更正版本，汇总时先配对再求和，不能直接把缓存 `Requests` 中的候选全部相加。升级第 3/4 版缓存时保留已采集历史，重新读取还存在的日志，补齐轮次归属并校正重复快照。已删除的源日志无法重新核对，保留相应历史并提示此限制。
- 日志被删除后，已采集的 7 天内统计仍保留；未采集就被删除的数据无法补回。损坏、不可读、旧版估算或缓存保存失败会返回明确提示。
- Agent 退出时停止采集；重新启动会从还存在的本地日志补齐。服务端只转发汇总结果，不保存原始日志或历史用量。

## 返回结果

```json
{
  "available": true,
  "collectedAt": "2026-10-28T20:00:00+08:00",
  "timeZone": "China Standard Time",
  "requestCountKind": "user_messages",
  "days": [
    {
      "date": "2026-10-28",
      "requestCount": 12,
      "inputTokens": 100000,
      "cachedInputTokens": 80000,
      "outputTokens": 3000,
      "reasoningOutputTokens": 1000,
      "totalTokens": 103000,
      "breakdownAvailable": true
    }
  ],
  "runningSessions": 1,
  "runningSessionDetails": [{ "title": "调整用量图表", "projectName": "hako" }],
  "warnings": []
}
```

示例省略了前 6 天，实际 `days` 固定为 7 项，按日期升序排列。`available` 表示当前能找到会话日志目录；false 时仍可返回此前缓存的近 7 天统计，并附提示。请求 ID、会话 ID、完整源路径和对话正文均不出现在结果中。运行状态不可用时，数量和列表均为 null；无处理中会话时，数量为 0、列表为空。旧 Agent 可能不返回列表，手机保留数量并提示更新。

iOS 设备详情底部固定提供“查询 / 操作”页签，各能力以独立卡片同页展示，同时最多展开一张，切换页签时收起已展开内容。Codex 卡片收起时显示处理中会话数及数据可用状态，展开后默认展示处理中会话，以数量徽标分组，每个会话以独立卡片分层显示项目名和标题。卡片内可切换“最近 7 天”，并按调用数 / Token 切换单轴柱状图，纵轴为所选指标的实际用量，调用数为蓝色、Token 为橙色。旧 Agent 未声明用户调用口径时展示 Token 并提示更新，不将旧模型请求次数显示为调用数。点击日期突出当天柱子，并在图下展示完整调用数及 Token 数字；默认显示最近一天，不显示每日详情表格。零值日期可点对应绘图区查看读数。历史用量警告、时区、采集时间和统计口径收纳在默认折叠的“数据说明”中，入口显示提示条数。卡片长按排序与展开定位见 [设备监控协议](device-monitoring.md)。网页沿用通用能力调用：选择 `query.codex.usage · v1`，参数 `{}`，结果以 JSON 展示；无需为此能力修改服务端转发逻辑。需要更新 Windows Agent 和 iOS。

后续可用 `UserPromptSubmit`、`Stop`、`Interrupt` Hook 直接采集新事件，历史和 token 仍需用量日志补齐；Hook 也需要去重、区分自动续跑并处理异常退出时遗漏的结束回调。当前实现没有安装或启用全局 Hook，不能把历史数据声称为 Hook 采集结果。官方事件说明见 [Codex Hooks](https://learn.chatgpt.com/docs/hooks)。

Hook 由 Codex 调用，Hako 是否启动不影响独立 Hook 脚本执行；若脚本只向 Hako 进程发送事件，接收方未启动时会漏记。未来若采用 Hook，需先持久化到本地队列、由 Agent 补读，不能只依赖实时通知。现阶段保留日志与元数据库采集：Agent 重新启动可从仍保留的记录补齐历史统计，并重新查询当时的会话状态。

官方 `UserPromptSubmit` 和 `Stop` 的事件字段不包含 Token 用量。Hook 可记录发送/生命周期事件，但 Token 仍需读取用量记录或事件源；从 Hook 脚本读取日志并不等于仅靠 Hook 获取 Token。官方也说明 transcript 格式不是稳定接口，本文的“精确记录 / 兼容事件”是采集适配分类，不代表官方承诺的替代或弃用关系，也不能保证精确记录覆盖所有历史。

本地事件与数据库适配以实际安装版本为准；官方 App Server 的用量和运行状态事件说明见 [Codex App Server](https://learn.chatgpt.com/docs/app-server)。当前采集不启动另一个 app-server，也不使用认证令牌或账号用量接口。
