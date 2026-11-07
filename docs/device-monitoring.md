# 设备监控协议 v4

单用户、多设备。Agent 是跨平台的设备代理角色，仓库当前提供 Windows 实现；iOS 为 Console，服务端为 Hako 统一后端，设备管理是其中的业务模块。三端各自实现协议，不共享代码包。

本版在通用设备请求基础上增加实时订阅。部署时同步更新服务端、Windows Agent 和 iOS Console，Agent 连接要求 v4。应用级认证与扫码登录见 [Hako 服务器认证协议](server-authentication.md)。

## 应用级身份与认证

配置、公钥登记、DPoP 登录、会话管理和 Web 扫码批准统一见 [Hako 服务器认证协议](server-authentication.md)。所有外部通信使用 HTTPS/WSS，设备接口复用主应用 Console 会话和设备签名。

## Console 设备接口

iOS 使用 `wss://<服务器>/ws/console/agents`，升级请求使用主应用的 DPoP 会话认证。收到 `{"type":"ready"}` 后可发送文本 JSON 消息，每条消息带唯一 `id`。服务端返回 `{"type":"reply","id":"…","status":200,"body":{…}}`，其中 `status` 和 `body` 沿用下表 HTTP 接口的状态与响应格式。

| 消息 `type` | 其他字段 | 对应 HTTP 接口 |
| --- | --- | --- |
| `list` | 无 | `GET /api/v1/agents` |
| `register` | `body` 为登记参数 | `POST /api/v1/agents` |
| `request` | `agentId` 和 `body`，后者为命令参数 | `POST /api/v1/agents/{id}/requests` |

服务端继续提供以下 HTTP 接口。

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

iOS 发送 WebSocket `request` 消息，原有 Console HTTP 接口 `POST /api/v1/agents/{id}/requests` 仍可用，两者使用 DPoP 认证。网页使用 `POST /admin/api/agents/{id}/requests`，沿用 Cookie/CSRF 认证。命令参数必须为 JSON 对象，包含 `method`、`version`、对象 `params`，不接受额外顶层字段，正文上限 16 KiB。

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

鉴权及转发失败使用状态码和 `{"error":"错误码"}`：格式无效 400 `invalid_request`，未声明或版本不匹配 400 `unsupported_method`，离线或断开 409，并发上限 429，超时 504。每设备最多 4 个待处理请求，全局最多 32 个。服务端等待 10 秒，聚合采集预算 8 秒。断线取消 Agent 连接下的任务，超时不表示请求从未执行。客户端不自动重试操作；明确鉴权失败后的会话续期不属于操作重试。

## 实时刷新

iOS 在设备详情勾选「实时刷新」后连接 `/ws/console/agents/live/{id}`，同样使用 DPoP 会话认证。服务端发送 `ready` 后，成功订阅返回 `{"type":"subscribed"}`，失败返回 `type: "error"`、`status` 和 `body`。勾选默认关闭。取消勾选、离开详情或进入后台会关闭订阅，回到前台时恢复仍勾选的订阅。设备列表定时更新、详情的进入和下拉刷新仍可发起普通 WebSocket 查询。

首个订阅触发 `{"type":"telemetry_start","id":"…"}`，末个订阅结束时发送 `telemetry_stop`，使用同一个 `id`。Agent 在此期间发送 `telemetry_update`，包含订阅 `id`、已声明的查询 `method`、`version`，以及二选一的 `result` 或 `error`。服务器按设备转发给订阅方，将 `type` 改为 `update` 并省略内部订阅 ID。并发订阅共用 Agent 的采集任务，较慢的连接按能力接收最新数据。

Windows Agent 开始订阅时采集初始数据。系统指标约每秒上报一次，监听端口每 10 秒上报一次。Codex 每秒检查本机任务状态，发现任务开始或结束时重新采集并上报。短任务在两次检查之间结束时，完成记录也会触发上报。其他能力按需调用。上报内容与节奏由 Agent 决定。

### 系统指标、网络与磁盘速率

`query.system.metrics` v1 在原有 CPU、内存与采样时间字段外增加可选的 `network` 对象：

```json
{"available":true,"downloadBytesPerSecond":3072,"uploadBytesPerSecond":1536,"interfaceCount":2,"message":null}
```

Windows Agent 在约 1 秒采样窗口前后读取 `GetIfTable2` 的 64 位收发字节计数器，逐网卡求差后按实际经过时间计算 B/s，再汇总物理网卡；包含局域网流量，不等同于互联网测速。排除回环、隧道、过滤与非物理接口，避免虚拟网络层重复计数。正常空闲返回 0；无法读取、没有符合条件的网卡、网卡增减或计数器重置时，`available: false`、两个速率为 null，并通过 `message` 说明，CPU 与内存继续显示。只在本地或远程请求采样时读取，不后台累积或保存流量，不提供今日累计流量。无需新增服务端路由或命令版本。iOS 对缺少该字段的 Agent 提示更新；网络字段格式错误时仅提示网络数据异常，不丢弃有效的 CPU / 内存数据。

`query.system.metrics` v1 也可包含 `disk`。其中 `volumes` 列出已就绪的固定盘符卷及其已用、总容量，`readBytesPerSecond` 与 `writeBytesPerSecond` 是同一采样窗口内物理磁盘的合计速度。单项速度不可用时返回 null，空闲时返回 0。磁盘数据缺失时，已有的 CPU、内存和网卡指标照常显示。 [Windows 物理磁盘性能计数器](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/performance-history-for-drives)

### 监听端口

`query.network.listeners` v1 参数为 `{}`，支持单独调用及 `query.all`，由 Windows Agent 按需读取 TCP LISTEN 和 UDP 绑定端口（IPv4 / IPv6），不统计已连接或出站 TCP 连接。服务端沿用通用转发，不存历史，不需要新增路由。

```json
{"collectedAt":"2026-10-31T08:00:00Z","ports":[{"protocol":"TCP","port":8000,"processes":[{"processId":1234,"processName":"python","startedAt":"2026-10-30T08:00:00Z","uptimeSeconds":86400,"addresses":["0.0.0.0","::"]}]}],"warnings":[]}
```

以 `(protocol, port)` 合并端口，按端口号、协议排序；每项按 PID 保留所有进程，各进程的 `addresses` 去重，包含通配地址、具体 IP 及 IPv6 scope ID。同端口不同 IP 不生成重复端口项，TCP / UDP 同号端口独立展示，避免误把不同协议当成同一监听。

`startedAt` 为进程启动时间（UTC），`uptimeSeconds` 为采集时该进程存活的整秒数，不代表端口监听时长；刷新查询时重新采集。进程退出、权限不足时，能读取的字段继续保留，不可读的 `processName`、`startedAt`、`uptimeSeconds` 为 null，并在 `warnings` 中提示；不会仅因读不到某个进程而丢弃整个列表。部分协议或地址族读取失败时返回其余结果及提示，全部读取失败为 `sample_failed`；结果超过 48 KiB 返回 `result_too_large`，不静默截断。空 `ports` 表示采集未发现端口，须同时查看 `warnings` 是否存在部分采集失败。

进程名和启动时间优先使用 `NtQuerySystemInformation(SystemProcessInformation)` 的同一份系统进程快照，避免逐个打开系统服务进程时被权限拒绝。原生接口动态加载，检查返回链表、名称及时间边界；不可用或布局无效时回退逐进程读取。该接口布局参考 [.NET 的进程快照结构](https://github.com/dotnet/runtime/blob/main/src/libraries/Common/src/Interop/Windows/NtDll/Interop.SYSTEM_PROCESS_INFORMATION.cs)，兼容性边界见 [Windows 原生接口说明](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation)。不使用当前时间或 Agent 启动时间代替未知的进程启动时间。

进程增加可选 `category` 字段（`system` / `user` / null），沿用 v1，按程序来源分类：使用 [QueryFullProcessImageName](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew) 尝试读取可执行文件路径，规范化后位于 Windows 目录内的程序归系统，其他目录的程序归用户；比较完整目录边界，`Windows.old` 等相似前缀不算 Windows 目录。路径不可读取时，仅已知 Windows 核心进程名（如 System、svchost、lsass）归系统，其他有名称的程序归用户。名称及路径均不可读时为 null，暂列用户并提示。Session 0、SYSTEM 账户或管理员权限不再作为系统分类依据，因此 Python 自建服务、Clash Verge 及其后台服务均归用户。分类仅用于展示推断，不传输完整程序路径；新客户端兼容旧 Agent，缺失分类的进程暂列用户并明确提示。

Python / pythonw 进程增加可选 `launch` 对象，沿用 v1，例如 `{"kind":"script","target":"C:\\Apps\\serve-debug.py"}` 或 `{"kind":"module","target":"http.server"}`。Agent 按需读取进程启动命令，按 Windows 命令行引号规则解析，只返回脚本入口路径或 `-m` 模块名称；忽略解释器选项及脚本的其他参数，不传输完整命令、环境变量或 `-c` 代码。脚本路径保留启动时传入的绝对或相对形式，不用 Agent 的工作目录猜测绝对路径。`kind` 还可为 `inline`、`stdin`、`interactive`、`unavailable`，这几项不包含 target。启动信息读取被权限拒绝、进程已退出或接口不可用时明确返回 unavailable，不根据端口猜测脚本；其他语言的进程不返回 launch。旧客户端忽略新增字段，新客户端仍兼容旧 Agent。列表展示 `python · 脚本名` 或 `python · -m 模块`，展开可复制脚本路径或模块名称。

iOS 设备详情的「监听端口」查询卡片与 Windows 本地详情均按「用户 / 系统」排列两个 Tab，默认打开用户，显示各自端口数及空列表提示；同一端口含不同分类的进程时，每个 Tab 保留该分类的进程及地址，不修改完整采集数据。端口默认收起，展开可查看每个 PID 的进程名、启动时间、运行时长及监听 IP。网页沿用通用能力清单与 JSON 展示。Windows 原生表格式依据 [GetExtendedTcpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable) 与 [GetExtendedUdpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedudptable)。

### URL 检测

`action.network.http.check` v1 只接受 `url` 字符串，最长 2048 字符，必须是完整 HTTP/S 地址，不允许 URL 用户名密码或额外参数。允许本机、局域网、端口、路径及查询参数。Agent 使用当前运行环境网络及代理发起 GET，5 秒总超时，收到响应头后结束，不读取正文、不跟随重定向、不携带 Cookie 或系统登录凭据，正常校验 TLS 证书。URL 及结果只转发，不保存为服务器历史。

```json
{"result":{"url":"https://example.com/","reachable":true,"httpSuccess":true,"statusCode":200,"elapsedMs":183,"checkedAt":"2026-10-28T08:00:00Z","failure":null}}
```

收到任何 HTTP 响应即 `reachable: true`，只有 2xx 为 `httpSuccess: true`；3xx、401、404、500 都是可达，显示实际状态码。未收到 HTTP 响应时两项为 false，`statusCode: null`，`failure` 为 `{code,message}`，代码为 `dns_failed`、`connect_failed`、`tls_failed`、`timeout` 或 `request_failed`。目标不可达仍是正常操作结果；无效参数是业务错误，Agent 离线、断开及转发超时是 HTTP 错误。

### Git 仓库

Windows Agent 按需检查当前用户 `~/Code` 的一级子目录，列出其中的 Git 仓库和 worktree。扫描跳过 Git 元数据目录和目录链接。远程地址显示前会去除 URL 中的凭据与查询参数。仓库列表的领先和落后数使用本机远程跟踪引用。打开仓库详情或下拉刷新时，有效期内直接读取跟踪引用。成功检查远端后，Agent 按仓库和远端分支在内存中缓存一小时。

| 命令（v1） | 参数 | 结果 |
| --- | --- | --- |
| `query.git.repositories` | 首次 `{}`，后续传 `cursor` | 仓库摘要、扫描范围和 `nextCursor`，为空时扫描完成 |
| `query.git.repository` | `repository` | 该仓库的文件状态、最近待推送提交和用于确认的 `revision` |
| `action.git.commit` | `repository`、`revision`、`message`、`files`（文件索引） | 提交选中文件的当前内容，返回操作 ID |
| `action.git.push` | `repository`、`revision` | 向上游分支或 `origin` 同名分支普通推送，返回操作 ID |
| `query.git.remote` | `repository` | 获取远端分支并更新对应跟踪引用，返回操作 ID |
| `action.git.pull` | `repository`、`revision` | 快进到已确认的远端提交，返回操作 ID |
| `query.git.operation` | `operation` | `running`、`succeeded`、`failed` 或 `unknown` |

`repository` 是相对 Code 根目录的仓库标识。提交、推送和拉取分别确认。提交保留未选文件及其暂存状态，推送使用已确认的提交和目标分支。远端检查只更新跟踪引用。发现远端新提交时显示「拉取」，本地有改动或分支分叉时需先在电脑上处理。拉取会重新核对仓库状态，并快进到已确认的提交。Git 使用电脑当前用户的配置和现有凭据。Git 查询按需调用，进入系统详情时的 `query.all` 不扫描仓库。

### 构建进度

Hako iOS 在「设置 → 构建进度 → 本地」通过 chore 的只读接口 `/chore/ios/build-status.json` 查看本机 xkode 任务。

### 客户端显示

iOS 设备列表右上角的滑杆打开「服务器与登录」，设备详情右上角的滑杆打开页面排序。详情显示设备名称、在线状态和 ID，顶部沿用运动记录的下划线标签栏。排序前五项显示在顶部，其余通过「更多」切换。长按行尾手柄拖动整行，点「完成」后按服务器、账号和设备保存顺序。能力临时消失时保留排序记录，新增能力追加到末尾。

进入详情和下拉刷新使用 `query.all` 更新常规数据和能力清单。「Git」页首次没有缓存时自动扫描，结果按服务器、账号和设备保存在本机。之后打开页面读取缓存，点「重新扫描」才更新仓库清单。扫描失败会保留上次结果。提交与推送只在相应确认页执行。系统页并列显示最新 CPU 和内存仪表盘，下方显示实时网卡速率。Codex 保留处理中会话和最近 7 天的双轴分组柱状图，点击日期查看当天明细。未知查询以只读 JSON 显示，未知操作提示暂不支持。

网页端只识别 Agent 上报的能力清单：按清单显示名称与版本，用户选择能力、输入 JSON 对象参数，再通过通用请求接口调用，完整响应统一以 JSON 展示。网页不插入清单外命令，不内置系统指标或 URL 检测的专用逻辑、参数模板及结果字段校验。状态刷新仅更新清单与在线状态，不自动调用能力。

## Agent WebSocket

端点 `/ws/agent`，JSON 文本消息，最大 64 KiB，连接后 10 秒内完成认证。三端同步升级，无 v2 兼容层。

```json
{"type":"hello","version":4,"username":"owner","keyId":"公钥指纹","capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":1}]}
```

`keyId=base64url(SHA256(SPKI_DER))`。服务端以预登记 RSA 公钥验证身份，返回 `{"type":"challenge","payload":"标准 Base64"}`。payload 以 `hako-agent-auth/v4\n` 开头，绑定 origin、账号、keyId、随机数；Agent 校验绑定后用 RSA-PSS/SHA-256（salt 长度 32）签原始字节，返回 `{"type":"authenticate","signature":"标准 Base64"}`。认证并保存清单成功后返回 `type=authenticated,agentId,name`，失败以 1008 关闭。最新已认证连接替换旧连接。

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
