# Agent 局域网数据查询

Windows Agent 产品名称为 **Kage**，Android Agent 产品名称为 **Nami**。Windows 二进制及产品元数据显示 Kage；Android 应用 ID 和存储标识沿用既有值以支持覆盖升级。

两端新增 `query.network.lan`，版本 1，参数为 `{}`。结果字段：

| 字段 | 含义 |
| --- | --- |
| `enabled` | 是否已提供局域网数据监听 |
| `protocol` | `hako-agent-lan-v1` |
| `addresses` | 当前联网接口的 RFC1918 IPv4 地址数组 |
| `port` | 当前监听端口，关闭时为 0 |
| `token` | 32 字节随机会话密钥的标准 Base64，仅经已认证云端查询获取，不记录到日志 |

该命令属于当前状态，参加 `query.all`。历史短信、通话和操作记录继续独立分页查询，不参加聚合或 Android 实时状态订阅。Kage 的七日 Codex 用量也从 `query.all` 排除，保留独立查询；局域网实时刷新只聚合当前状态。

Kage 复用已配置的代码工坊直连端口，`DirectPort=0` 时关闭，不额外占用端口。Nami 在启用 Agent 时由 `:agent` 进程创建系统分配的端口，主进程通过私有原子文件读取监听描述；收到查询后守护进程通过私有 Binder 转给主进程。停止或重启 Agent 时关闭监听并更换会话密钥。手机 IP 与端口变化通过下一次查询重新发现。

Hako iOS 在已登录的设备管理会话内自动查询此能力，只选择与 iPhone 当前 Wi-Fi IPv4 子网匹配的地址，不需要手动抄录 IP。凭据仅在内存短期缓存，并随服务器或账号上下文切换清除。页面显示实际查询使用的「局域网直连 · IP」或「服务器转发」。直连请求失败时查询经现有云端通道继续；初次发现和凭据刷新仍需要服务器连接，不提供长期完全离线登录。

实时数据在直连时每 2 秒查询 `query.all`，不轮询历史；直连失效时切回云端实时订阅。云端订阅期间定期尝试局域网，找到可用直连后切换。`admin` 和 `action` 始终经现有通道执行，不自动重放动作。代码工坊原有直连行为独立于本协议。

## 传输

原生客户端发送 `POST /agent/v1/query`。监听只接受本机和同一局域网子网，不提供浏览器跨域调用。HTTP 正文仅包含版本和密文：`{"version":1,"payload":"<Base64>"}`。不在 URL 或 HTTP 请求头发送密钥。

请求和响应使用 AES-256-GCM，组合编码为 `12 字节随机 nonce || ciphertext || 16 字节 tag`。请求 AAD 为 UTF-8 `hako-agent-lan-v1:request`，响应 AAD 为 `hako-agent-lan-v1:response`，避免反射。每次加密使用独立随机 nonce。

解密后的请求包含 UUID `id`、Unix 毫秒 `timestamp`、`method`、正整数 `version` 与对象 `params`。服务器拒绝超过 30 秒时差的请求；两端时钟需准确。响应包含原始 `id` 和 `result` 或 `error:{code,message}`，iOS 验证关联 ID。只有 `query.` 命令可进入业务分发器。

解密正文上限 64 KiB，HTTP 密文上限 96 KiB。监听限制连接并发、读取超时与查询执行时间。无凭据、错误密钥、篡改、超期请求均不返回设备数据；任何 LAN 失败都不会关闭云端连接。

跨平台测试向量：密钥为字节 `00...1f`，nonce 为 `00...0b`，明文为 UTF-8 `LAN cross-platform test`，请求 AAD 如上。组合密文的 Base64 为 `AAECAwQFBgcICQoLC0OYO6aXrWj+bOfn0J0eAvG7p0CVCCsC7CiLRe9PkYVIZxJY51fa`。此为公开测试数据，不是实际会话密钥。
