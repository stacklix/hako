# 本机 Codex 用量采集

Windows Agent 提供 `query.codex.usage` v1，参数固定为 `{}`，也加入 `query.all`。统计当前 Windows 用户在这台电脑上的 Codex 本地记录，不代表整个账号、其他电脑或云端任务的用量，也不是计费金额或套餐余额。

## 请求与 token 口径

- 请求数是**有用量记录的模型请求次数**，一次用户任务可产生多次模型请求；工具调用不算模型请求。没有产出用量记录的失败请求无法计入。
- 优先读取 JSONL 中 `token_usage_record.payload.usage`，按 `response_id` 去重；同一响应的后续用量更新覆盖较早记录，不增加请求数。不会把 `thread_token_usage` 或 `turn_token_usage` 累计值当成单次用量相加。
- 包括本机日志中记录的后台/子任务模型请求。fork 中继承的记录及移到归档目录的记录不会重复计算。
- 旧版只有 `event_msg/token_count` 时，按变化的累计用量识别更新，使用 `last_token_usage` 并按轮次和累计值去重；这类请求次数标明为**估算**，不承诺能恢复缺失的请求。
- 总 token 优先使用记录中的 `total_tokens`。输入包含缓存输入，输出包含推理输出，不能再把缓存和推理各加一次。只有总量、没有有效细分的旧记录仍计入总量，所在日期的 `breakdownAvailable` 为 false，手机隐藏该日无可靠依据的输入/输出明细。
- 按 **Agent 所在设备的本地时区**分组，显示今天及之前 6 个自然日。旧会话今天继续使用的请求归今天，不归会话创建日；没有请求的日期补零。

## 当前处理中会话

只读查询 Codex `state_*.sqlite` 与 `thread_history_*.sqlite`，统计有 `inProgress` 且未完成轮次的会话，并检查对应 `thread-writer-locks` 的活跃文件锁；没有活跃 writer 的残留记录不计入。按会话去重，排除内部 subagent/guardian 会话。

这是未结束轮次的数量，包括等待输入或批准的轮次，并非正在进行网络请求的连接数。数据库或版本结构不支持读取时，`runningSessions` 为 null，显示“暂不可用”，不冒充 0。文件锁只用于探测，不修改 Codex 数据库或锁文件。

## 本地记录与刷新

- 默认读取 `%USERPROFILE%/.codex`，遵循进程的 `CODEX_HOME` 环境变量；扫描 `sessions` 和 `archived_sessions`。运行状态从版本号最高的本地元数据库读取。
- Agent 后台实例运行时每 60 秒采集一次；新查询最多复用 30 秒内的用量快照，处理中会话数每次查询时读取。首次导入较多历史日志可能需要数秒；查询超时可在后台导入完成后刷新。
- 采集文件为当前 Agent 配置目录中的 `codex-usage.json`，默认 `%LOCALAPPDATA%/Hako/codex-usage.json`；独立 `--data-dir` 使用自己的缓存。
- 缓存只保存 7 天内的请求 ID、时间、token 数字和增量读取位置，不保存提示词、回答、工具结果、标题、账号或凭据。恢复时复用增量位置，避免重扫完整日志；未写完的最后一行下次重读。
- 日志被删除后，已采集的 7 天内统计仍保留；未采集就被删除的数据无法补回。损坏、不可读、旧版估算或缓存保存失败会返回明确提示。
- Agent 退出时停止采集；重新启动会从还存在的本地日志补齐。服务端只转发汇总结果，不保存原始日志或历史用量。

## 返回结果

```json
{
  "available": true,
  "collectedAt": "2026-10-28T20:00:00+08:00",
  "timeZone": "China Standard Time",
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
  "warnings": []
}
```

示例省略了前 6 天，实际 `days` 固定为 7 项，按日期升序排列。`available` 表示当前能找到会话日志目录；false 时仍可返回此前缓存的近 7 天统计，并附提示。请求 ID、会话 ID、源路径和对话正文均不出现在结果中。

iOS 设备详情按能力清单显示“Codex · 最近 7 天”，包含每日请求数、每日总 token、今日输入/输出细分、处理中会话数、时区与采集时间。网页沿用通用能力调用：选择 `query.codex.usage · v1`，参数 `{}`，结果以 JSON 展示；无需为此能力修改服务端转发逻辑。需要更新 Windows Agent 和 iOS。

本地事件与数据库适配以实际安装版本为准；官方 App Server 的用量和运行状态事件说明见 [Codex App Server](https://learn.chatgpt.com/docs/app-server)。当前采集不启动另一个 app-server，也不使用认证令牌或账号用量接口。
