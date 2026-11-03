# 组网管理（Headplane）

Hako 首页的「组网管理」通过 Headplane 管理 Headscale。界面沿用移动原型的黑白灰配色、下划线标签、紧凑设备列表和弹层，支持深色模式。没有预填演示设备。

## 连接

右上角滑杆按钮 → 填写实例名称、Headplane 管理地址及 Headscale API Key → 验证并保存。示例地址为 `https://headplane.example.com/admin`；反向代理使用其他前缀时填写实际管理前缀。仅填写域名会补上 `/admin`。

服务器必须启用 Headplane 的 API Key 登录。客户端将 Key 提交到 Headplane 的登录表单，取得会话 Cookie，随后访问同一 Headplane 的 loader/action。它不会直接请求 Headscale，也不支持 OIDC 登录或 SSH 会话。

连接验证成功后才替换本机配置。凭据使用独立 Keychain 命名空间 `me.stackli.hako.headplane`，仅解锁时可读、仅限本机；会话 Cookie 只保存在内存中。默认要求 HTTPS，HTTP 需主动开启。不会自动跟随重定向或将凭据写入日志。

## 当前功能

| 页面 | 功能 |
| --- | --- |
| 设备 | 在线/离线/过期统计，按名称、IP、标签和用户搜索，详情、重命名、修改标签、过期、删除 |
| 网络 | 查看子网路由和出口节点，确认批准/撤销；DNS、MagicDNS、分流 DNS 和自定义记录只读查看 |
| 访问控制 | 查看 ACL、用户组及标签所有者，保留注释的 HuJSON 原文编辑、修改预览和保存前远端冲突检查 |
| 更多 | Headscale 用户及所属设备只读查看，接入密钥列表/创建/过期，Headplane Agent 状态，连接设置 |

设备与网络页仅在前台且未打开弹层时每 20 秒读取设备。手动刷新可在失败后重试，错误保留已有数据。服务端返回的权限控制编辑入口。后台未配置或不提供 DNS/Agent 时明确显示读取错误。

Agent 页面读取 `nodeCount` 展示设备数量，0 与未提供分别显示；根据 `syncedAt`、`error`、`authUrl` 区分已同步、同步异常、等待同步和等待授权。同步异常会保留最近同步时间及设备数量，HTTP 请求失败仍单独显示错误。页面不展示该接口未提供的 Agent 名称或同步间隔。

组网管理主页面的大标题右侧固定提供「＋ 创建密钥」实心圆角按钮，布局与运动记录一致，滚动内容或切换标签页时保持可见。点击直接打开创建表单并读取用户与权限；「更多 → 接入密钥」用于查看列表。创建时可选用户、ACL 标签、1/7/30/90 天有效期、可重复使用和临时设备。标签支持逗号或换行分隔，自动补上 `tag:`、去重并校验格式；通过 `acl_tags` 提交，列表展示返回的 `aclTags`。完整新密钥仅在本次结果弹层中显示，复制内容仅限本机并在 120 秒后失效；列表不显示完整密钥。当前创建仍需选择用户，不提供无用户归属的纯标签密钥；已有的纯标签密钥只读显示。

删除、过期、路由和策略保存要求操作确认。写请求不自动重试；超时或响应不明确后禁用后续写操作，直到成功刷新远端状态并由用户核对。已确认写入后的回查失败也会保留这一状态。策略保存前再次比较原文，但服务端没有原子条件写接口，仍存在检查与提交之间的并发窗口。

## 协议边界

Headplane 未提供供第三方稳定使用的公开 REST 管理接口；这里适配其 React Router single-fetch `.data` loader/action。请求字段参照官方仓库的 **v0.6.2、v0.7.0、v0.8.0 和 v0.8.2** 发布标签，使用 `action_id` 表单协议。该范围表示已核对源码契约，不等于每个部署均已完成在线验证。

2026-11-04 使用 v0.8.2 官方 loader/action 和其锁定的 React Router 8.4.0 进行了本地契约测试：登录、各资源读取、设备操作、路由审批、策略保存及密钥生命周期等 15 项检查全部通过。Headscale 后端和会话存储使用模拟实现，未连接用户实际部署。

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

测试覆盖真实编码器生成的 fixture、畸形/循环引用、URL 与表单编码、Cookie 会话、读请求单次重试、写请求不重放、凭据保存失败、策略冲突和过期读取结果隔离，以及 Agent 数量、同步异常、待授权和未启用状态。CI 已包含该命令。`Tests/Fixtures/Headplane/generate.mjs` 使用官方 `react-router@8.4.0` 内置 turbo-stream v2 编码器生成纯测试数据，不需要真实服务器或凭据。

实际实例验收仍需验证登录、列表、路由批准/撤销、测试设备重命名、策略保存与密钥生命周期；应使用可丢弃的测试设备和密钥。模拟网络验证不代表已连接用户的部署。
