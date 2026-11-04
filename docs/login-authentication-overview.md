# Hako 登录与身份认证总览

本文面向使用者和接入应用的开发者，介绍 Hako 自身的登录、第三方使用 Hako 登录，以及 Hako 连接外部服务时的认证。协议字段见[服务器认证协议](server-authentication.md)，部署见[服务端 README](../apps/server/README.md)，OIDC 细节见[通用 OIDC](server-oidc.md)。

## 先区分三种关系

```mermaid
flowchart TD
    H[Hako 涉及的身份认证] --> S[访问 Hako 自身]
    H --> P[第三方应用使用 Hako 识别用户]
    H --> C[Hako 作为客户端连接外部服务]
    S --> S1[iOS Console：设备密钥 + DPoP]
    S --> S2[管理网页：手机明确批准 + 管理 Cookie]
    S --> S3[Agent：登记公钥 + RSA 挑战签名]
    P --> P1[Hako 自定义扫码协议]
    P --> P2[标准 OIDC Authorization Code Flow]
    C --> C1[Headplane / Arcane / 青龙 / GitHub / ECS]
```

Hako 服务端目前是**单账号、多个可信管理设备**。多个 Console 对应同一账号，不是多个独立用户。没有密码登录、公开注册、短信验证码或完整多用户权限管理。用户名用于账号配置与显示；对第三方的稳定身份使用数据库持久化的 subject，不使用设备 ID 或公钥指纹替代。

| 方式 | 谁在验证谁 | 登录后获得什么 | 权限范围 |
| --- | --- | --- | --- |
| Console 设备登录 | Hako 验证已登记 iPhone 设备密钥 | Console 会话、访问/刷新凭据 | Hako 管理员，可批准登录与管理设备 |
| Hako 管理网页登录 | 手机批准本次浏览器登录 | 独立管理 Cookie + CSRF | Hako Web 管理能力 |
| Agent 认证 | Hako 验证已登记 Agent 公钥 | 已认证 WebSocket 连接 | 该设备的能力上报、请求响应；不是 Console |
| 第三方自定义扫码 | Hako 验证应用凭据，再由 Console 批准用户 | 稳定身份，可选应用授权令牌 | 该客户端自己的身份授权；不是 Hako 管理权 |
| OIDC 登录 | Hako 验证客户端与手机批准；应用验证 Hako 签名 | ID Token、OIDC Access Token | 标准用户身份及允许的资料 |
| 外部服务凭据 | 对应外部服务验证 Hako 提供的凭据 | 对应服务的 API/会话能力 | 由外部服务自己的策略决定 |

## 一、iOS Console：设备密钥登录 Hako

适用于 Hako iOS 自身的管理身份。手机本地生成 P-256 密钥，私钥保留在 Secure Enclave，仅导出公钥。操作员将公钥登记到服务端 `config/server.json` 的 `consoles`；服务启动时以配置文件为准加载信任。

```mermaid
sequenceDiagram
    actor O as 操作员
    participant P as Hako iOS
    participant H as Hako 服务端
    O->>P: 查看并导出本机公钥
    O->>H: 登记 Console 公钥并重启
    P->>H: 设备 DPoP + username/deviceId 请求挑战
    H->>H: 检查公钥信任与请求签名
    H-->>P: 10 秒挑战与 nonce
    P->>H: 新 DPoP 绑定 nonce，主动登录
    H->>H: 消费单次挑战，建立 Console 会话
    H-->>P: sessionId + Access Token + Refresh Token
    P->>H: 后续请求携带设备 DPoP 和 Access Token
```

DPoP 把签名绑定请求方法、服务器 URL、时间、随机 jti；访问资源时还绑定访问令牌摘要。仅拿到访问令牌无法替代设备私钥。每个资源请求都检查会话和当前设备信任。

访问令牌 15 分钟有效；Console 刷新会话无固定或闲置时限，但可撤销。刷新使用轮换 ID 处理响应丢失，重用旧凭据的异常情况可导致会话撤销。

```mermaid
flowchart TD
    A[启动或返回前台] --> B[验证已保存 Console 会话]
    B -->|有效| C[继续使用]
    B -->|需刷新| D[设备 DPoP + Refresh Token + rotationId]
    D --> E[持久保存新凭据]
    D -->|相同轮换请求，响应曾丢失| F[使用相同 rotationId 恢复响应]
    B -->|网络失败| G[保留凭据，显示连接错误]
    B -->|明确已撤销| H[停止使用，等待用户主动登录]
    H --> I[主动登录仍须是已登记设备]
```

主动退出撤销当前 Console 会话，也使它批准的相关网页和应用授权不能继续使用。退出不会移除公钥信任：持有已登记私钥的设备仍可由用户主动重新登录。要禁用设备，须移除服务端公钥并重启；重置本机密钥也需要更新登记。其他 Console 不因某一台退出而失去信任。

## 二、Hako 管理网页：手机批准网页登录

适用于 `/admin/`、设备代理、访问日志及应用管理页面。管理网页本身没有密码入口，也不接收 Console 长期凭据。

```mermaid
sequenceDiagram
    actor U as 用户
    participant B as 管理浏览器
    participant H as Hako 服务端
    participant P as 已登录 Hako iOS
    B->>H: 创建 90 秒管理登录请求
    H-->>B: 二维码、确认码、私有绑定 Cookie
    U->>P: 扫描 v1 二维码或粘贴请求
    P->>H: 用 Console DPoP 读取请求
    H-->>P: 服务器、来源 IP、浏览器、确认码
    U->>P: 核对后点击确认登录
    P->>H: 带 nonce 的 DPoP 批准
    B->>H: 原浏览器 Cookie 轮询并领取
    H-->>B: 独立管理 Cookie + CSRF
```

扫描、读取请求或已存在管理员登录态都不等于批准。公开请求 ID、二维码和确认码都不能替代浏览器私有 Cookie。管理页 Cookie 使用 HttpOnly、SameSite=Strict，HTTPS 下使用 Secure 和 `__Host-`；写操作还检查同源和 CSRF。

管理网页闲置 30 分钟或登录 12 小时到期；状态轮询不续期。主动退出、单独移除网页会话、批准方 Console 退出/失效，以及服务重启都会使相应网页会话失效。手机「已登录设备」可单独移除网页，不会删除 Console 公钥。

## 三、Agent：设备代理认证，不是用户登录

Agent 运行在被管理设备上。先生成 RSA 密钥，把公钥登记到 Hako；私钥留在 Agent 所在设备。当前 Agent 使用 RSA-PSS/SHA-256 挑战响应建立可信 WebSocket。

```mermaid
sequenceDiagram
    participant A as 已登记 Agent
    participant H as Hako 服务端
    A->>H: WSS /ws/agent，hello v3
    Note over A,H: 携带账号、keyId 与能力清单
    H->>H: 查找已登记 Agent 公钥
    H-->>A: 绑定服务器、账号、keyId 的随机挑战
    A->>H: RSA-PSS/SHA-256 签名
    H->>H: 验签并再次检查设备信任
    H-->>A: authenticated
    H->>A: 转发管理员发起的能力请求
    A-->>H: 返回该设备执行结果
```

Agent 不取得 Console 会话，不能批准用户登录，也不能凭设备身份成为 Hako 管理员。移除 Agent 后立即断开现有连接并拒绝后续认证；这与退出用户网页登录是不同操作。

## 四、第三方应用接入 Hako：先登记客户端

自定义扫码和 OIDC 共用服务器上的应用登记，可从网页 `/admin/applications` 或 iOS「设置 → Hako 服务 → 第三方应用」管理。应用后端持有 Client ID 和随机 Client Secret；用户手机持有 Console 身份；两种身份不能相互替代。

```mermaid
flowchart TD
    A[管理员用手机批准进入 Hako 应用管理] --> B[创建应用：名称与登记来源]
    B --> C[生成 Client ID 与一次性显示的 Client Secret]
    C --> D{接入方式}
    D -->|自定义扫码| E[应用后端配置 Hako URL / ID / Secret]
    D -->|标准 OIDC| F[显式开启 OIDC]
    F --> G[登记精确回调 / scopes / PKCE / Secret 认证方式]
    G --> H[应用配置 Issuer / ID / Secret / 回调]
    H --> I[通过 Discovery 获取端点与 JWKS]
    C -. 后续管理 .-> J[轮换 Secret 或停用应用]
    J --> K[使该应用旧请求、授权码及访问授权失效]
```

Secret 只在创建或轮换时显示；列表和日志不返回原始值，不能“找回旧 Secret”。普通扫码应用不会自动获得 OIDC 能力。一个客户端的停用、轮换或配置变更不影响其他客户端。

## 五、第三方自定义扫码：为应用绑定或登录用户

适用于能实现 Hako 专用后端协议的应用，已有接口 `/api/v1/app-login/*` 保持兼容。应用后端以 Secret 认证创建请求，持有私有 redeemToken；二维码只包含公开请求 ID 和 Hako 服务器。

```mermaid
sequenceDiagram
    actor U as 用户
    participant B as 应用浏览器
    participant A as 第三方应用后端
    participant H as Hako 服务端
    participant P as Hako iOS
    B->>A: 绑定账号或使用 Hako 登录
    A->>H: Client ID + Secret，创建 bind/login 请求
    H-->>A: v2 二维码、确认码、私有 redeemToken
    A-->>B: 只展示公开二维码与确认码
    U->>P: 扫描二维码
    P->>H: Console DPoP 读取应用与用途
    U->>P: 核对并明确批准
    P->>H: 带 nonce 的 DPoP 批准
    A->>H: 应用凭据 + 私有 redeemToken 兑换
    H-->>A: issuer + 稳定 subject + username
    opt purpose=login
        H-->>A: 独立应用 sessionToken
        A-->>B: 应用建立自己的本地会话
        A->>H: 定期校验应用授权是否仍有效
    end
```

`bind` 仅返回身份，用于在应用中关联已有账号，不颁发 Hako 应用会话。`login` 额外颁发该客户端专属的 sessionToken，最长 12 小时、闲置 30 分钟；由应用加密保存在后端，不能当作管理 Cookie 或 Console Token 使用。

第三方应用按 `(issuer, subject)` 绑定用户，不能只凭用户名认人。应用需主动校验 Hako 授权并维护自己的本地登录有效性。应用自己的密码、API Key 或其他登录方式由它自行管理，不因为接入 Hako 就被替换。

## 六、标准 OIDC：让支持 OIDC 的应用使用 Hako 登录

OIDC 接口为 Discovery、Authorization、Token、UserInfo 和 JWKS。第一版实现 Authorization Code Flow、PKCE S256、`client_secret_basic` 和可配置的 `client_secret_post`。每客户端只接受登记的一种认证方式。

生产环境配置固定 HTTPS Issuer 和精确 HTTPS 回调。开发 HTTP 仅允许 HTTP loopback issuer 配合精确 loopback 回调；当前 iOS 仍要求 HTTPS。支持 `openid` 与 `profile`，不提供邮箱，也不把用户名拼成邮箱。

```mermaid
sequenceDiagram
    actor U as 用户
    participant B as 原浏览器或 WKWebView
    participant A as OIDC 应用后端
    participant H as Hako 服务端
    participant P as Hako iOS
    U->>A: 使用 Hako 登录
    A-->>B: 跳转授权地址：state / nonce / PKCE
    B->>H: 发起授权
    H->>H: 验证客户端、精确回调、scope 与 PKCE
    H-->>B: 授权页面 + 独立私有 Cookie
    alt 桌面
        U->>P: 扫描 v3 二维码
    else 手机同机
        U->>B: 点击在本机 Hako 中确认
        B->>P: 打开严格匹配的确认请求
    end
    P->>H: Console DPoP 读取真实应用详情
    P-->>U: 展示来源、身份信息与确认码
    U->>P: 明确批准或拒绝
    P->>H: 提交用户选择
    B->>H: 原 Cookie + CSRF 领取
    H-->>B: 跳转预登记回调，携带 code + state
    B->>A: 回到原应用
    A->>A: 校验 state
    A->>H: Secret + code + PKCE verifier
    H-->>A: ID Token + OIDC Access Token
    A->>H: 通过 JWKS 验签，使用 Access Token 请求 UserInfo
    H-->>A: 稳定 sub 与实际账号资料
    A-->>B: 建立应用自己的本地会话
```

同机确认后，由**原浏览器/WKWebView**继续领取；不会仅凭公开请求 ID 在另一个浏览器领取。内置浏览器只接受来自当前配置 Hako 服务器、对应授权请求页面的用户点击，且深链必须精确匹配，不泛化放行任意 scheme。批准仍在原生确认页由用户明确操作。

授权请求 90 秒有效；批准后授权码 60 秒、单次兑换；ID Token 与 Access Token 均为 5 分钟。ID Token 使用独立、持久化的 RSA/RS256 签名密钥，客户端通过 JWKS 验证签名与 iss/sub/aud/iat/exp/nonce。Access Token 只用于 Hako UserInfo，不能调用管理接口。

没有 Implicit、密码授权、动态注册、refresh token 或完整单点注销。Headplane v0.8.2 是首个兼容验证客户端；其接入、无邮箱用户关联与 Web SSH 前置条件见[独立示例](clients/headplane-oidc.md)。这些客户端条件不进入通用 OIDC 协议。

## 七、凭据不能混用

```mermaid
flowchart LR
    C[Console Token + 设备 DPoP] --> CA[Hako Console 管理接口与批准]
    W[管理 Cookie + CSRF] --> WA[Hako Web 管理接口]
    S[应用 Client ID + Secret] --> SA[应用自身认证 / 创建自定义请求 / OIDC 兑换]
    G[自定义应用 sessionToken + 应用凭据] --> GA[该客户端的 Hako 应用授权校验]
    O[OIDC Access Token] --> OA[Hako UserInfo]
    I[签名 ID Token] --> IA[OIDC 客户端验证用户身份]
    L[第三方本地 Cookie] --> LA[第三方自己的登录会话]
```

Client Secret 证明“这是登记的应用”，不能证明用户已经同意，也不赋予管理员权限。ID Token 是给相应客户端验证身份的凭证，不是 Hako 通用 API Token。Hako 管理 Cookie、自定义扫码会话和 OIDC Access Token 各有独立边界。

## 八、撤销、退出与重启

```mermaid
flowchart TD
    A[Console 会话退出、撤销或设备失去信任] --> W[相关 Hako 管理网页登录失效]
    A --> G[相关自定义扫码授权失效]
    A --> O[相关 OIDC 授权不能再兑换或访问 UserInfo]
    B[单独移除网页 / 应用授权] --> T[仅移除所选授权]
    C[应用停用、轮换 Secret 或变更配置] --> P[该客户端的旧请求与授权失效]
    R[Hako 服务重启] --> M[临时网页、扫码、OIDC 请求和授权失效]
    R --> K[稳定 subject、签名密钥与持久 Console 会话恢复]
    O -. 不等于立即删除 .-> I[已签发且尚未过期的离线 ID Token]
    O -. 不等于自动退出 .-> L[第三方应用自己的本地会话]
```

重启恢复的 Console 会话仍受当前公钥信任检查，已移除设备不会因恢复数据重新获得信任。签名密钥与 subject 应和加密数据库一起备份，masterKey 独立安全保管。只恢复部分数据、重新生成主密钥或删除数据库都可能破坏身份连续性。

手机「已登录设备」可查看 Console、管理网页登录、自定义应用授权和 OIDC 授权。当前不提供远程删除其他 Console 会话的常规入口；禁用设备应从信任配置入手。单独移除网页/应用授权不会删除设备公钥，也不会影响其他独立授权。

**Hako 授权撤销与第三方退出是两件事。** Hako 能拒绝后续兑换或授权校验，但无法远程删除第三方的 Cookie、数据库会话或已经缓存的身份结果。本版不提供完整单点注销。

## 九、Hako 连接外部服务时使用什么认证

这组功能中，Hako 是调用方；凭据由外部服务签发，不能用于登录 Hako 服务端。

| 功能 | 现有认证方式 | 与 Hako OIDC 的关系 |
| --- | --- | --- |
| 组网管理 / Headplane 原生管理功能 | 使用配置的 API Key 登录 Headplane，获得专用 Cookie；版本诊断可另外使用 info_secret | 原生 API Key 会话与 Web SSH 的 OIDC 浏览器会话隔离 |
| Headplane Web SSH | 内置浏览器中的 Headplane OIDC 登录会话 | 可选择 Hako 为 Issuer；仍要求 Headscale 用户关联、Agent、Tailscale SSH 和策略 |
| 容器管理 / Arcane | 配置 API Key，发送 `X-Api-Key` | 不自动改为 Hako OIDC |
| 青龙面板 | 配置青龙 Client ID/Secret，换取青龙访问 Token | 与 Hako 应用 Client ID/Secret 不同 |
| GitHub 数据/构建等能力 | 主应用配置 GitHub Token，以 Bearer 调用 GitHub | 权限与有效期由 GitHub Token 决定 |
| 阿里云 ECS | AccessKey ID/Secret 签名请求，可带 STS SecurityToken | 由阿里云 RAM/STS 权限约束 |

```mermaid
flowchart TD
    H[Hako iOS] --> HP[Headplane 原生 API Key 登录与 Cookie]
    H --> BR[独立浏览器的 Headplane OIDC 会话]
    BR --> OP[Hako 或其他配置的 OIDC Provider]
    H --> AR[Arcane API Key]
    H --> QL[青龙 Client ID/Secret 换 Token]
    H --> GH[GitHub Token]
    H --> ECS[ECS AccessKey / STS 签名]
```

凭据由各自服务适配器管理，子应用不读取其他服务的秘密。更改 Hako Console 登录不会自动替换这些外部凭据；清除某个子应用连接也不等于在外部服务撤销其原始 API Key。

## 当前验证状态与使用建议

- 自身 Console、管理网页登录、Agent 和自定义扫码沿用已有机制，并有服务端回归覆盖。
- OIDC 已实现通用端点、客户端配置、明确手机批准、独立签名与 UserInfo，以及生命周期和隔离测试；独立 go-oidc/OAuth2 客户端及 Headplane v0.8.2 官方认证模块均已通过协议互操作测试。
- 新版 iOS 已完成本机后台编译、开发签名和 IPA 打包；本次没有在线设备安装/启动结果。
- 实体手机桌面/同机批准、真实 Headplane UI 登录、无邮箱时手动关联已有 Headscale 用户，以及 Web SSH 连接仍需真实实例验收。模拟批准、签名检查或构建成功不能替代这些结果。

新接入的通用应用优先使用 OIDC。需要沿用已有专用协议或明确区分绑定/登录用途的应用，可继续使用自定义扫码。部署与操作细节分别查阅[服务器认证协议](server-authentication.md)、[OIDC 说明](server-oidc.md)和 [Headplane 示例](clients/headplane-oidc.md)。
