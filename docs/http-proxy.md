# iOS HTTP 代理

在主应用「设置 → 网络 → HTTP 代理」选择代理设备。HTTP 代理是独立网络服务，不注册为 Agent 命令，不占用设备管理标签或命令请求额度。配置按 Sora 地址和登录账号分别保存；候选设备从主应用统一 Agent 清单的 `modules.proxy` 声明筛选，保留已选离线设备。代理选择由主应用统一保存，各子应用共用；代码工坊的选择由工坊自行保存，两者互不影响。

通过 Hako 共享 `HTTPTransport` 创建的会话，遇到带 `X-Proxy` 请求头的请求时，自动走以下链路：

```text
iOS --独立代理 WebSocket--> Sora --独立代理 WebSocket--> Kage 代理模块
    --HTTP/HTTPS--> 目标服务器
```

HTTPS 在 Sora 入口终止，WebSocket 传递请求和响应的数据，不隧穿原始 TLS 连接或证书。Agent 访问 HTTPS 目标时建立独立连接并校验证书。

```swift
var request = URLRequest(url: URL(string: "http://service.example/api/items?limit=10")!)
request.setValue("192.168.1.10:8080", forHTTPHeaderField: "X-Proxy")
let (data, response) = try await HTTPTransport.data(for: request)
```

Agent 实际访问 `http://192.168.1.10:8080/api/items?limit=10`。保留原 URL 的协议、转义路径和查询参数，以 `X-Proxy` 指定的 IP 和显式端口替换目标主机及端口。IPv6 使用 `[fd00::1]:8080`。不接受域名、URL、用户信息或附加路径。请求 `Host` 重新生成。`X-Proxy`、逐跳请求头及 `Connection` 声明的头不会传给目标；目标认证头及其他端到端请求头保留。

主应用先通过共享控制连接发送 `module_open`（`module: "proxy", version: 1`），收到就绪结果后打开 `/ws/proxy/client/{id}`。Kage 按需连接 `/ws/proxy/agent`。客户端消息为 `{type:"request",id,body:{version:1,request:{...}}}`。独立 HTTP API `/api/v1/proxy/{id}/requests` 使用相同代理后端，不调用 Agent 命令。封装为 `version: 1` 和 `request`，不包含 Agent 命令的 `method`/`params`。`request` 中的 HTTP 参数为 `url`、`target`、`method`、`headers`、Base64url `body`、`timeoutMs`；结果为 `status`、`headers`、Base64url `body`。Sora 只做鉴权、路由、关联和资源限制，不校验代理业务参数。二进制内容不转成 UTF-8；压缩响应由 Kage 解压，返回相应长度。目标 3xx/4xx/5xx 原样交给调用方，不自动跟随重定向，不自动重试目标请求。代理封装请求及响应体不进入 Sora 客户端 HTTP 日志。

独立连接复用已登记设备的 RSA 公钥与信任撤销机制，认证挑战使用 `hako-proxy-auth/v1` 域。连接、重连、收发锁和请求额度与设备监控、遥测、SSH 分离；Kage 守护进程内的代理模块直接访问目标，不经主进程 RPC。代理断开不会使设备命令连接离线，设备换钥或移除时两条连接同时关闭。

限制：请求体 512 KiB、响应体 8 MiB、请求头和响应头各 16 KiB；每台 Agent 最多四个并发代理请求，目标执行最多八秒。共享 HTTPTransport 的 data 请求在进入 URLSession 前直接固定原始正文并交给代理；由 URLProtocol 拦截的请求则在 startLoading 同步读取正文，之后才异步鉴权和转发，避免延后读取一次性请求流。正文仅在内存中封装，不写入日志。响应完整缓冲后返回，不提供实时 SSE、WebSocket 升级或 CONNECT 隧道。取消会停止 iOS 等待；已送往 Agent 的请求最多在八秒期限内结束，取消不代表目标没有执行。

独立代理需要 Sora 0.8.16、Kage 1.5.0 和 Hako iOS 0.8.134。iOS 在代理动作前核对 Sora 版本，Kage 校验代理协议版本和参数；不提供原 Agent 命令通道的回退。没有 `X-Proxy` 的请求继续按原方式发送；未配置代理、未登录、代理服务离线或代理失败时明确报错，不回退直连。Sora 代理请求封装限制 1 MiB，鉴权后的代理 WebSocket 响应限制 12 MiB；握手和 Console WebSocket 原有限制保留。

Agent 的添加和修改统一位于主应用「设置 → Agent 管理」，复用现有公钥登记、名称修改与换钥流程；不提供删除入口。设备管理子应用只保留监控和切换设备入口。
