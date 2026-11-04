# Headplane v0.8.2 接入 Hako

本示例独立于 Hako 通用 OIDC 实现。其他应用使用同一协议，不需要 Headplane/SSH 专用身份、权限或 claims。

## 配置

先按[通用 OIDC 配置](../server-oidc.md)部署 Hako、登记 Console、创建应用并启用 OIDC。假设 Headplane 公开地址为 `https://headplane.example.com`，在 Hako 登记唯一回调：

```text
https://headplane.example.com/admin/oidc/callback
```

Hako 应用允许 `openid profile`、要求 PKCE S256，认证方式选 `client_secret_basic`。Headplane v0.8.2 的相关配置为：

```yaml
server:
  base_url: "https://headplane.example.com"
  cookie_secure: true
  # cookie_secret 仍按 Headplane 自身要求独立配置
headscale:
  url: "http://headscale:8080"
  api_key: "<已有 Headscale API key>"
oidc:
  enabled: true
  issuer: "https://hako.example.com"
  client_id: "<Hako 应用 Client ID>"
  client_secret: "<创建或轮换时保存的 Secret>"
  token_endpoint_auth_method: "client_secret_basic"
  scope: "openid profile"
  use_pkce: true
  use_end_session: false
```

上述为相关字段片段，合并到已有有效配置，保留 Headplane 的持久数据目录、Cookie Secret 等配置。Secret 也可使用官方 `client_secret_path` 从部署秘密文件读取。不要将 Hako masterKey、Console 密钥或登录令牌提供给 Headplane。

显式覆盖默认 scope 很重要：Hako 没有邮箱，拒绝 `email` scope，不会把用户名拼成邮箱。不要配置需要邮箱的域名筛选或虚构 `email_verified`。Hako 未实现注销端点，因此保留 `use_end_session:false`。

这些字段、回调结构及客户端行为已对照 [v0.8.2 官方配置](https://github.com/tale/headplane/blob/v0.8.2/config.example.yaml)和[官方 OIDC 模块](https://github.com/tale/headplane/blob/v0.8.2/app/server/oidc/provider.ts)核对。

## 登录与 Headscale 关联

用户点击 Headplane 的 OIDC 登录，跳转 Hako 后，桌面扫描二维码；同机浏览器点击「在本机 Hako 中确认」。iOS 读取并显示应用、登记来源、申请身份信息及确认码。用户明确批准后，原浏览器自动返回 Headplane；无脚本时点击继续。

Hako 返回稳定 sub，以及当前账号实际名称。Headplane 的权限与会话由它自身管理，不能将 OIDC 客户端身份等同于 Hako 管理员。Headplane 首次账号引导与后续角色分配也属于客户端策略，Hako 不签发特定 Headplane 角色。

根据 [v0.8.2 官方 SSO 说明](https://github.com/tale/headplane/blob/v0.8.2/docs/features/sso.md)，Headplane 优先按 subject 关联 Headscale 用户，其次可按邮箱；本接入不提供邮箱。对于本地创建、无 OIDC provider_id 的 Headscale 用户，客户端引导支持手动选择已有用户并持久化关联。**此路径已核对官方代码/文档，但本次没有在真实 Headplane + Headscale 实例中完成手动关联验收。** 不应通过伪造邮箱或在 Hako 内硬编码 Headscale 用户来绕过关联。

## 官方客户端模块互操作测试

除独立 go-oidc/OAuth2 客户端外，仓库提供可选测试，执行 Headplane v0.8.2 原始 `createOidcService`：

```powershell
# 从仓库根目录执行；需要 Node 24 和 Go 1.26+
node apps/server/tests/prepare-headplane-oidc.mjs build/oidc-validation/headplane-runtime
npm install --prefix build/oidc-validation/headplane-runtime --ignore-scripts --no-audit --no-fund jose@6.2.12
$env:HAKO_HEADPLANE_RUNNER = "$PWD/build/oidc-validation/headplane-runtime/runner.mjs"
Set-Location apps/server
go test ./internal/server -run TestOIDCHeadplane082OfficialProvider -v
```

准备脚本校验官方源文件 SHA-256：`b8fda14d0f71a995d68907ed5b5eceec1e506916986d99737fa19accd79d3b62`。只替换客户端宿主的结果/日志适配器与构建时 `/admin` 前缀，并移除 TypeScript 类型；Discovery、PKCE、Token 兑换、JWT 验证、nonce/state 与 UserInfo 处理逻辑保持官方原样。使用官方相同的 `jose@6.2.12`，测试信任单独生成的本机 TLS 测试 CA，不关闭 TLS 验证。

未设置环境变量时此项明确跳过；普通 `go test ./...` 不自动下载或运行第三方源码。本次已实际通过 basic 和 post 两种配置，均取得稳定 subject、真实账号名且没有邮箱。这里的手机批准使用测试 Console 签名模拟，**不等于完整 Headplane UI 或实体手机登录成功**。

## Web SSH 后续验收

先完成真实 OIDC 登录和 Headscale 用户关联，再在具备下列条件的实例验证 Web SSH：Headplane Agent 正常、目标节点在线并开启 Tailscale SSH、访问策略允许该已关联用户、目标 SSH 账号有效。这些条件不属于 Hako OIDC 协议。

iOS 组网管理中的内置浏览器保留独立 Cookie。仅当来源为当前配置 Hako 服务器的对应 `/oidc/requests/{id}` 页、主框架用户点击、v3 深链结构与请求一致时，打开原生确认 sheet；批准后由原 WKWebView 领取并完成回调，不另开浏览器搬运 Cookie。Safari 同机路径使用已注册的 Hako scheme，同样要求严格结构与服务器匹配。两者仍需真机验收。

本次尚未完成生产实例登录、手动关联、Web SSH 连接或实体手机安装/启动验收。撤销 Hako 授权只阻止后续码兑换及 UserInfo 使用，不会立即销毁 Headplane 自己建立的本地会话；当前没有完整单点注销。
