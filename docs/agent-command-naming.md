# Agent 命令命名规范

此规范约束服务端、Agent、iOS 和网页端的命令声明与调用。

| 类别 | 固定前缀 | 例子 |
| --- | --- | --- |
| 查询：提供数据 | `query.` | `query.system.metrics` |
| Codex 本机统计 | `query.` | `query.codex.usage` |
| 操作：按需执行 | `action.` | `action.network.http.check` |
| 内置聚合查询 | `query.all` | 获取全部已声明查询能力的数据 |

- 普通能力按 `前缀.领域.功能` 命名，可以增加子领域；操作末段使用动词。
- 各段以小写英文字母开头，仅使用小写英文字母、数字和下划线，段之间用点连接；完整名称最多 100 个 ASCII 字符。
- 版本放在独立的正整数 `version` 字段。清单中名称唯一，调用时名称和版本必须完全匹配。
- `query.all` v1 是协议保留命令，不能注册为普通能力。只聚合 `query.` 提供器，绝不执行 `action.`。
- 查询支持聚合和单项两种方式。`query.system.metrics` v1 单独返回系统指标；`query.all` v1 返回按能力名组织的全部查询结果。
- CPU 和内存同属系统指标，统一注册为 `query.system.metrics`，一次采样同时返回，不能因展示为两个区域而拆成两个命令。
- 操作必须单独调用，不得由进入页面、刷新数据或重连自动触发。
- 新能力按领域扩展，不在名称中加入平台名或版本号；若行为确实与平台有关，在能力说明及结果中定义。

调用示例：

```json
{"method":"query.all","version":1,"params":{}}
```

```json
{"method":"query.system.metrics","version":1,"params":{}}
```

```json
{"method":"action.network.http.check","version":1,"params":{"url":"https://example.com/"}}
```

详细消息、参数、结果及错误约定见 [设备监控协议](device-monitoring.md)。

`query.codex.usage` v1 统计本机最近 7 天的模型请求次数、token 用量及当前处理中会话数，参数 `{}`，详见 [Codex 用量采集](codex-usage.md)。
