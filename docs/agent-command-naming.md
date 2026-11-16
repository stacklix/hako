# Agent 命令命名规范

此规范约束 Agent 与调用端的命令声明与调用。服务端只负责鉴权、设备路由和透传，不校验命令命名、版本、参数、结果或能力清单，也不按清单拦截调用。

| 类别 | 固定前缀 | 例子 |
| --- | --- | --- |
| 查询：提供数据 | `query.` | `query.system.metrics` |
| Codex 本机统计 | `query.` | `query.codex.usage` |
| 本机监听端口 | `query.` | `query.network.listeners` |
| 操作：按需执行 | `action.` | `action.network.http.check` |
| 守护管理：在守护进程执行 | `admin.` | `admin.services.status`、`admin.services.start` |
| 内置聚合查询 | `query.all` | 获取支持聚合的查询数据 |

- 普通能力按 `前缀.领域.功能` 命名，可以增加子领域；操作末段使用动词。
- 各段以小写英文字母开头，仅使用小写英文字母、数字和下划线，段之间用点连接；完整名称最多 100 个 ASCII 字符。
- 版本放在独立的正整数 `version` 字段。清单中名称唯一，调用时名称和版本必须完全匹配。
- `query.all` v1 由主进程实现，不能注册为普通能力。只聚合常规 `query.` 提供器，不包含 `action.` 或 `admin.`。服务端对它没有特殊处理。
- 守护进程维护到服务端的连接，直接处理 `admin.`，通过当前用户专用本机管道转发 `query.` 和 `action.` 给主进程。主进程退出时，连接和管理能力仍可用；普通命令返回主进程不可用，恢复后重新转发，不自动重放操作。
- `query.system.metrics` v1 等常规查询支持单项和聚合两种方式。`query.all` v1 按能力名组织聚合结果。Git 仓库扫描、详情和操作状态仅按需查询，仍在能力清单中声明。
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

`query.codex.usage` v1 统计本机最近 7 天的用户发送调用数、token 用量及当前处理中会话数、项目名与显示标题，参数 `{}`，详见 [Codex 用量采集](codex-usage.md)。
