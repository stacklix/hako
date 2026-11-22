# iOS HTTP 代理

在主应用「设置 → 网络 → HTTP 代理」选择支持 `action.network.http.proxy` v1 的 Agent。配置按 Sora 地址和登录账号分别保存；设备列表只展示声明此能力的 Agent，保留已选离线设备。

通过 Hako 共享 `HTTPTransport` 创建的会话，遇到带 `X-Proxy` 请求头的请求时，自动走以下链路：

```text
iOS --HTTPS/已鉴权 HTTP POST--> Sora --现有 Agent WebSocket--> 守护进程
    --本机 RPC--> Agent 主进程 --HTTP/HTTPS--> 目标服务器
```

HTTPS 在 Sora 入口终止，WebSocket 传递请求和响应的数据，不隧穿原始 TLS 连接或证书。Agent 访问 HTTPS 目标时建立独立连接并校验证书。

```swift
var request = URLRequest(url: URL(string: "http://service.example/api/items?limit=10")!)
request.setValue("192.168.1.10:8080", forHTTPHeaderField: "X-Proxy")
let (data, response) = try await HTTPTransport.data(for: request)
```

Agent 实际访问 `http://192.168.1.10:8080/api/items?limit=10`。保留原 URL 的协议、转义路径和查询参数，以 `X-Proxy` 指定的 IP 和显式端口替换目标主机及端口。IPv6 使用 `[fd00::1]:8080`。不接受域名、URL、用户信息或附加路径。请求 `Host` 重新生成。`X-Proxy`、逐跳请求头及 `Connection` 声明的头不会传给目标；目标认证头及其他端到端请求头保留。

Sora 使用已有 `/api/v1/agents/{id}/requests` 接口，只做鉴权、路由、关联和资源限制，不识别代理命令。命令参数是 `url`、`target`、`method`、`headers`、Base64url `body`、`timeoutMs`。结果为 `status`、`headers`、Base64url `body`。二进制内容不转成 UTF-8；压缩响应由 Agent 解压，返回相应长度。目标 3xx/4xx/5xx 原样交给调用方，不自动跟随重定向，不自动重试目标请求。代理封装请求及响应体不进入 Sora 客户端 HTTP 日志。

限制：请求体 512 KiB、响应体 8 MiB、请求头和响应头各 16 KiB；每台 Agent 最多四个并发代理请求，目标执行最多八秒。普通请求体被 URLSession 转成流后仍可读取转发。响应完整缓冲后返回，不提供实时 SSE、WebSocket 升级或 CONNECT 隧道。取消会停止 iOS 等待；已送往 Agent 的请求最多在八秒期限内结束，取消不代表目标没有执行。

需要 Sora 0.8.15、Kage 1.4.27 和 Hako iOS 0.8.111。iOS 在代理动作前核对 Sora 版本，Agent 再校验命令版本和参数。没有 `X-Proxy` 的请求继续按原方式发送；未配置代理、未登录、设备离线或代理失败时明确报错，不回退直连。Sora HTTP 命令封装限制 1 MiB，鉴权后的 Agent WebSocket 响应限制 12 MiB；握手和 Console WebSocket 原有限制保留。

Agent 的添加和修改统一位于主应用「设置 → Agent 管理」，复用现有公钥登记、名称修改与换钥流程；不提供删除入口。设备管理子应用只保留监控和切换设备入口。
