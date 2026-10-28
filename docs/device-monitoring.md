# 设备监控协议 v2

单用户、多设备。Windows 为 Agent，iOS 为 Console，服务端为设备管理服务。三端各自实现协议，不共享代码包。

本版统一使用通用设备请求，移除旧的 `/metrics/query` 接口和 Agent v1 消息协议，不提供兼容层。部署时同步更新服务端、Windows Agent 和 iOS Console；认证、会话与扫码登录 HTTP 路径保持不变。

## 配置与身份

服务端 `config/server.json` 包含唯一 `username` 和手工登记的 `consoles` P-256 公钥，所有 Console 都是管理员。每次启动以文件更新 Console 信任，增删需重启。`agents` 仅用于首次导入，之后由数据库、`/admin/` 管理页及已登录 iOS Console 即时维护。Console 无密码、TOTP 或公开注册，私钥由 iPhone Secure Enclave 保存，只导出 SPKI PEM 公钥；Agent 使用 RSA，私钥由 Windows 保存。

Console 设备身份可在未配置服务器、未联网、未登录时本地生成并单独导出公钥，立即持久保存，后续新服务器沿用该身份。旧版本已有的服务器密钥绑定继续保留，首次读取时可作为本机默认身份；重复导出不重新生成密钥，登录会话仍按服务器和账号隔离。

iOS 可通过红色「重置密钥对」并二次确认替换本机身份。新密钥和重置标记先原子写入 Keychain，再清理旧身份与本机会话；旧绑定不会因清理中断而恢复。恢复会话时再次校验凭据中的设备 ID 与当前公钥匹配。离线重置不修改服务端信任，操作员需替换服务端旧公钥并重启，清理旧 Console 和关联网页会话。

所有外部通信使用 HTTPS/WSS。服务地址必须为根 origin；反向代理保持原路径。服务端使用配置的 `HAKO_PUBLIC_URL` 校验签名 URL，不信任客户端的 Host 或 X-Forwarded-* 构造签名目标。

## Web 管理

`/admin/` 只支持已登录 Console 扫码批准，没有管理密钥入口。网页 POST `/admin/api/login/requests` 创建 90 秒有效请求，获得 ID、确认码、到期时间和 `hako://admin-login?v=1&server=<origin>&request=<id>` 二维码。浏览器私有绑定凭据仅保存在 HttpOnly、SameSite=Strict 的 Cookie 中，不放入二维码。

Console 只接受当前 HTTPS 服务器的二维码或手动粘贴的登录请求，带现有 DPoP 会话 GET `/api/v1/admin-login/requests/{id}` 获取服务器、确认码、浏览器及 nonce。核对确认页并点击确认或拒绝后，POST 同一路径的 `/approve` 或 `/deny`，正文为 `confirmationCode`，DPoP 声明必须包含 nonce。确认登录不再额外要求 Face ID、Touch ID 或设备密码。签名绑定完整请求路径、方法、访问令牌和挑战，防止替换与重放。

网页 GET `/admin/api/login/requests/{id}` 轮询 pending/scanned/approved/denied，仅原浏览器可读取；批准后由原浏览器 POST `/complete` 领取一次性会话。扫码和 GET 轮询不颁发会话；重复批准、领取、过期或被刷新替换的请求均拒绝。二维码不携带 Console 令牌或私钥。

网页会话使用独立 Cookie 与 CSRF，HTTPS 启用 Secure 与 `__Host-`；修改请求验证 origin。闲置 30 分钟、登录 12 小时或服务重启后过期，轮询不续期。每次访问还检查批准它的 Console 会话有效，Console 退出或撤销使关联网页会话失效。

`/admin/api/` 保留 `session`、`logout`、`overview`、Agent 公钥增删、指标查询和 Console 会话撤销；Console 公钥只能在文件修改，网页只读。Agent 删除立即断开连接，完成挑战后的设备也会在注册在线前再次检查信任。手工移除 Console 并重启会清理其会话和登录挑战，重新添加不恢复旧会话。部署见 [服务端说明](../apps/server/README.md)。

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
| `GET /api/v1/agents` | 返回 `agents` 数组：`id,name,platform,online,lastSeen,methods` |
| `POST /api/v1/agents` | 登记 Agent，正文 `id,name,publicKeyPem`，需 Console DPoP 会话认证；成功返回 201 和 `id,keyId` |
| `POST /api/v1/agents/{id}/requests` | 转发通用动作请求，默认最多等待 10 秒 |

会话列表的 `sessions` 数组包含 `id,type,createdAt,current`，`type` 为 `console` 或 `web`；Console 项包含 `deviceId`，网页项包含 `browser,lastUsedAt`。网页的 `id` 是独立的管理标识，不是登录 Cookie 或其哈希；列表不返回 Cookie、CSRF 或 Console 令牌。当前 Console 优先，其余按登录时间倒序排列。列表过滤过期或批准方已失效的网页会话，读取列表不延长网页闲置期限。iOS「已登录设备」显示会话类型、浏览器和时间，支持下拉刷新及「移除网页登录」；移除后该浏览器下次请求即返回未登录，不影响其他浏览器或 Console。服务端与 iOS 需同步更新。

iOS「设备监控 → 添加 Agent」支持粘贴或导入 Windows RSA 公钥；添加成功立即生效并刷新设备列表，无需重启服务端。Console 登记和网页登记共用校验、持久化及并发锁：设备 ID 为 1–80 位英文字母、数字、下划线或连字符，名称非空且最多 100 个 UTF-8 字节，接受单个 SPKI 或 PKCS#1 PEM RSA 2048–8192 位公钥，不接受私钥或文件路径。请求上限 16 KiB。重复设备 ID 或公钥返回 409 `duplicate_agent`，非法设备或公钥返回 400 `invalid_public_key_or_device`，存储失败返回 503 `storage_unavailable`。iOS 在发送前拒绝私钥并校验输入；登记成功但列表刷新失败时保留新增设备并提示刷新，不再次提交。请求超时或断网时结果可能未确认，应先刷新列表。旧服务端需升级后才能使用此入口。

网络错误保留登录凭据；明确会话撤销后才进入重新登录流程。离线退出持久标记 `logoutPending`，停止本地使用并在下次联网时尝试服务端撤销。

## 通用设备调用

Console 使用 `POST /api/v1/agents/{id}/requests`，网页使用 `POST /admin/api/agents/{id}/requests`。两者共用同一转发实现，各自沿用 DPoP 或 Cookie/CSRF 认证；所有可信 Console 及其批准的网页会话都具有管理员权限，可以调用 Agent 声明的动作。

请求必须为 JSON 对象，包含 `method` 和对象类型的 `params`（无参数时传 `{}`），不接受额外顶层字段。请求正文上限 16 KiB：

```json
{"method":"system.metrics","params":{}}
```

服务端只校验消息格式和动作是否在当前连接的能力清单中，不解析业务参数、不校验具体指标，也不按动作建立 HTTP 路由。参数及结果使用原始 JSON 转发，保留嵌套字段和大整数精度。新增字段、动作、参数和业务错误码通常只需更新 Agent 和相应客户端，无需更新服务端。

设备列表和网页 `overview` 中的每台设备包含 `methods`：

```json
{"id":"pc","name":"PC","platform":"windows","online":true,"lastSeen":"2026-10-27T10:00:00Z","methods":[{"name":"system.metrics","version":1}]}
```

能力清单由 Agent 在认证连接的 `hello` 中上报，包含 1–64 个不重复动作。动作名称最长 100 字符，格式为小写字母开头的点分段名称（段内允许小写字母、数字、下划线，例如 `disk.metrics`、`process.list`），版本为正整数。版本用于客户端选择可理解的参数与结果，不由服务端解释。离线设备的 `methods` 为空数组；能力变化需重连，重复设备连接使用最新已认证连接的清单。Agent 只能执行自身注册的动作。

HTTP 成功转发后统一返回 200，正文为以下两种结构之一；动作执行失败也以 200 返回业务错误，客户端必须检查 `error`：

```json
{"result":{"cpuUsagePercent":12.3,"memoryUsagePercent":50,"memoryUsedBytes":8589934592,"memoryTotalBytes":17179869184,"sampledAt":"2026-10-25T10:00:00Z","sampleWindowMs":1000}}
```

```json
{"error":{"code":"sample_failed","message":"设备采样失败。"}}
```

`result` 可以是任意 JSON 值（包含数组、标量和 `null`），必须与 `error` 二选一。错误码为 1–80 位英文字母、数字、下划线或连字符，错误信息最多 1024 个 UTF-8 字节。服务端不维护业务错误码列表。

鉴权、转发失败仍使用 HTTP 错误状态和 `{"error":"错误码"}`：参数格式无效或动作未声明为 400（`invalid_request` / `unsupported_method`），离线或连接中断为 409，并发上限为 429，超时为 504。超时或断线不代表动作未执行，也不会自动取消 Agent 上的动作；客户端不得自动重试有副作用的动作，应先确认执行结果。需要流式响应、超过消息大小/等待时限的任务或新的权限规则时，仍需扩展协议与服务端。

当前 Windows 注册 `system.metrics` v1，参数为 `{}`，结果为本次 CPU 与物理内存采样；额外参数返回 `invalid_params`。网页保留指标展示，同时提供基于能力清单的动作选择、JSON 参数输入和 JSON 结果查看；iOS 通过通用调用解码系统指标，新增专用展示需更新客户端。

## Agent WebSocket

端点 `/ws/agent`，JSON 文本消息，最大 64 KiB。建立连接后 10 秒内认证。

```json
{"type":"hello","version":2,"username":"owner","keyId":"公钥指纹","methods":[{"name":"system.metrics","version":1}]}
```

`keyId=base64url(SHA256(SPKI_DER))`。服务端查找预登记 RSA 公钥，返回 `{"type":"challenge","payload":"标准 Base64"}`。payload 以 `hako-agent-auth/v2\n` 开头，绑定 origin、账号、keyId 以及随机数；Windows 检查前缀绑定后，用 RSA-PSS/SHA-256（salt 长度 32 字节）对原始 payload 字节签名，返回：

```json
{"type":"authenticate","signature":"标准 Base64"}
```

成功返回 `type=authenticated,agentId,name`。身份验证失败以 WebSocket 1008 关闭。重复设备连接仅保留最新的已认证连接。服务端每 20 秒发送 `{"type":"ping"}`，Agent 返回 `{"type":"pong"}`；60 秒未收到有效消息断开。

动作请求消息：

```json
{"type":"request","id":"随机请求 ID","method":"system.metrics","params":{}}
```

结果消息：

```json
{
  "type": "response",
  "id": "原请求 ID",
  "result": {
    "cpuUsagePercent": 12.3,
    "memoryUsagePercent": 50,
    "memoryUsedBytes": 8589934592,
    "memoryTotalBytes": 17179869184,
    "sampledAt": "2026-10-25T10:00:00Z",
    "sampleWindowMs": 1000
  }
}
```

失败返回 `{"type":"response","id":"原请求 ID","error":{"code":"sample_failed","message":"设备采样失败。"}}`，不伪造零值。缺失结果、同时包含结果与错误或错误结构无效会断开连接。服务端按当前设备连接和请求 ID 匹配，超时或旧连接响应不会作为新查询结果。每设备最多 4 个待处理请求，服务全局最多 32 个。

服务端把本次 `result` 或 `error` 包装为上述 HTTP JSON 返回，不包含 WebSocket 的 `type`、`id`。iOS 手动刷新，不持续轮询，不保存历史指标。

## 验证边界

Go 测试覆盖认证、重放、持久登录、轮换恢复、撤销、任意动作与嵌套 JSON 转发、大整数与 null 保真、能力清单、业务错误、旧接口移除及迟到响应隔离。Windows 检查覆盖真实指标和 DPAPI；可与 Go 服务端进行真实 C# Agent 联调。iOS 的 Secure Enclave、公钥导出、Keychain 和实际 UI 需要在 iPhone 上验收；Windows 环境跳过 iOS 编译、签名和安装。
