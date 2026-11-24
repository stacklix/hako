# Hako 服务器认证协议

使用者入口与各方式流程图见[登录与身份认证总览](login-authentication-overview.md)。

Hako 统一后端为主应用和子应用提供服务。服务器配置、设备身份、Console 登录、登录会话和扫码批准属于主应用；设备监控复用这些能力。iOS 入口为「设置 → 扫码登录」及「设置 → 服务器与登录」，均以 sheet 打开，无需先进入设备监控。服务器配置在点击 sheet 右上角勾号时保存，关闭有修改的配置会提示放弃；扫码 sheet 仅提供关闭按钮，批准仍需核对后明确确认。Console 表示可信管理客户端角色。

## 版本兼容性

`GET /api/v1/version` 无需登录，返回当前服务端版本和两类客户端各自的最低版本。

```json
{"serverVersion":"0.1.3","minimumIosVersion":"0.1.0","minimumAgentVersion":"1.0.0"}
```

版本使用 `主版本.次版本.补丁版本` 三段非负整数。最低版本的前两段指定兼容版本线。实际版本的前两段必须与之相同，第三段按数值比较且须达到最低要求。比如要求 `0.1.2` 时，`0.1.10` 兼容，`0.1.1`、`0.2.0` 和 `1.1.0` 均不兼容。升级中间段时，应同步更新对端所要求的版本线。

服务端、iOS 和 Windows Agent 每次发布、部署或安装有内容变化的新版，均递增各自发布版本的第三段（补丁版本），包括纯界面和内部实现改动；不以构建号或提交哈希代替发布版本递增。同一已验证产物的重试复用原版本。三端独立递增实际变更并交付的组件，不要求无关组件同步升级。

iOS 使用应用的营销版本，Agent 使用程序集版本。版本入口及交付规则见[协作规范](../AGENTS.md#三端版本兼容性)。当前兼容要求以服务端 `apps/server/internal/server/version.go` 和客户端声明为准；接口契约发生变化时维护对应最低版本。不兼容变更递增第二段并将第三段归零，普通补丁递增不自动提高对端最低版本。

iOS 在启动、回到前台或更换服务器地址时检查。Agent 在连接与自动重连时检查。每端同时比较自身版本与服务端要求，以及服务端版本与自身要求。任一方向不满足、接口返回 404 或 405、或版本响应无法解析时，客户端弹框提示，原有连接流程继续。网络异常和其他 HTTP 错误沿用现有连接处理。

## 配置与身份

服务端 `config/server.json` 包含唯一 `username` 和手工登记的 `consoles` P-256 公钥，所有 Console 都是管理员。每次启动以文件更新 Console 信任，增删需重启。`agents` 仅用于首次导入，之后由数据库、`/consilium/` 管理页及已登录 iOS Console 即时维护。Console 无密码、TOTP 或公开注册，私钥由 iPhone Secure Enclave 保存，只导出 SPKI PEM 公钥；Agent 使用 RSA，私钥由 Agent 所在设备保存。

Console 设备身份可在未配置服务器、未联网、未登录时本地生成并单独导出公钥，立即持久保存，后续新服务器沿用该身份。旧版本已有的服务器密钥绑定继续保留，首次读取时可作为本机默认身份；重复导出不重新生成密钥，登录会话仍按服务器和账号隔离。

iOS 可通过红色「重置密钥对」并二次确认替换本机身份。新密钥和重置标记先原子写入 Keychain，再清理旧身份与本机会话；旧绑定不会因清理中断而恢复。恢复会话时再次校验凭据中的设备 ID 与当前公钥匹配。离线重置不修改服务端信任，操作员需替换服务端旧公钥并重启，清理旧 Console 和关联网页会话。

所有外部通信使用 HTTPS/WSS。服务地址必须为根 origin；反向代理保持原路径。服务端使用配置的 `HAKO_PUBLIC_URL` 校验签名 URL，不信任客户端的 Host 或 X-Forwarded-* 构造签名目标。

## Web 管理

`/consilium/` 只支持已登录 Console 扫码批准，没有管理密钥入口。网页 POST `/consilium/api/login/requests` 创建 90 秒有效请求，获得 ID、确认码、到期时间和 `hako://web-login?v=1&server=<origin>&request=<id>` 二维码。浏览器私有绑定凭据仅保存在 HttpOnly、SameSite=Strict 的 Cookie 中，不放入二维码。

Console 只接受当前 HTTPS 服务器的二维码或手动粘贴的登录请求，带现有 DPoP 会话 GET `/api/v1/auth/web-login/requests/{id}` 获取服务器、确认码、浏览器、`clientIP` 及 nonce。`clientIP` 是创建二维码的浏览器访问来源（IPv4/IPv6），确认页显示「来源 IP」；不是扫码手机的 IP 或浏览器的局域网地址。默认取连接地址，仅对 `HAKO_TRUSTED_PROXIES` 配置的可信代理按 `X-Forwarded-For` 从右向左解析，取首个不可信地址。该字段不出现在二维码、创建响应或网页轮询中。浏览器名由 User-Agent 提示，用于会话列表，支持桌面与 iOS 的 Chrome/Firefox/Edge 标识。核对确认页并点击确认或拒绝后，POST 同一路径的 `/approve` 或 `/deny`，正文为 `confirmationCode`，DPoP 声明必须包含 nonce。确认登录不再额外要求 Face ID、Touch ID 或设备密码。签名绑定完整请求路径、方法、访问令牌和挑战，防止替换与重放。

网页 GET `/consilium/api/login/requests/{id}` 轮询 pending/scanned/approved/denied，仅原浏览器可读取；批准后由原浏览器 POST `/complete` 领取一次性会话。扫码和 GET 轮询不颁发会话；重复批准、领取、过期或被刷新替换的请求均拒绝。二维码不携带 Console 令牌或私钥。

网页会话使用独立 Cookie 与 CSRF，HTTPS 启用 Secure 与 `__Host-`；修改请求验证 origin。闲置 30 分钟、登录 12 小时或服务重启后过期，轮询不续期。每次访问还检查批准它的 Console 会话有效，Console 退出或撤销使关联网页会话失效。

`/consilium/api/` 保留 `session`、`logout`、`agents` 资源及通用能力调用；网页展示 Agent、访问日志及第三方应用，不展示管理客户端列表、数量、公钥或 Console 登录会话，`GET /consilium/api/agents` 只返回 `agents,updatedAt`，不返回账号、`consoles` 或手机会话列表，账号由 `/consilium/api/session` 返回；网页不能撤销手机会话，服务端不提供 `DELETE /consilium/api/sessions/{id}` 路由。Console 会话管理仅接受 Console 的 DPoP 认证；Console 公钥只能在服务端配置文件修改。Agent 删除立即断开连接，完成挑战后的设备也会在注册在线前再次检查信任。手工移除 Console 并重启会清理其会话和登录挑战，重新添加不恢复旧会话。部署见 [服务端说明](../apps/server/README.md)。

## 第三方应用扫码登录

可信管理员登录 `/consilium/applications` 创建应用，填写名称与实际应用根地址（HTTPS 或局域网 HTTP）。服务器自动生成唯一应用 ID 和随机 32 字节 Base64url SK，仅创建 / 轮换响应返回原始 SK 和可复制的 `HAKO_URL / HAKO_CLIENT_ID / HAKO_CLIENT_SECRET` 配置。应用记录、启用状态和 `base64url(SHA256(SK))`（无填充）持久保存在现有加密数据库，不使用 `server.json` 管理应用，不保存原始 SK；重启不丢失。

管理接口为 `GET/POST /consilium/api/applications`、`PATCH /consilium/api/applications/{id}`（正文 `enabled`）、`POST /consilium/api/applications/{id}/rotate`（正文 `{}`），全部要求原生 Hako 管理 Cookie，写请求还要求 CSRF 和同源。列表仅返回 `id,name,origin,enabled,createdAt`，不返回 SK 或其哈希。最多 64 个应用。停用 / 轮换立即清除该应用的待授权请求及授权会话；每次请求和授权还绑定创建时的密钥哈希，防止并发轮换恢复旧授权。重新启用不恢复旧授权。轮换后应用更新 SK 并重启；SK 遗失只能轮换，不能查看旧值。

应用后端使用 HTTPS，携带 `Authorization: Bearer <clientSecret>` 和 `X-Hako-Client: <id>`。服务端常量时间校验密钥摘要，按客户端隔离请求和授权会话；带浏览器 Origin / Sec-Fetch-Site 的调用拒绝。应用凭证不能调用 Console 批准接口，不能获得 Hako 管理后台会话。禁止将应用密钥、私有兑换凭据或手机令牌放入二维码。

| 应用后端接口 | 用途 |
| --- | --- |
| `POST /api/v1/app-login/requests` | 正文 `purpose`（`bind` / `login`）、`userAgent`、`clientIP`，创建 90 秒请求 |
| `GET /api/v1/app-login/requests/{id}` | 查询 pending / scanned / approved / denied |
| `DELETE /api/v1/app-login/requests/{id}` | 取消请求 |
| `POST /api/v1/app-login/requests/{id}/complete` | 正文 `{}`，一次性兑换身份和登录授权 |
| `GET /api/v1/app-login/session` | 校验当前应用授权，并更新其活动时间 |
| `DELETE /api/v1/app-login/session` | 应用退出时撤销当前授权 |

创建响应为 `id,redeemToken,confirmationCode,qrPayload,expiresAt,pollIntervalMs`。后续请求操作还必须携带 `X-Hako-Request: <redeemToken>`；这个私有凭据只留在应用后端，公开请求 ID 不可替代。二维码采用 `hako://web-login?v=2&server=<Hako origin>&request=<id>`。v1 继续用于 Hako 自身后台；旧手机端拒绝 v2，防止未展示应用详情就批准。

手机继续使用 `/api/v1/auth/web-login/requests/{id}` 与带 nonce 的 DPoP 批准 / 拒绝。第三方详情额外包含 `application,applicationOrigin,purpose`，均取服务端登记或已验证请求；来源 IP 由应用后端报告，手机明确标注这一点。手机校验 v2 必须含有效应用地址（HTTPS 或局域网 HTTP）及用途，并显示应用、地址、绑定或登录操作和六位确认码。Hako 后台的浏览器 Cookie 接口不能领取第三方请求。

兑换响应含 `issuer,subject,username,clientId,purpose`。`subject` 是加密数据库内持久化的随机账号 ID，用户名变化和 Console 换钥均不改变它；应用必须按 `(issuer,subject)` 绑定已有账号，不按用户名匹配。`bind` 不颁发会话；`login` 额外返回 `sessionToken,expiresAt`。应用将 sessionToken 加密保存在后端，校验 / 退出时通过 `X-Hako-Session` 携带，不可作为 Hako admin Cookie 使用。批准方退出 / 撤销、应用移除和 Hako 重启使授权失效。最长 12 小时、闲置 30 分钟；应用需定期校验并在失败时停止使用授权。

Console 的会话列表新增 `type=application`，含 `application,origin,browser,createdAt,lastUsedAt` 和独立会话管理 ID，不返回 sessionToken。使用现有 `DELETE /api/v1/web-sessions/{id}` 可单独撤销，手机也提供移除操作。应用自行签发本地 Cookie，必须将其有效性与该授权关联；iLinker 至多缓存成功校验 60 秒，密码登录独立保留。配置示例和密钥生成步骤见 iLinker README 的 Hako 接入说明。

## 原生子应用自动鉴权

原生子应用使用已登录 Console 的 DPoP 会话申请短期授权码，应用后端使用已有应用 ID/Secret 和 PKCE 兑换同一 `(issuer,subject)` 身份。此接口只负责通用认证；Cerno 等业务 API 由 iOS 直接连接独立 HTTPS 后端，不经 Sora 聚合、代理或 Agent 转发。网页 v2 扫码请求与确认流程不变，原生请求不能进入网页批准路径，网页请求也不能通过原生接口自动批准。

手机先生成随机 PKCE verifier，只把其 SHA-256 Base64url challenge 发送到目标应用后端。后端建立自身登录上下文、保存 challenge，再创建以下请求；`redeemToken` 必须仅保存在后端，不能返回手机、写入日志或进入 URL。原生子应用不能持有应用 Secret、Hako 应用 sessionToken 或 Console 私钥/令牌的副本；Console 身份继续由主应用安全存储管理。

| 接口 | 认证、请求与响应 |
| --- | --- |
| `POST /api/v1/app-login/native/requests` | 应用后端使用 `Authorization: Bearer <clientSecret>`、`X-Hako-Client`；正文 `codeChallenge,codeChallengeMethod:"S256"`，可选 `userAgent,clientIP`。201 返回 `id,redeemToken,issuer,clientId,application,applicationOrigin,nonce,codeChallenge,codeChallengeMethod,expiresAt`，请求有效 90 秒 |
| `GET /api/v1/auth/native-app/requests/{id}` | 可信 Console DPoP；返回相同公开绑定字段，不含 `redeemToken` |
| `POST /api/v1/auth/native-app/requests/{id}/authorize` | 可信 Console DPoP；正文 `nonce,consent`。默认 `consent:false`，没有有效原生授权时返回 409 `native_consent_required`。首次明确同意后才发 `consent:true`。成功返回 `code,expiresAt`，码最多有效 60 秒且不超过原请求期限 |
| `POST /api/v1/app-login/native/requests/{id}/complete` | 应用后端认证加 `X-Hako-Request: <redeemToken>`；正文 `code,codeVerifier`。一次兑换返回 `issuer,subject,username,clientId,purpose:"login",sessionToken,expiresAt` |

应用后端给手机的 native/start 响应只包含自身 `loginId` 及 Hako 公开绑定字段，不能包含 `redeemToken`。后续完成请求必须验证该 `loginId` 对应的 challenge、原始上下文与有效期，再向 Hako 兑换；不能将任意手机提供的请求 ID 或地址直接当作可信兑换目标。手机共享授权服务独立向当前 Hako 服务器获取真实详情，核对预期应用 ID、当前 issuer、配置的 HTTPS 后端 origin、nonce、有效期和自身 PKCE challenge，绑定不符立即拒绝。

iOS 的 `NativeApplicationAuthorization` 注入 `AuthenticatedServerAccess`，签名、登录态和密钥仍由主应用管理。遇到 `consent_required` 向调用方返回经过核验的 `NativeApplicationConsent`，调用方呈现通用 `NativeApplicationConsentSheet`；只有用户明确确认时调用 `confirm`，不能自动重试为 `consent:true`。前后台账号、服务器或会话变化后，未完成请求及旧确认内容被丢弃。授权响应正文不进入 Console HTTP 日志；应用后端自身的兑换请求/响应及原生会话也必须脱敏。

兑换出的 Hako 应用授权只在后端保存；后端签发自己的原生设备会话，并通过已有 `GET /api/v1/app-login/session` 校验其有效性，退出用同路径 DELETE。Hako 授权最长 12 小时、闲置 30 分钟，原生设备会话不能绕过该授权独立长期有效。网络故障不等于撤销，但后台无法确认授权时应拒绝受保护操作。

原生静默同意绑定批准它的 Console 会话、设备和应用密钥版本，与网页授权分开。自然过期后可以在有效原生同意下重新换取授权；「已登录设备」单独显示 `type=application`、`browser=Hako iOS 自动登录授权` 的授权组，即使授权码未兑换或后端会话已过期，该组仍可见并可撤销，组内原生会话不重复展示。移除该授权组（`DELETE /api/v1/web-sessions/{consentId}`），或后端 DELETE 其中一个原生会话时，同时撤销该 Console 对该应用的静默同意、待兑换授权码和同组原生兄弟会话，不能静默重新建立。该操作不会清除同应用独立的网页扫码会话，也不会影响其他 Console 的原生授权。Console 退出/失去信任、应用停用/移除/换钥及 Hako 重启使相关原生授权失效；重启后首次登录需要重新明确同意。

其他错误：400 `invalid_native_request`、`invalid_native_nonce` 或 `invalid_native_grant`；401 认证失效；404 `native_request_not_found`（包括跨应用或缺少后台私有凭据）；409 `native_request_finished`；410 `native_request_expired`；429 限流或容量上限。授权码、verifier、兑换和原生会话均不能作为 Hako 管理后台或其他应用凭据使用。

## iOS Console 第三方应用管理

原生入口为「设置 → Hako 服务 → 第三方应用」。与 Web 管理页共用应用记录、Secret 哈希及 OIDC 配置；不会在手机建立另一份独立登记表。登记默认支持自定义扫码登录，OIDC 仍须明确开启。

| 原生 Console 接口 | 用途 |
| --- | --- |
| `GET /api/v1/applications` | 返回 `applications,issuer`，不返回 Secret 或哈希 |
| `POST /api/v1/applications` | `name,origin` 和可选完整 `oidc`；返回应用与仅此一次的 Secret |
| `PATCH /api/v1/applications/{id}` | 修改 `enabled` 或完整 `oidc` 配置 |
| `DELETE /api/v1/applications/{id}` | JSON `{}`，移除应用登记并使该应用的待授权请求、授权码及 Hako 访问授权失效；已移除时仍返回 `{"ok":true}` |
| `POST /api/v1/applications/{id}/rotate` | JSON `{}`，轮换 Secret，返回新的一次性凭据 |

全部要求当前可信 Console 会话、`X-Hako-Device` 及绑定路径/方法/令牌的 DPoP，每次消耗防重放 jti；写请求要求 JSON，按 Console 会话限制每分钟 30 次。带浏览器 Origin/Sec-Fetch-Site 的调用被拒绝。管理 Cookie、第三方 Secret、扫码 sessionToken 和 OIDC Access Token 均不能认证这些接口。Web 原有 `/consilium/api/applications` 的 Cookie/CSRF 边界保持不变。

原生与网页复用同一管理逻辑，停用、轮换和 OIDC 配置变更执行相同的授权失效操作。iOS 仅在创建/轮换响应后展示 Secret，内存结果绑定发起请求的服务器、账号及会话；切换上下文后丢弃旧响应并关闭凭据页，不持久化原始 Secret。网络失败不自动重试写入，先刷新核对；响应遗失且 Secret 不可恢复时由用户明确轮换。

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
- Hako Web 管理控制台及其 Cookie/CSRF 接口现位于 `/consilium/`、`/consilium/api/*`；旧 `/admin` 命名空间返回 404，不提供跳转。`/api/v1/agents/*` 和 `/ws/agent` 属于设备业务，详见 [设备监控协议](device-monitoring.md)。
- 主应用验证与登录只访问认证接口，设备列表仅由设备监控按需加载。

Console 会话仅支持查看与本机退出，不提供远程删除接口；`DELETE /api/v1/sessions/{id}` 已移除。退出或会话失效不会取消公钥信任，持有已登记私钥的设备可以重新登录；要禁用设备，应在配置文件中移除对应 Console 公钥并重启。网页 Agent 列表改为 `GET /consilium/api/agents`，原 `/admin/api/overview` 已移除，不提供兼容路由。

局域网 iLinker 可登记 `http://192.168.0.2:8001`（含端口）。HTTP 应用地址支持私有 IPv4、IPv6 ULA、回环、链路本地地址、localhost / .localhost 和 .local 主机；公网应用仍使用 HTTPS，地址不带路径、查询或片段。手机端需同步更新地址校验。该地址仅用于手机确认展示，Hako 不请求该地址；应用 SK 和手机认证仍发送到 HTTPS Hako 服务。

## 通用 OIDC Provider

iOS 通知入口是通用「通知」页，登录请求为其中一个分组。单条左滑清除及确认后的「清除全部」仅在本机隐藏消息，按服务器、账号和请求原始到期时间记录；不调用批准、拒绝或取消接口，其他设备与原浏览器流程不受影响。关闭确认 Sheet 不清除通知。读取静默进行，失败保留未过期的旧内容，无加载动画；详情见 [通知与登录请求](server-oidc.md#手机登录请求通知)。

Hako 首页设置按钮左侧提供通知入口，前台通过 `GET /api/v1/auth/login-prompts/stream` WebSocket 接收服务端推送的全部待处理管理网页登录、第三方扫码和 OIDC 请求，不自动弹窗。点击列表条目才打开原生确认 Sheet；接口要求可信 Console DPoP，不返回确认码。用户输入原浏览器六位数字后通过同级 `/{id}/approve` 提交确认码与 nonce 签名，拒绝走 `/{id}/deny`，五次输错拒绝该请求。查询和打开 Sheet 不批准、不领取；各类型继续使用原浏览器 Cookie 或客户端私有领取凭据。旧 OIDC 通知接口保持兼容。具体范围见 [登录请求通知](server-oidc.md#手机登录请求通知)。

OIDC 在现有应用管理、稳定 subject 与 Console 手机批准基础上，增加独立 `/oidc/` 协议接口和凭据命名空间。仅显式启用并登记回调/scope/认证方式的应用可使用。v3 二维码/深链用于 OIDC，手机详情增加 `purpose=oidc` 和空格分隔的 `scopes`；v1 管理登录、v2 自定义扫码及其接口保持兼容。扫码和已有管理员会话都不能替代明确批准。

OIDC 浏览器绑定 Cookie 与管理 Cookie 分离，使用 HttpOnly、HTTPS Secure、`__Host-` 及 SameSite=Lax；完成请求校验原浏览器与 CSRF。授权码短时单次兑换，Token/UserInfo 不接受 Console 或扫码凭据。Console 会话列表继续用 `type=application` 展示 OIDC 待兑换授权及访问授权，复用按管理 ID 撤销接口。

OIDC 请求 90 秒、码 60 秒、ID Token 和 Access Token 5 分钟。临时授权重启失效，签名私钥与 subject 在现有加密 SQLite 内独立持久化。撤销阻止后续码兑换/UserInfo；已签发离线 ID Token 与客户端本地会话不会因此立即清除。没有 refresh token 或完整单点注销。

通用协议、严格参数支持范围、客户端管理、HTTP loopback 限制、备份/密钥策略见 [OIDC 说明](server-oidc.md)，客户端示例见 [Headplane v0.8.2](clients/headplane-oidc.md)。
