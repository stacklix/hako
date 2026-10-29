# Hako 服务器认证协议

Hako 统一后端为主应用和子应用提供服务。服务器配置、设备身份、Console 登录、登录会话和扫码批准属于主应用；设备监控复用这些能力。iOS 入口为首页「扫码登录」及「设置 → 服务器与登录」，无需先进入设备监控。Console 表示可信管理客户端角色。

## 配置与身份

服务端 `config/server.json` 包含唯一 `username` 和手工登记的 `consoles` P-256 公钥，所有 Console 都是管理员。每次启动以文件更新 Console 信任，增删需重启。`agents` 仅用于首次导入，之后由数据库、`/admin/` 管理页及已登录 iOS Console 即时维护。Console 无密码、TOTP 或公开注册，私钥由 iPhone Secure Enclave 保存，只导出 SPKI PEM 公钥；Agent 使用 RSA，私钥由 Agent 所在设备保存。

Console 设备身份可在未配置服务器、未联网、未登录时本地生成并单独导出公钥，立即持久保存，后续新服务器沿用该身份。旧版本已有的服务器密钥绑定继续保留，首次读取时可作为本机默认身份；重复导出不重新生成密钥，登录会话仍按服务器和账号隔离。

iOS 可通过红色「重置密钥对」并二次确认替换本机身份。新密钥和重置标记先原子写入 Keychain，再清理旧身份与本机会话；旧绑定不会因清理中断而恢复。恢复会话时再次校验凭据中的设备 ID 与当前公钥匹配。离线重置不修改服务端信任，操作员需替换服务端旧公钥并重启，清理旧 Console 和关联网页会话。

所有外部通信使用 HTTPS/WSS。服务地址必须为根 origin；反向代理保持原路径。服务端使用配置的 `HAKO_PUBLIC_URL` 校验签名 URL，不信任客户端的 Host 或 X-Forwarded-* 构造签名目标。

## Web 管理

`/admin/` 只支持已登录 Console 扫码批准，没有管理密钥入口。网页 POST `/admin/api/login/requests` 创建 90 秒有效请求，获得 ID、确认码、到期时间和 `hako://web-login?v=1&server=<origin>&request=<id>` 二维码。浏览器私有绑定凭据仅保存在 HttpOnly、SameSite=Strict 的 Cookie 中，不放入二维码。

Console 只接受当前 HTTPS 服务器的二维码或手动粘贴的登录请求，带现有 DPoP 会话 GET `/api/v1/auth/web-login/requests/{id}` 获取服务器、确认码、浏览器、`clientIP` 及 nonce。`clientIP` 是创建二维码的浏览器访问来源（IPv4/IPv6），确认页显示「来源 IP」；不是扫码手机的 IP 或浏览器的局域网地址。默认取连接地址，仅对 `HAKO_TRUSTED_PROXIES` 配置的可信代理按 `X-Forwarded-For` 从右向左解析，取首个不可信地址。该字段不出现在二维码、创建响应或网页轮询中。浏览器名由 User-Agent 提示，用于会话列表，支持桌面与 iOS 的 Chrome/Firefox/Edge 标识。核对确认页并点击确认或拒绝后，POST 同一路径的 `/approve` 或 `/deny`，正文为 `confirmationCode`，DPoP 声明必须包含 nonce。确认登录不再额外要求 Face ID、Touch ID 或设备密码。签名绑定完整请求路径、方法、访问令牌和挑战，防止替换与重放。

网页 GET `/admin/api/login/requests/{id}` 轮询 pending/scanned/approved/denied，仅原浏览器可读取；批准后由原浏览器 POST `/complete` 领取一次性会话。扫码和 GET 轮询不颁发会话；重复批准、领取、过期或被刷新替换的请求均拒绝。二维码不携带 Console 令牌或私钥。

网页会话使用独立 Cookie 与 CSRF，HTTPS 启用 Secure 与 `__Host-`；修改请求验证 origin。闲置 30 分钟、登录 12 小时或服务重启后过期，轮询不续期。每次访问还检查批准它的 Console 会话有效，Console 退出或撤销使关联网页会话失效。

`/admin/api/` 保留 `session`、`logout`、`agents` 资源及通用能力调用；网页只展示 Agent，不展示管理客户端列表、数量、公钥或 Console 登录会话，`GET /admin/api/agents` 只返回 `agents,updatedAt`，不返回账号、`consoles` 或手机会话列表，账号由 `/admin/api/session` 返回；网页不能撤销手机会话，服务端不提供 `DELETE /admin/api/sessions/{id}` 路由。Console 会话管理仅接受 Console 的 DPoP 认证；Console 公钥只能在服务端配置文件修改。Agent 删除立即断开连接，完成挑战后的设备也会在注册在线前再次检查信任。手工移除 Console 并重启会清理其会话和登录挑战，重新添加不恢复旧会话。部署见 [服务端说明](../apps/server/README.md)。

## Console 认证与会话

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
| `DELETE /api/v1/web-sessions/{id}` | 单独撤销指定网页管理端会话，需 Console DPoP 认证 |

会话列表的 `sessions` 数组包含 `id,type,createdAt,current`，`type` 为 `console` 或 `web`；Console 项包含 `deviceId`，网页项包含 `browser,lastUsedAt`。网页的 `id` 是独立的管理标识，不是登录 Cookie 或其哈希；列表不返回 Cookie、CSRF 或 Console 令牌。当前 Console 优先，其余按登录时间倒序排列。列表过滤过期或批准方已失效的网页会话，读取列表不延长网页闲置期限。iOS「已登录设备」显示会话类型、浏览器和时间，支持下拉刷新及「移除网页登录」；移除后该浏览器下次请求即返回未登录，不影响其他浏览器或 Console。服务端与 iOS 需同步更新。

网络错误保留登录凭据；明确会话撤销后才进入重新登录流程。离线退出持久标记 `logoutPending`，停止本地使用并在下次联网时尝试服务端撤销。

## 接口命名与升级

- Console 扫码接口：`GET /api/v1/auth/web-login/requests/{id}`，`POST /api/v1/auth/web-login/requests/{id}/approve`、`/deny`，归属应用认证。
- 原 `/api/v1/admin-login/requests/*` 接口已移除，二维码不再接受 `hako://admin-login`。服务端与 iOS 必须同步更新，并刷新网页二维码，不提供旧版兼容。
- `/api/v1/auth/*`、`/api/v1/sessions`、`/api/v1/web-sessions/{id}` 已是通用认证与会话命名，继续沿用。`Console` 是角色名称，配置字段、设备身份和长期凭据不因功能迁移而重建。
- `/admin/`、`/admin/api/*` 表示 Hako Web 管理控制台及其 Cookie/CSRF 接口，继续沿用；`/api/v1/agents/*` 和 `/ws/agent` 属于设备业务，详见 [设备监控协议](device-monitoring.md)。
- 主应用验证与登录只访问认证接口，设备列表仅由设备监控按需加载。

Console 会话仅支持查看与本机退出，不提供远程删除接口；`DELETE /api/v1/sessions/{id}` 已移除。退出或会话失效不会取消公钥信任，持有已登记私钥的设备可以重新登录；要禁用设备，应在配置文件中移除对应 Console 公钥并重启。网页 Agent 列表改为 `GET /admin/api/agents`，原 `/admin/api/overview` 已移除，不提供兼容路由。
