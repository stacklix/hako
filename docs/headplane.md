# 组网管理（Headplane）

Hako 首页的「组网管理」通过 Headplane 管理 Headscale。界面沿用移动原型的黑白灰配色、下划线标签、紧凑设备列表和弹层，支持深色模式。没有预填演示设备。

## 连接

右上角滑杆按钮 → 填写实例名称、Headplane 管理地址及 Headscale API Key → 验证并保存。示例地址为 `https://headplane.example.com/admin`；反向代理使用其他前缀时填写实际管理前缀。仅填写域名会补上 `/admin`。

管理操作要求服务器启用 Headplane 的 API Key 登录。客户端将 Key 提交到 Headplane 的登录表单，取得会话 Cookie，随后访问同一 Headplane 的 loader/action。它不会直接请求 Headscale。SSH 终端单独使用官方 Web SSH 页面与 OIDC 登录，不复用管理操作的 API Key 会话。

连接验证成功后才替换本机配置。凭据使用独立 Keychain 命名空间 `me.stackli.hako.headplane`，仅解锁时可读、仅限本机；会话 Cookie 只保存在内存中。默认要求 HTTPS，HTTP 需主动开启。不会自动跟随重定向或将凭据写入日志。

可选填写「版本查询密钥」，值对应 Headplane 服务端的 `server.info_secret`，与 API Key 分开使用；它随连接加密保存在同一 Keychain 命名空间。旧版本保存的连接无需迁移。仅 `/api/info` 使用此密钥作为 Bearer Token，不会发送给登录、健康检查或管理页面接口；未填写时不会用 API Key 代替。

## 当前功能

| 页面 | 功能 |
| --- | --- |
| 设备 | 在线/离线/过期统计，按名称、IP、标签和用户搜索，详情、重命名、修改标签、过期、删除 |
| 网络 | 查看子网路由和出口节点，确认批准/撤销；DNS、MagicDNS、分流 DNS 和自定义记录只读查看 |
| 访问控制 | 查看 ACL、用户组及标签所有者，保留注释的 HuJSON 原文编辑、修改预览和保存前远端冲突检查 |
| 更多 | Headscale 用户及所属设备只读查看，接入密钥列表/创建/过期，Headplane Agent 状态，连接设置 |

「更多 → 服务器状态与能力」和连接设置中的同名入口提供只读诊断：

- 健康检查：读取管理前缀下的 `/healthz`。HTTP 200 的 `OK` 表示检查通过，HTTP 500 的 `ERROR` 表示 Headplane 已响应但 Headscale 健康检查异常。网络错误、HTML、重定向或未知响应显示检查失败/状态未知，不作为健康结果。
- 版本信息：通过独立 Bearer 密钥读取 `/api/info`，展示 Headplane、Headscale 版本及可折叠的运行环境版本。401/403 提示检查 `server.info_secret`，不会触发 API Key 重新登录；Headscale 不健康时版本可能为未知。
- 配置能力：读取 `/settings.data` 的 `routes/settings/overview` 和 `layout/app`，分别显示 Headscale 配置是否可写、是否有 Headscale OIDC 配置，以及配置是否可读和当前账号的查看权限。配置可写不代表账号有写权限，Headscale OIDC 配置也不等于 Headplane OIDC 登录已启用。

各项独立加载，版本密钥缺失不阻断健康和配置检查。检查失败会清除对应旧结果，连接切换后丢弃旧请求；诊断始终使用已保存的连接，设置草稿需先验证保存。

设备与网络页仅在前台且未打开弹层时每 20 秒读取设备。手动刷新可在失败后重试，错误保留已有数据。服务端返回的权限控制编辑入口。后台未配置或不提供 DNS/Agent 时明确显示读取错误。

设备详情独立请求 `GET /machines/:id.data?_routes=routes/machines/machine`（相对管理前缀），按设备编号缓存，不再使用设备列表作为详情数据源。展示系统主机名、注册时间、节点公钥、MagicDNS 域名、公布及批准路由；Agent 部分展示最近同步时间、同步设备数、Agent 节点标识、系统及客户端版本、发行版、硬件架构、网络端点、DERP 区域编号与 NAT/IPv6/UDP/UPnP/PCP/NAT-PMP 信息。仅展示接口提供的可选信息，连接探测缺失显示「未提供」，不当作「否」；Agent 数据是最近采集结果，不表示实时探测。

打开详情和手动刷新均读取独立接口。重命名、标签、过期及路由变更后，已读取过的详情自动失效并回查；删除或 403/404 会清除缓存。暂时读取失败时保留并明确标记旧详情，同时禁用写操作。旧请求不得覆盖修改后的结果；连接切换清空详情状态。详情读取不能代替设备列表核对未确认的写操作。

Agent 页面读取 `nodeCount` 展示设备数量，0 与未提供分别显示；根据 `syncedAt`、`error`、`authUrl` 区分已同步、同步异常、等待同步和等待授权。同步异常会保留最近同步时间及设备数量，HTTP 请求失败仍单独显示错误。页面不展示该接口未提供的 Agent 名称或同步间隔。

组网管理主页面的大标题右侧固定提供「＋ 创建密钥」实心圆角按钮，布局与运动记录一致，滚动内容或切换标签页时保持可见。点击直接打开创建表单并读取用户与权限；「更多 → 接入密钥」用于查看列表。密钥归属可选「用户」或「纯标签」：用户模式要求选择用户；纯标签模式要求至少一个 ACL 标签，请求省略 `user_id`，依赖 Headscale 对无用户归属密钥的支持，旧服务拒绝时直接展示错误，不自动改为用户密钥或重试。有效期支持 1/7/30/90 天及自定义整数天数（1–365,000）；拒绝小数、负数、非数字与溢出。另可选可重复使用和临时设备。标签支持逗号或换行分隔，自动补上 `tag:`、去重并校验格式；通过 `acl_tags` 提交，列表展示返回的 `aclTags`。完整新密钥仅在本次结果弹层中显示，复制内容仅限本机并在 120 秒后失效；列表不显示完整密钥。纯标签密钥的过期操作暂不提供，因为当前适配的官方 action 仍要求用户编号。

## SSH 终端

设备详情 →「SSH 终端」→ 填写目标系统的 SSH 用户名 →「打开终端」。App 使用隔离的 WKWebView 打开同一管理前缀的 `/ssh/<设备名称>?user=<用户名>`，由 Headplane 官方 WebAssembly 客户端加入 Tailnet 并提供交互终端；使用设备名称而不是设备编号。设备离线或已过期时禁用入口。

首次连接后点击右上角「登录」，在官方 OIDC 页面完成登录；返回当前 Headplane 首页或设备列表后，自动打开原设备终端。右上角重新连接按钮也可手动返回终端。SSH 账号须已关联 Headscale 用户，服务端须启用 Agent、提供 `hp_ssh.wasm` / `wasm_exec.js`，目标须启用 Tailscale SSH，策略须允许访问。API Key 登录会被官方 SSH loader 拒绝；本实现不会绕过这一限制。部分身份提供商可能限制内嵌浏览器登录，实际可用性取决于部署与提供商策略。

SSH 浏览器使用非持久网站数据，不注入 API Key、版本查询密钥或原生管理 Cookie；关闭后不保存网页登录状态。允许 HTTPS 身份提供商跳转，HTTP 仅在连接明确允许时使用，不加载文件、脚本 URL 或含账号密码的地址，不放宽 TLS 证书验证。关闭前确认断开，退出时销毁页面及 WASM 连接，不记录终端输入输出；网络加载失败可手动重连。

该接入按 v0.8.2 官方 SSH 页面实现。已验证地址生成、管理前缀、用户名编码及登录返回来源；实际 OIDC 登录、Tailnet 接入及交互终端仍需在已启用上述能力的实例上验收。

删除、过期、路由和策略保存要求操作确认。写请求不自动重试；超时或响应不明确后禁用后续写操作，直到成功刷新远端状态并由用户核对。已确认写入后的回查失败也会保留这一状态。策略保存前再次比较原文，但服务端没有原子条件写接口，仍存在检查与提交之间的并发窗口。

## 协议边界

Headplane 未提供供第三方稳定使用的公开 REST 管理接口；这里适配其 React Router single-fetch `.data` loader/action。请求字段参照官方仓库的 **v0.6.2、v0.7.0、v0.8.0 和 v0.8.2** 发布标签，使用 `action_id` 表单协议。该范围表示已核对源码契约，不等于每个部署均已完成在线验证。

2026-11-04 使用 v0.8.2 官方 loader/action 和其锁定的 React Router 8.4.0 进行了本地契约测试：登录、各资源读取、设备操作、路由审批、策略保存及密钥生命周期等 15 项检查全部通过。Headscale 后端和会话存储使用模拟实现，未连接用户实际部署。

独立设备详情另按 v0.8.2 官方 loader 验证了 Agent 有数据、查询失败、未启用和设备不存在四种响应，并用原生解码器读取。详情接口的这项验证范围为 v0.8.2。

服务器诊断使用 v0.8.2 官方 loader 和 React Router 验证了健康正常/异常、版本正常/后端不健康/密钥错误/未认证、设置及布局能力读取。测试后端使用模拟实现。原生测试另覆盖管理地址前缀、凭据隔离、缺失版本密钥、旧连接读取、错误响应、重定向和失败后旧结果清理。

未宣称支持已改用 `intent` 字段的开发分支。升级 Headplane 后需重新验证路由、字段和响应编码；遇到不兼容数据会报错，不将未知响应当成成功。应用的部署地址、反向代理、Cookie 设置和 Headscale 后端能力同样影响可用性。

协议依据：[Headplane v0.8.2](https://github.com/tale/headplane/tree/v0.8.2)、[机器操作](https://github.com/tale/headplane/blob/v0.8.2/app/routes/machines/machine-actions.ts)、[密钥操作](https://github.com/tale/headplane/blob/v0.8.2/app/routes/settings/auth-keys/actions.ts)、[Agent 状态](https://github.com/tale/headplane/blob/v0.8.2/app/routes/settings/agent.tsx)。

## 开发验证

### DNS 页面返回 500

v0.8.2 的 DNS loader 在 Headscale 配置不可读时抛出 `No configuration is available`；生产模式下 React Router 将它隐藏为 `Unexpected Server Error`，返回 HTTP 500。网络读取权限不足等其他异常也可能返回相同提示，不能仅凭此响应确定原因。

API Key 能读取设备，不代表 Headplane 能读取 DNS 配置。先打开同一实例网页的 DNS 页面，并查看对应请求的 Headplane 服务端日志。如果日志指向配置不可用，检查 Headplane 配置中的 `headscale.config_path` 是否指向其容器内的 Headscale 配置文件、文件挂载和读取权限，以及 YAML 是否有效。只读挂载足以查看 DNS，无需为查看功能授予写权限；调整后重启 Headplane 再读取。

此场景已用 v0.8.2 官方 DNS loader 和 React Router 8.4.0 生产模式在本地复现：模拟配置可读时返回 200，不可读时返回上述 500。尚未确认用户实际部署的根因。

### 运行测试

模块代码位于 `apps/ios/Hako/Headplane/`。业务客户端遵循 `HeadplaneAccess`，共享宿主的 `HTTPTransport`、`SecureStorage` 和日志设施，不依赖其他子应用。

在 `apps/ios` 下执行：

```sh
swiftc -target arm64-apple-macos14.0 Hako/HTTPTransport.swift Hako/SecureStorage.swift Hako/Logging/HakoLog.swift Hako/Headplane/HeadplaneProtocol.swift Hako/Headplane/HeadplaneStream.swift Hako/Headplane/HeadplaneClient.swift Hako/Headplane/HeadplaneStore.swift Tests/HeadplaneTests.swift -o /tmp/hako-headplane-tests
/tmp/hako-headplane-tests
```

测试覆盖真实编码器生成的 fixture、畸形/循环引用、URL 与表单编码、Cookie 会话、读请求单次重试、写请求不重放、凭据保存失败、策略冲突和过期读取结果隔离，以及 Agent 数量、同步异常、待授权和未启用状态。设备详情另覆盖独立请求、设备编号校验、多设备隔离、可选字段、布尔值未知状态、编辑后回查、旧请求丢弃、403/404 清理和写入结果不确定时的恢复。CI 已包含该命令。`Tests/Fixtures/Headplane/generate.mjs` 使用官方 `react-router@8.4.0` 内置 turbo-stream v2 编码器生成纯测试数据，不需要真实服务器或凭据。

实际实例验收仍需验证登录、列表、路由批准/撤销、测试设备重命名、策略保存与密钥生命周期；应使用可丢弃的测试设备和密钥。模拟网络验证不代表已连接用户的部署。
