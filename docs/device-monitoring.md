# 设备监控协议 v3

单用户、多设备。Agent 是跨平台的设备代理角色，仓库当前提供 Windows 实现；iOS 为 Console，服务端为 Hako 统一后端，设备管理是其中的业务模块。三端各自实现协议，不共享代码包。

本版统一使用通用设备请求，移除旧的 `/metrics/query` 接口和 Agent v1/v2 消息协议，不提供兼容层。部署时同步更新服务端、Windows Agent 和 iOS Console；应用级认证与扫码登录见 [Hako 服务器认证协议](server-authentication.md)，扫码接口与二维码协议已统一调整。

## 应用级身份与认证

配置、公钥登记、DPoP 登录、会话管理和 Web 扫码批准统一见 [Hako 服务器认证协议](server-authentication.md)。所有外部通信使用 HTTPS/WSS，设备接口复用主应用 Console 会话和设备签名。

## Console 设备接口

| 接口 | 用途 |
| --- | --- |
| `GET /api/v1/agents` | 返回 `agents` 数组：`id,name,online,lastSeen,capabilities` |
| `POST /api/v1/agents` | 登记 Agent，正文 `name,publicKeyPem`，ID 自动生成；需 Console DPoP 会话认证，成功返回 201 和 `id,keyId` |
| `POST /api/v1/agents/{id}/requests` | 转发通用动作请求，默认最多等待 10 秒 |

iOS「设备监控 → 添加 Agent」和网页登记入口只填写名称及公钥，支持粘贴或导入 Agent 导出的 RSA 公钥；添加成功立即生效并刷新设备列表，无需重启服务端。两者共用校验、持久化及并发锁。未提供或提供空 `id` 时，服务端使用密码学随机数生成 5 位唯一 ID，只含大写字母和数字，以字母开头（如 `A7K2Q`），发生重号时重新生成，并与公钥一同持久化，重启后保留；客户端使用响应中的 `id` 定位设备。接口仍接受可选的显式 `id`，格式为 `[A-Z][A-Z0-9]{0,4}`，即 1–5 位大写字母或数字且以字母开头。登记和去重在同一把锁内完成，避免并发重号。名称非空且最多 100 个 UTF-8 字节，接受单个 SPKI 或 PKCS#1 PEM RSA 2048–8192 位公钥，不接受私钥或文件路径。请求上限 16 KiB。重复公钥或显式 ID 返回 409 `duplicate_agent`，非法设备或公钥返回 400 `invalid_public_key_or_device`，存储失败返回 503 `storage_unavailable`，无法分配 ID 时返回 503 `device_id_unavailable`。iOS 在发送前拒绝私钥并校验输入；登记成功但列表刷新失败时使用响应 ID 保留新增设备并提示刷新，不再次提交。请求超时或断网时结果可能未确认，应先刷新列表。需同步更新服务端和 iOS。

## 命令与能力

命名遵循 [Agent 命令命名规范](agent-command-naming.md)：查询固定使用 `query.`，操作固定使用 `action.`，版本使用独立正整数 `version` 字段。CPU 与内存合为 `query.system.metrics` v1；`action.network.http.check` v1 检查 URL。普通名称为至少三段的小写点分段名称，每段以字母开头，允许字母、数字、下划线，总长最多 100 字符。名称唯一，最多 64 项。

`query.all` v1 为协议内置聚合命令，不加入能力清单；只汇总查询提供器。支持按完整名称单独查询或操作，两者都严格匹配清单中的名称和版本。首次连接前 `capabilities: null` 表示未知，已认证空清单为 `[]`；服务端保存最近成功认证的清单，离线和重启后保留，在线状态单独返回。

```json
{"id":"N100","name":"我的设备","online":true,"lastSeen":"2026-10-28T08:00:00Z","capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":1}]}
```

设备清单不预设操作系统，也不返回固定的 `platform`；网页与 iOS 使用设备名称、在线状态和能力清单展示 Agent。移除平台字段后需同步更新服务端与 iOS。

`query.codex.usage` v1 是 Windows Agent 新增的数据提供器，返回本机最近 7 天每日用户发送调用数、token 用量和当前处理中会话数、项目名与显示标题，参数 `{}`，同时加入 `query.all`；详细口径、隐私边界及缓存策略见 [Codex 用量采集](codex-usage.md)。服务端继续通用转发，无新增业务路由。

## 通用设备调用

Console 使用 `POST /api/v1/agents/{id}/requests`，网页使用 `POST /admin/api/agents/{id}/requests`，分别沿用 DPoP 或 Cookie/CSRF 认证。请求必须为 JSON 对象，包含 `method`、`version`、对象 `params`，不接受额外顶层字段，正文上限 16 KiB。

```json
{"method":"query.all","version":1,"params":{}}
```

```json
{"method":"query.system.metrics","version":1,"params":{}}
```

```json
{"method":"action.network.http.check","version":1,"params":{"url":"https://example.com/"}}
```

服务端只校验格式、能力名和版本，保留原始 JSON 参数与结果，不维护具体数据字段及业务错误码。成功转发 HTTP 200，`result` 与 `error` 二选一；单项命令返回直接结果，聚合返回按能力名组织的数据，且附上实际执行连接的清单：

```json
{"capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":1}],"result":{"data":{"query.system.metrics":{"version":1,"result":{"cpuUsagePercent":12.3,"memoryUsagePercent":50,"memoryUsedBytes":8589934592,"memoryTotalBytes":17179869184,"sampledAt":"2026-10-28T08:00:00Z","sampleWindowMs":1000}}}}}
```

聚合每项 `result` / `error` 二选一，一项失败不影响其他项。无查询能力返回空 `data`。单项错误或聚合顶层错误使用 `{"error":{"code":"invalid_params","message":"参数无效。"}}`；错误码匹配 `[A-Za-z0-9_-]{1,80}`，消息最多 1024 UTF-8 字节。`result` 支持对象、数组、标量或 null，不丢失大整数精度。每项结果受消息大小预算约束，超限返回 `result_too_large`。

鉴权及转发失败使用 HTTP 错误和 `{"error":"错误码"}`：格式无效 400 `invalid_request`，未声明或版本不匹配 400 `unsupported_method`，离线或断开 409，并发上限 429，超时 504。每设备最多 4 个待处理请求，全局最多 32 个。服务端等待 10 秒，聚合采集预算 8 秒。断线取消 Agent 连接下的任务，超时不表示请求从未执行。客户端不自动重试操作；明确鉴权失败后的会话续期不属于操作重试。

### 系统指标与网络速率

`query.system.metrics` v1 在原有 CPU、内存与采样时间字段外增加可选的 `network` 对象：

```json
{"available":true,"downloadBytesPerSecond":3072,"uploadBytesPerSecond":1536,"interfaceCount":2,"message":null}
```

Windows Agent 在约 1 秒采样窗口前后读取 `GetIfTable2` 的 64 位收发字节计数器，逐网卡求差后按实际经过时间计算 B/s，再汇总物理网卡；包含局域网流量，不等同于互联网测速。排除回环、隧道、过滤与非物理接口，避免虚拟网络层重复计数。正常空闲返回 0；无法读取、没有符合条件的网卡、网卡增减或计数器重置时，`available: false`、两个速率为 null，并通过 `message` 说明，CPU 与内存继续显示。只在本地或远程请求采样时读取，不后台累积或保存流量，不提供今日累计流量。无需新增服务端路由或命令版本。iOS 对缺少该字段的 Agent 提示更新；网络字段格式错误时仅提示网络数据异常，不丢弃有效的 CPU / 内存数据。

### 监听端口

`query.network.listeners` v1 参数为 `{}`，支持单独调用及 `query.all`，由 Windows Agent 按需读取 TCP LISTEN 和 UDP 绑定端口（IPv4 / IPv6），不统计已连接或出站 TCP 连接。服务端沿用通用转发，不存历史，不需要新增路由。

```json
{"collectedAt":"2026-10-31T08:00:00Z","ports":[{"protocol":"TCP","port":8000,"processes":[{"processId":1234,"processName":"python","startedAt":"2026-10-30T08:00:00Z","uptimeSeconds":86400,"addresses":["0.0.0.0","::"]}]}],"warnings":[]}
```

以 `(protocol, port)` 合并端口，按端口号、协议排序；每项按 PID 保留所有进程，各进程的 `addresses` 去重，包含通配地址、具体 IP 及 IPv6 scope ID。同端口不同 IP 不生成重复端口项，TCP / UDP 同号端口独立展示，避免误把不同协议当成同一监听。

`startedAt` 为进程启动时间（UTC），`uptimeSeconds` 为采集时该进程存活的整秒数，不代表端口监听时长；刷新查询时重新采集。进程退出、权限不足时，能读取的字段继续保留，不可读的 `processName`、`startedAt`、`uptimeSeconds` 为 null，并在 `warnings` 中提示；不会仅因读不到某个进程而丢弃整个列表。部分协议或地址族读取失败时返回其余结果及提示，全部读取失败为 `sample_failed`；结果超过 48 KiB 返回 `result_too_large`，不静默截断。空 `ports` 表示采集未发现端口，须同时查看 `warnings` 是否存在部分采集失败。

进程名和启动时间优先使用 `NtQuerySystemInformation(SystemProcessInformation)` 的同一份系统进程快照，避免逐个打开系统服务进程时被权限拒绝。原生接口动态加载，检查返回链表、名称及时间边界；不可用或布局无效时回退逐进程读取。该接口布局参考 [.NET 的进程快照结构](https://github.com/dotnet/runtime/blob/main/src/libraries/Common/src/Interop/Windows/NtDll/Interop.SYSTEM_PROCESS_INFORMATION.cs)，兼容性边界见 [Windows 原生接口说明](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation)。不使用当前时间或 Agent 启动时间代替未知的进程启动时间。

进程增加可选 `category` 字段（`system` / `user` / null），沿用 v1：系统快照中的 Session 0 归为系统服务会话，其余会话归为用户，不以进程名称、安装路径或是否以管理员运行判定。此分类是会话来源，不等同于账户所属关系，例如在服务会话运行的自建程序也归系统。会话不可读取时为 null；新客户端兼容旧 Agent，缺失分类的进程暂列用户并明确提示。会话依据见 [Microsoft 的 Session 0 隔离说明](https://techcommunity.microsoft.com/blog/askperf/application-compatibility---session-0-isolation/372361/)。

iOS 设备详情的「监听端口」查询卡片与 Windows 本地详情均按「用户 / 系统」排列两个 Tab，默认打开用户，显示各自端口数及空列表提示；同一端口含不同分类的进程时，每个 Tab 保留该分类的进程及地址，不修改完整采集数据。端口默认收起，展开可查看每个 PID 的进程名、启动时间、运行时长及监听 IP。网页沿用通用能力清单与 JSON 展示。Windows 原生表格式依据 [GetExtendedTcpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable) 与 [GetExtendedUdpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedudptable)。

### URL 检测

`action.network.http.check` v1 只接受 `url` 字符串，最长 2048 字符，必须是完整 HTTP/S 地址，不允许 URL 用户名密码或额外参数。允许本机、局域网、端口、路径及查询参数。Agent 使用当前运行环境网络及代理发起 GET，5 秒总超时，收到响应头后结束，不读取正文、不跟随重定向、不携带 Cookie 或系统登录凭据，正常校验 TLS 证书。URL 及结果只转发，不保存为服务器历史。

```json
{"result":{"url":"https://example.com/","reachable":true,"httpSuccess":true,"statusCode":200,"elapsedMs":183,"checkedAt":"2026-10-28T08:00:00Z","failure":null}}
```

收到任何 HTTP 响应即 `reachable: true`，只有 2xx 为 `httpSuccess: true`；3xx、401、404、500 都是可达，显示实际状态码。未收到 HTTP 响应时两项为 false，`statusCode: null`，`failure` 为 `{code,message}`，代码为 `dns_failed`、`connect_failed`、`tls_failed`、`timeout` 或 `request_failed`。目标不可达仍是正常操作结果；无效参数是业务错误，Agent 离线、断开及转发超时是 HTTP 错误。

### 客户端显示

iOS 设备列表将“服务器与登录”配置收纳在右上角的 `slider.horizontal.3` 滑杆图标按钮中，遵循 [iOS 界面规范](../apps/ios/AGENTS.md)，与容器管理保持一致；列表非空时，“添加 Agent”为设备分组标题右侧的加号图标，空列表保留带文字的添加入口。从列表携带的能力清单先创建完整框架，再以一次 `query.all` 填充数据；进入详情及下拉刷新均不额外调用设备列表接口，详情没有工具栏刷新按钮。未知清单通过聚合响应获取。详情在导航栏下方顶部固定“查询 / 操作”页签，内容区显示设备名称、在线状态与 ID，查询成功后不显示额外提示行。每条命令对应一张独立卡片，默认双列排列、大字号时单列，全部放在同一滚动页面，不分页；支持按名称或命令搜索。卡片默认收起，收起时显示关键数值或执行状态，同时最多展开一张，展开后占满一行。切换页签收起内容，展开操作不执行请求。系统指标与 Codex 属于查询，URL 连通性检测属于操作。

长按卡片标题区域即可拖动排序，没有排序按钮或编辑模式；拖至屏幕上下边缘时可继续滚动。顺序按服务器、账号、设备及查询 / 操作分组分别保存在本机，成功放下后保存，取消拖动恢复原顺序。能力临时消失时保留排序记录，新增能力追加到末尾，顺序不影响查询协议或 Agent 能力清单。辅助功能支持“向前移动 / 向后移动”操作。展开前保存可见卡片及其相对位置，展开后仅在卡片显示不完整时自动滚至合适位置；收起后等待布局更新，再恢复原浏览位置。用户主动滚动时取消尚未执行的自动定位，遵循减少动态效果设置。

展开「监听端口」后，标题栏滚至内容区顶部时吸附在固定的「查询 / 操作」页签下方，并可随时点击收起；向回滚动恢复原位置，整张卡片滚出时由卡片底部将标题栏推出。使用原有标题栏和手势，不复制辅助功能按钮，不改变卡片布局高度和滚动位置书签；吸附状态下拖动排序的坐标也包含标题栏位移。用户 / 系统筛选和端口详情继续在标题栏下方滚动。

系统指标将 CPU、内存并列显示，下方显示实时下行 / 上行速度及物理网卡统计范围；Codex 在卡片内切换处理中会话和最近 7 天用量，用量图同时以双轴分组柱状图展示调用数与 Token，点击日期突出两组柱子并悬浮显示当天完整数字，统计说明默认折叠。查询与操作各有独立加载、错误及结果；查询刷新失败在页顶提示并保留旧数据，操作错误在对应卡片内提示。已声明但缺失数据明确显示“未返回数据”。未知查询或版本以可横向滚动的只读 JSON 显示，未知操作显示暂不支持，不推测参数。查询已知为空时跳过自动刷新。URL 检测只由用户点击按钮执行。

网页端只识别 Agent 上报的能力清单：按清单显示名称与版本，用户选择能力、输入 JSON 对象参数，再通过通用请求接口调用，完整响应统一以 JSON 展示。网页不插入清单外命令，不内置系统指标或 URL 检测的专用逻辑、参数模板及结果字段校验。状态刷新仅更新清单与在线状态，不自动调用能力。

## Agent WebSocket

端点 `/ws/agent`，JSON 文本消息，最大 64 KiB，连接后 10 秒内完成认证。三端同步升级，无 v2 兼容层。

```json
{"type":"hello","version":3,"username":"owner","keyId":"公钥指纹","capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":1}]}
```

`keyId=base64url(SHA256(SPKI_DER))`。服务端以预登记 RSA 公钥验证身份，返回 `{"type":"challenge","payload":"标准 Base64"}`。payload 以 `hako-agent-auth/v3\n` 开头，绑定 origin、账号、keyId、随机数；Agent 校验绑定后用 RSA-PSS/SHA-256（salt 长度 32）签原始字节，返回 `{"type":"authenticate","signature":"标准 Base64"}`。认证并保存清单成功后返回 `type=authenticated,agentId,name`，失败以 1008 关闭。最新已认证连接替换旧连接。

服务端每 20 秒发 `{"type":"ping"}`，Agent 回复 `{"type":"pong"}`，60 秒未收到有效消息断开。Agent 接收循环与能力执行分离，最多同时执行 4 个请求，写入串行，检测不阻塞查询或心跳。

```json
{"type":"request","id":"随机请求 ID","method":"query.all","version":1,"params":{}}
```

```json
{"type":"response","id":"原请求 ID","result":{"data":{"query.system.metrics":{"version":1,"result":{"cpuUsagePercent":12.3,"memoryUsagePercent":50,"memoryUsedBytes":8589934592,"memoryTotalBytes":17179869184,"sampledAt":"2026-10-28T08:00:00Z","sampleWindowMs":1000}}}}}
```

失败使用 `{"type":"response","id":"原请求 ID","error":{"code":"invalid_params","message":"参数无效。"}}`。缺失结果、同时包含结果与错误、错误结构无效会断开连接。服务端按连接及请求 ID 隔离超时或旧连接响应，HTTP 响应移除 `type,id`，只对聚合查询附加当前执行连接的能力清单。

## 验证边界

Go 测试覆盖认证、重放、持久登录、轮换恢复、撤销、任意动作与嵌套 JSON 转发、大整数与 null 保真、能力清单、业务错误、旧接口移除及迟到响应隔离。Windows 检查覆盖真实指标和 DPAPI；可与 Go 服务端进行真实 C# Agent 联调。iOS 的 Secure Enclave、公钥导出、Keychain 和实际 UI 需要在 iPhone 上验收；Windows 环境跳过 iOS 编译、签名和安装。
