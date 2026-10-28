# 设备监控协议 v3

单用户、多设备。Agent 是跨平台的设备代理角色，仓库当前提供 Windows 实现；iOS 为 Console，服务端为设备管理服务。三端各自实现协议，不共享代码包。

本版统一使用通用设备请求，移除旧的 `/metrics/query` 接口和 Agent v1/v2 消息协议，不提供兼容层。部署时同步更新服务端、Windows Agent 和 iOS Console；认证、会话与扫码登录 HTTP 路径保持不变。

## 配置与身份

服务端 `config/server.json` 包含唯一 `username` 和手工登记的 `consoles` P-256 公钥，所有 Console 都是管理员。每次启动以文件更新 Console 信任，增删需重启。`agents` 仅用于首次导入，之后由数据库、`/admin/` 管理页及已登录 iOS Console 即时维护。Console 无密码、TOTP 或公开注册，私钥由 iPhone Secure Enclave 保存，只导出 SPKI PEM 公钥；Agent 使用 RSA，私钥由 Agent 所在设备保存。

Console 设备身份可在未配置服务器、未联网、未登录时本地生成并单独导出公钥，立即持久保存，后续新服务器沿用该身份。旧版本已有的服务器密钥绑定继续保留，首次读取时可作为本机默认身份；重复导出不重新生成密钥，登录会话仍按服务器和账号隔离。

iOS 可通过红色「重置密钥对」并二次确认替换本机身份。新密钥和重置标记先原子写入 Keychain，再清理旧身份与本机会话；旧绑定不会因清理中断而恢复。恢复会话时再次校验凭据中的设备 ID 与当前公钥匹配。离线重置不修改服务端信任，操作员需替换服务端旧公钥并重启，清理旧 Console 和关联网页会话。

所有外部通信使用 HTTPS/WSS。服务地址必须为根 origin；反向代理保持原路径。服务端使用配置的 `HAKO_PUBLIC_URL` 校验签名 URL，不信任客户端的 Host 或 X-Forwarded-* 构造签名目标。

## Web 管理

`/admin/` 只支持已登录 Console 扫码批准，没有管理密钥入口。网页 POST `/admin/api/login/requests` 创建 90 秒有效请求，获得 ID、确认码、到期时间和 `hako://admin-login?v=1&server=<origin>&request=<id>` 二维码。浏览器私有绑定凭据仅保存在 HttpOnly、SameSite=Strict 的 Cookie 中，不放入二维码。

Console 只接受当前 HTTPS 服务器的二维码或手动粘贴的登录请求，带现有 DPoP 会话 GET `/api/v1/admin-login/requests/{id}` 获取服务器、确认码、浏览器、`clientIP` 及 nonce。`clientIP` 是创建二维码的浏览器访问来源（IPv4/IPv6），确认页显示「来源 IP」；不是扫码手机的 IP 或浏览器的局域网地址。默认取连接地址，仅对 `HAKO_TRUSTED_PROXIES` 配置的可信代理按 `X-Forwarded-For` 从右向左解析，取首个不可信地址。该字段不出现在二维码、创建响应或网页轮询中。浏览器名由 User-Agent 提示，用于会话列表，支持桌面与 iOS 的 Chrome/Firefox/Edge 标识。核对确认页并点击确认或拒绝后，POST 同一路径的 `/approve` 或 `/deny`，正文为 `confirmationCode`，DPoP 声明必须包含 nonce。确认登录不再额外要求 Face ID、Touch ID 或设备密码。签名绑定完整请求路径、方法、访问令牌和挑战，防止替换与重放。

网页 GET `/admin/api/login/requests/{id}` 轮询 pending/scanned/approved/denied，仅原浏览器可读取；批准后由原浏览器 POST `/complete` 领取一次性会话。扫码和 GET 轮询不颁发会话；重复批准、领取、过期或被刷新替换的请求均拒绝。二维码不携带 Console 令牌或私钥。

网页会话使用独立 Cookie 与 CSRF，HTTPS 启用 Secure 与 `__Host-`；修改请求验证 origin。闲置 30 分钟、登录 12 小时或服务重启后过期，轮询不续期。每次访问还检查批准它的 Console 会话有效，Console 退出或撤销使关联网页会话失效。

`/admin/api/` 保留 `session`、`logout`、`overview`、Agent 公钥增删和通用能力调用；网页只展示 Agent，不展示管理客户端列表、数量、公钥或 Console 登录会话，`overview` 不返回 `consoles` 或手机会话列表；网页不能撤销手机会话，服务端不提供 `DELETE /admin/api/sessions/{id}` 路由。Console 会话管理仅接受 Console 的 DPoP 认证；Console 公钥只能在服务端配置文件修改。Agent 删除立即断开连接，完成挑战后的设备也会在注册在线前再次检查信任。手工移除 Console 并重启会清理其会话和登录挑战，重新添加不恢复旧会话。部署见 [服务端说明](../apps/server/README.md)。

## Console HTTP

所有签名请求带 `DPoP` JWT（ES256），头部包含 `typ=dpop+jwt`、`alg=ES256`、P-256 公钥 JWK。声明包括 `htm`、`htu`（不含查询参数）、`iat`、随机 `jti`。业务请求额外包含 `ath=base64url(SHA256(accessToken))`，并带 `Authorization: DPoP <accessToken>`、`X-Hako-Device: <deviceId>`。

设备 ID 是 RFC 7638 公钥 JWK 指纹：以键序 `crv,kty,x,y` 构造无额外空白的 JSON，SHA-256 后 base64url，无填充。ES256 签名为固定 64 字节 `r || s`，不是 ASN.1 DER。

首次主动登录：

1. `POST /api/v1/auth/challenge`，正文 `username,deviceId`，带设备 DPoP；服务端验证预登记公钥，返回 `challengeId,nonce`。
2. `POST /api/v1/auth/login`，正文 `username,deviceId,challengeId`，使用新的 DPoP，声明中加入服务端 `nonce`。挑战 10 秒有效且仅可成功使用一次。
3. 成功返回 `sessionId,deviceId,accessToken,refreshToken,expiresAt`。访问令牌 15 分钟有效。刷新会话无固定或闲置时限。

`POST /api/v1/auth/refresh` 正文为 `sessionId,deviceId,refreshToken,rotationId`，使用设备 DPoP，不带访问令牌。客户端先持久保存随机 `rotationId`，再发请求；响应成功后原子保存新令牌并清除 rotation ID。若响应丢失，使用原刷新凭据、相同 rotation ID 和新的 DPoP 重试。不同 rotation ID 重用旧凭据撤销会话。

刷新、重放检测、会话撤销持久化到加密 SQLite 文档。每个资源请求同时检查会话和当前公钥登记；会话从不因本地存在令牌就被视为有效。客户端不自动重新登录来绕过撤销，只能由用户主动登录。

| 接口 | 用途 |
| --- | --- |
| `GET /api/v1/auth/session` | 校验当前登录态 |
| `POST /api/v1/auth/logout` | 撤销当前会话 |
| `GET /api/v1/sessions` | 查看有效的 Console 和网页管理端登录会话 |
| `DELETE /api/v1/sessions/{id}` | 撤销指定 Console 会话 |
| `DELETE /api/v1/web-sessions/{id}` | 单独撤销指定网页管理端会话，需 Console DPoP 认证 |
| `GET /api/v1/agents` | 返回 `agents` 数组：`id,name,online,lastSeen,capabilities` |
| `POST /api/v1/agents` | 登记 Agent，正文 `name,publicKeyPem`，ID 自动生成；需 Console DPoP 会话认证，成功返回 201 和 `id,keyId` |
| `POST /api/v1/agents/{id}/requests` | 转发通用动作请求，默认最多等待 10 秒 |

会话列表的 `sessions` 数组包含 `id,type,createdAt,current`，`type` 为 `console` 或 `web`；Console 项包含 `deviceId`，网页项包含 `browser,lastUsedAt`。网页的 `id` 是独立的管理标识，不是登录 Cookie 或其哈希；列表不返回 Cookie、CSRF 或 Console 令牌。当前 Console 优先，其余按登录时间倒序排列。列表过滤过期或批准方已失效的网页会话，读取列表不延长网页闲置期限。iOS「已登录设备」显示会话类型、浏览器和时间，支持下拉刷新及「移除网页登录」；移除后该浏览器下次请求即返回未登录，不影响其他浏览器或 Console。服务端与 iOS 需同步更新。

iOS「设备监控 → 添加 Agent」和网页登记入口只填写名称及公钥，支持粘贴或导入 Agent 导出的 RSA 公钥；添加成功立即生效并刷新设备列表，无需重启服务端。两者共用校验、持久化及并发锁。未提供或提供空 `id` 时，服务端使用密码学随机数生成 5 位唯一 ID，只含大写字母和数字，以字母开头（如 `A7K2Q`），发生重号时重新生成，并与公钥一同持久化，重启后保留；客户端使用响应中的 `id` 定位设备。接口仍接受可选的显式 `id`，格式为 `[A-Z][A-Z0-9]{0,4}`，即 1–5 位大写字母或数字且以字母开头。登记和去重在同一把锁内完成，避免并发重号。名称非空且最多 100 个 UTF-8 字节，接受单个 SPKI 或 PKCS#1 PEM RSA 2048–8192 位公钥，不接受私钥或文件路径。请求上限 16 KiB。重复公钥或显式 ID 返回 409 `duplicate_agent`，非法设备或公钥返回 400 `invalid_public_key_or_device`，存储失败返回 503 `storage_unavailable`，无法分配 ID 时返回 503 `device_id_unavailable`。iOS 在发送前拒绝私钥并校验输入；登记成功但列表刷新失败时使用响应 ID 保留新增设备并提示刷新，不再次提交。请求超时或断网时结果可能未确认，应先刷新列表。需同步更新服务端和 iOS。

网络错误保留登录凭据；明确会话撤销后才进入重新登录流程。离线退出持久标记 `logoutPending`，停止本地使用并在下次联网时尝试服务端撤销。

## 命令与能力

命名遵循 [Agent 命令命名规范](agent-command-naming.md)：查询固定使用 `query.`，操作固定使用 `action.`，版本使用独立正整数 `version` 字段。CPU 与内存合为 `query.system.metrics` v1；`action.network.http.check` v1 检查 URL。普通名称为至少三段的小写点分段名称，每段以字母开头，允许字母、数字、下划线，总长最多 100 字符。名称唯一，最多 64 项。

`query.all` v1 为协议内置聚合命令，不加入能力清单；只汇总查询提供器。支持按完整名称单独查询或操作，两者都严格匹配清单中的名称和版本。首次连接前 `capabilities: null` 表示未知，已认证空清单为 `[]`；服务端保存最近成功认证的清单，离线和重启后保留，在线状态单独返回。

```json
{"id":"N100","name":"我的设备","online":true,"lastSeen":"2026-10-28T08:00:00Z","capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":1}]}
```

设备清单不预设操作系统，也不返回固定的 `platform`；网页与 iOS 使用设备名称、在线状态和能力清单展示 Agent。移除平台字段后需同步更新服务端与 iOS。

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

### URL 检测

`action.network.http.check` v1 只接受 `url` 字符串，最长 2048 字符，必须是完整 HTTP/S 地址，不允许 URL 用户名密码或额外参数。允许本机、局域网、端口、路径及查询参数。Agent 使用当前运行环境网络及代理发起 GET，5 秒总超时，收到响应头后结束，不读取正文、不跟随重定向、不携带 Cookie 或系统登录凭据，正常校验 TLS 证书。URL 及结果只转发，不保存为服务器历史。

```json
{"result":{"url":"https://example.com/","reachable":true,"httpSuccess":true,"statusCode":200,"elapsedMs":183,"checkedAt":"2026-10-28T08:00:00Z","failure":null}}
```

收到任何 HTTP 响应即 `reachable: true`，只有 2xx 为 `httpSuccess: true`；3xx、401、404、500 都是可达，显示实际状态码。未收到 HTTP 响应时两项为 false，`statusCode: null`，`failure` 为 `{code,message}`，代码为 `dns_failed`、`connect_failed`、`tls_failed`、`timeout` 或 `request_failed`。目标不可达仍是正常操作结果；无效参数是业务错误，Agent 离线、断开及转发超时是 HTTP 错误。

### 客户端显示

iOS 从列表携带的能力清单先创建完整框架，再以一次 `query.all` 填充数据；进入详情、按钮刷新及下拉刷新均不额外调用设备列表接口。未知清单通过聚合响应获取。查询与操作各有独立加载、错误及结果；刷新失败保留旧数据并标注。已声明但缺失数据明确显示“未返回数据”。未知查询或版本以只读 JSON 显示，未知操作显示暂不支持，不推测参数。查询已知为空时跳过自动刷新。URL 检测只由用户点击按钮执行。

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
