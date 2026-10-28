# Agent 查询与操作能力方案

状态：已按此方案实现 v3；命名以 [Agent 命令命名规范](agent-command-naming.md) 为准。

Agent 能力分为查询类和操作类，以固定前缀区分。iOS 使用设备能力清单先构建详情页，再通过一次通用查询填充全部监控数据；用户需要执行操作时单独提交。第一版包含系统指标查询和 URL 连通性检测。CPU 与内存属于同一项系统指标能力。

## 命名约定

| 名称 | 类型 | 用途 |
| --- | --- | --- |
| `query.all` | 协议内置的聚合查询命令 | 一次获取当前设备全部查询类能力的数据 |
| `query.system.metrics` | 查询类能力 | 提供 CPU 使用率、物理内存、采样时间和采样窗口 |
| `action.network.http.check` | 操作类能力 | 根据用户输入的 HTTP 或 HTTPS URL，检查 Agent 到目标地址的连通性 |

查询类能力使用 `query.` 前缀，操作类能力使用 `action.` 前缀。名称使用小写英文字母、数字、下划线及点分段；普通能力名称按“前缀、领域、功能”组织，操作名称的最后一段使用动词。版本放在独立的 `version` 字段，不写入名称。

`query.all` 是内置命令，不作为独立的数据提供器或页面卡片。`query.system.metrics` 注册一份系统指标数据，内部包含 CPU 和内存；不再拆成两个能力。支持以能力名进行单项查询，例如 `query.system.metrics`；单项查询返回该能力的直接结果。iOS 详情页刷新使用 `query.all` 聚合查询。

后续可增加 `query.storage.volumes` 等数据能力，或 `action.system.restart` 等操作能力。新增能力按其声明单独实现，不在本期范围内。

## 能力清单

Agent 认证连接时上报统一的 `capabilities` 数组，前缀就是分类依据，不另设容易与名称冲突的类型字段：

```json
{
  "capabilities": [
    {"name": "query.system.metrics", "version": 1},
    {"name": "action.network.http.check", "version": 1}
  ]
}
```

服务端校验前缀、名称、正整数版本及名称唯一性，能力总数沿用最多 64 项的限制。保留名称 `query.all` 不能作为普通能力注册。清单中的能力必须有对应的 Agent 实现。

设备列表直接返回清单，iOS 从列表进入详情时复用它，不在进入页面或刷新数据前额外获取设备列表。服务端保存每台设备最近一次成功认证后上报的清单；设备离线时仍返回清单，并单独标记 `online: false`。首次连接前清单为未知状态，区别于已知的空清单。

能力发生变化时 Agent 重新连接并更新清单。一次聚合查询的 HTTP 响应同时携带执行该查询的连接所对应的清单；iOS 可据此调整发生变化的区域，无需增加一次列表查询。

## 接口与请求分发

保留通用转发入口：Console 使用 `POST /api/v1/agents/{id}/requests`，网页使用 `POST /admin/api/agents/{id}/requests`。两类调用在方法名和分发规则上区分，继续复用同一套认证、限流和 WebSocket 转发。

统一查询：

```json
{"method":"query.all","version":1,"params":{}}
```

单独执行 URL 检测：

```json
{
  "method": "action.network.http.check",
  "version": 1,
  "params": {"url": "https://example.com/"}
}
```

服务端和 Agent 使用一致的规则：

- `query.all` 只汇总已声明的 `query.` 数据提供器，不执行任何 `action.` 操作。
- `action.` 调用必须与当前连接声明的名称、版本完全匹配，一次请求只执行一项操作。
- 单项 `query.` 与 `action.` 调用都必须与当前连接声明的名称、版本完全匹配；未知方法、未知版本及非对象参数均返回明确错误。
- 服务端处理分发与转发，数据字段、参数含义和操作结果由 Agent 与对应客户端理解。

WebSocket 升级为 v3，使用 `capabilities` 替代 `methods`，请求消息增加调用版本；认证挑战的协议前缀同步升级为 `hako-agent-auth/v3`。Console 登录、会话续期和设备公钥认证机制保持原有设计。三端同步更新，不保留旧 `system.metrics` 方法及旧能力字段的兼容分支。

## 全部数据的返回结构

`query.all` 对每个已声明的查询类能力返回一项结果或一项错误。顶层 `capabilities` 由服务端从执行请求的同一连接获取；`result.data` 由 Agent 提供，按完整能力名称组织：

```json
{
  "capabilities": [
    {"name": "query.system.metrics", "version": 1},
    {"name": "action.network.http.check", "version": 1}
  ],
  "result": {
    "data": {
      "query.system.metrics": {
        "version": 1,
        "result": {
          "cpuUsagePercent": 12.3,
          "memoryUsagePercent": 50,
          "memoryUsedBytes": 8589934592,
          "memoryTotalBytes": 17179869184,
          "sampledAt": "2026-10-28T08:00:00Z",
          "sampleWindowMs": 1000
        }
      }
    }
  }
}
```

系统指标沿用当前结果字段，一轮采样同时得到 CPU 和内存。聚合查询只调用一次该提供器，不因页面上有两个展示区域而重复采样。

某项查询失败时，该项返回 `{"version":1,"error":{"code":"sample_failed","message":"系统指标采样失败。"}}`，其他能力的数据仍可正常返回。每项的 `result` 与 `error` 必须二选一，不能用零值代替失败。未返回的已声明能力在 iOS 对应区域显示“未返回数据”，而非长期保持加载状态。

操作能力及其上次执行结果不加入 `result.data`。没有查询类能力时返回空 `data`，操作入口仍可以使用。保留 JSON 原样转发与 64 KiB WebSocket 消息限制；新增数据提供器必须控制结果大小，超出预算时返回该项错误。

## URL 连通性检测

### 请求行为

命令为 `action.network.http.check` v1，参数只需要 `url`。实际访问由 Agent 发起，结果代表 Agent 运行环境的网络与代理配置下的可达性。

第一版约定如下：

- 接受最长 2048 字符的完整 HTTP 或 HTTPS URL，可包含端口、路径和查询参数；拒绝无效地址、其他协议及 URL 用户名密码。
- 允许检测局域网和本机地址，便于排查设备所在网络中的服务。
- 使用 GET，收到响应头后结束检测，不下载响应正文，不自动跟随重定向。
- 使用正常的 HTTPS 证书校验；检测不携带登录 Cookie 或系统登录凭据。
- 检测总超时为 5 秒。只在用户点击“检测”时执行；进入页面、刷新系统指标和重新连接均不会自动执行。
- URL 和检测结果只通过服务端转发，不作为服务端历史记录保存。

### 结果与判定

```json
{
  "result": {
    "url": "https://example.com/",
    "reachable": true,
    "httpSuccess": true,
    "statusCode": 200,
    "elapsedMs": 183,
    "checkedAt": "2026-10-28T08:00:00Z",
    "failure": null
  }
}
```

`reachable` 表示是否收到 HTTP 响应，`httpSuccess` 表示 HTTP 状态是否为 2xx。两者分开展示：

| 检测情况 | reachable | httpSuccess | 展示含义 |
| --- | --- | --- | --- |
| HTTP 200 | true | true | 地址可达，请求成功 |
| HTTP 301 | true | false | 地址可达，返回重定向及状态码 |
| HTTP 401 或 404 | true | false | 地址可达，返回认证要求或资源不存在 |
| HTTP 500 | true | false | 地址可达，目标服务返回错误 |
| DNS 失败、连接失败、TLS 失败、超时 | false | false | 未获得 HTTP 响应，展示失败原因 |

`elapsedMs` 包含发起请求到收到响应头或失败的总时间。未收到 HTTP 响应时 `statusCode` 为 null，`failure` 返回 `dns_failed`、`connect_failed`、`tls_failed`、`timeout` 或兜底 `request_failed`，并附可读说明。

“检测完成但目标不可达”仍是正常操作结果，即 `result.reachable: false`。参数无效或命令无法执行才使用外层 `error`。Agent 离线、连接中断或服务端转发超时沿用 HTTP 错误状态，不展示为目标 URL 不可达。

## iOS 详情页

详情页按完整能力名称和版本映射到本地组件：

| 能力 | 进入页面时建立的区域 | 数据或结果回来后 |
| --- | --- | --- |
| `query.system.metrics` v1 | 系统指标卡，包含 CPU、内存和采样时间占位 | 填充数值、进度条和采样信息 |
| `action.network.http.check` v1 | URL 输入框、“检测”按钮及结果区域 | 填充可达状态、HTTP 状态、耗时和检测时间 |

页面打开后先显示设备名称、ID 和清单决定的完整框架；有查询类能力时自动发送一次 `query.all`。右上角刷新和下拉刷新复用这个命令。数据加载时卡片保留位置，返回后只更新卡片状态与内容。

已知的其他查询能力后续注册专用组件；当前客户端不认识的查询能力先显示通用数据卡，收到数据后以只读 JSON 展示。未知操作或未知操作版本显示名称及客户端暂不支持的提示，不生成无法正确解释的输入表单。

能力清单未知时显示能力加载占位。通用查询响应携带清单，可一次补齐框架和数据；离线错误保留已经显示的框架。查询能力已知为空时，无需自动查询数据。

数据刷新与操作检测分别保存加载状态、结果及错误。检测进行中只禁用该检测按钮，系统指标仍可刷新；刷新指标不清空检测结果。数据请求失败保留卡片并显示错误，已有数据标记为上次结果，避免旧值被误认为刚刚刷新成功。

## 网页端

网页仅提供通用能力调用界面。能力选项完全来自 Agent 清单，显示名称与版本；用户输入 JSON 对象参数后发起请求，完整响应以 JSON 展示。网页不管理具体业务接口内容，不增加清单外命令，不内置系统指标卡片、URL 参数模板或结果字段校验。状态刷新不触发能力调用。

## 并发与超时

沿用服务端每设备最多 4 个待处理请求、全局最多 32 个请求的限制。Agent 接收循环持续处理心跳和新请求，将能力执行交给有并发上限的任务；WebSocket 写入继续串行，避免 URL 检测阻塞系统指标查询。

服务端转发预算保持 10 秒，Agent 聚合采集预算为 8 秒，URL 检测预算为 5 秒，客户端网络超时高于服务端预算。断开连接时取消该连接下的执行任务。操作请求不自动重试；服务端转发超时不等于 Agent 从未发起目标访问。

## 实现顺序

1. 明确 v3 消息、前缀、版本匹配、聚合返回及错误结构，更新协议测试。
2. Windows Agent 拆分查询提供器和操作处理器，注册 `query.system.metrics`、实现 `query.all`，再加入 HTTP 检测及受控并发。
3. Go 服务端校验与保存能力清单，更新分发规则、同连接清单回传及网页管理端。
4. iOS 以能力构建详情页，接入统一数据查询，再加入 URL 输入与独立检测状态。
5. 完成跨端验证后同步发布 Windows、服务端和 iOS。

主要修改位置为 Windows 的 `Core/AgentDispatcher.cs`、`Core/AgentConnection.cs`，服务端的 `internal/server/agents.go` 及能力持久化模型，iOS 的 `ConsoleClient.swift`、`DeviceMonitorView.swift`。HTTP 检测实现放入独立模块，避免与系统指标采样混合。

## 验收条件

- 名称前缀、保留名称、版本、重复能力及错误格式有明确校验；查询入口无法触发操作。
- 系统指标只注册一项能力，一次刷新只发一条 `query.all`，CPU 和内存共享一轮采样。
- 页面在延迟数据返回前已按清单显示框架，成功、单项失败、缺失结果及未知能力均能结束加载。
- 进入页面、下拉刷新和点击数据刷新不会发起 URL 检测；点击一次检测只调用一次操作。
- URL 检测覆盖 2xx、3xx、4xx、5xx、DNS、连接、TLS 和超时；重定向不被自动跟随，大响应正文不被下载。
- 查询和操作可以同时进行，错误与加载状态互不覆盖；断线和重连后的能力更新可正确处理。
- Windows 执行构建、检查程序和真实 Agent 联调；Go 执行测试和 vet；网页执行脚本检查。iOS 由 macOS CI 编译并在 iPhone 验证框架渲染和交互。

现行协议与实现背景见 [设备监控协议](device-monitoring.md)。
