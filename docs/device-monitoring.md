# 设备监控协议 v1

单用户、多设备。Windows 为 Agent，iOS 为 Console，服务端为设备管理服务。三端各自实现协议，不共享代码包。

## 配置与身份

服务端 `config/server.json` 包含唯一 `username` 和手工登记的 `consoles` P-256 公钥，所有 Console 都是管理员。每次启动以文件更新 Console 信任，增删需重启。`agents` 仅用于首次导入，之后由数据库及 `/admin/` 管理页即时维护。Console 无密码、TOTP 或公开注册，私钥由 iPhone Secure Enclave 保存，只导出 SPKI PEM 公钥；Agent 使用 RSA，私钥由 Windows 保存。

所有外部通信使用 HTTPS/WSS。服务地址必须为根 origin；反向代理保持原路径。服务端使用配置的 `HAKO_PUBLIC_URL` 校验签名 URL，不信任客户端的 Host 或 X-Forwarded-* 构造签名目标。

## Web 管理

`/admin/` 只支持已登录 Console 扫码批准，没有管理密钥入口。网页 POST `/admin/api/login/requests` 创建 90 秒有效请求，获得 ID、确认码、到期时间和 `hako://admin-login?v=1&server=<origin>&request=<id>` 二维码。浏览器私有绑定凭据仅保存在 HttpOnly、SameSite=Strict 的 Cookie 中，不放入二维码。

Console 只接受当前 HTTPS 服务器的二维码，带现有 DPoP 会话 GET `/api/v1/admin-login/requests/{id}` 获取服务器、确认码、浏览器及 nonce。核对并进行本机身份验证后，POST 同一路径的 `/approve` 或 `/deny`，正文为 `confirmationCode`，DPoP 声明必须包含 nonce。签名绑定完整请求路径、方法、访问令牌和挑战，防止替换与重放。

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
| `GET /api/v1/sessions` | 查看已登录的管理设备 |
| `DELETE /api/v1/sessions/{id}` | 撤销指定会话 |
| `GET /api/v1/agents` | 返回 `agents` 数组：`id,name,platform,online,lastSeen` |
| `POST /api/v1/agents/{id}/metrics/query` | 同步等待设备本次采样，默认最多 10 秒 |

网络错误保留登录凭据；明确会话撤销后才进入重新登录流程。离线退出持久标记 `logoutPending`，停止本地使用并在下次联网时尝试服务端撤销。

## Agent WebSocket

端点 `/ws/agent`，JSON 文本消息，最大 64 KiB。建立连接后 10 秒内认证。

```json
{"type":"hello","version":1,"username":"owner","keyId":"公钥指纹"}
```

`keyId=base64url(SHA256(SPKI_DER))`。服务端查找预登记 RSA 公钥，返回 `{"type":"challenge","payload":"标准 Base64"}`。payload 以 `hako-agent-auth/v1\n` 开头，绑定 origin、账号、keyId 以及随机数；Windows 检查前缀绑定后，用 RSA-PSS/SHA-256（salt 长度 32 字节）对原始 payload 字节签名，返回：

```json
{"type":"authenticate","signature":"标准 Base64"}
```

成功返回 `type=authenticated,agentId,name`。身份验证失败以 WebSocket 1008 关闭。重复设备连接仅保留最新的已认证连接。服务端每 20 秒发送 `{"type":"ping"}`，Agent 返回 `{"type":"pong"}`；60 秒未收到有效消息断开。

查询消息：

```json
{"type":"request","id":"随机请求 ID","method":"system.metrics"}
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

失败返回 `type=response,id,error=sample_failed`，不伪造零值。服务端按当前设备连接和请求 ID 匹配，超时或旧连接响应不会作为新查询结果。每设备最多 4 个待处理查询，服务全局最多 32 个。

服务端把本次 `result` 作为 HTTP JSON 返回，离线返回 409、超时返回 504、采样失败返回 502。iOS 手动刷新，不持续轮询，不保存历史指标。

## 验证边界

Go 测试覆盖认证、重放、持久登录、轮换恢复、撤销及设备转发。Windows 检查覆盖真实指标和 DPAPI；可与 Go 服务端进行真实 C# Agent 联调。iOS 的 Secure Enclave、公钥导出、Keychain 和实际 UI 需要在 iPhone 上验收；Windows 环境跳过 iOS 编译、签名和安装。
