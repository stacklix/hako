# Agent 能力与独立模块

主应用通过共享控制连接 `/ws/console/agents` 的 `list` 一次读取全部 Agent。Agent 的 RSA 认证握手声明命令和模块；Sora 保存原始清单，离线后仍可显示支持情况。模块支持与模块当前是否建立连接是两件事。

```json
{
  "id": "AQHSX",
  "name": "Windows",
  "online": true,
  "capabilities": [{"name": "query.system.metrics", "version": 1}],
  "modules": {
    "workshop": {"version": 1, "lan": {"addresses": ["192.168.1.10"], "port": 8005}},
    "proxy": {"version": 1}
  }
}
```

`capabilities` 只列 Agent 命令；模块不存在表示不支持。整个声明缺失时显示“未声明”。Sora 不解释或按清单拦截业务命令及模块参数；调用端和 Agent 校验自己支持的协议。

iOS 主应用的 `HakoAgents.list()` 返回全部 Agent，子应用自行按能力过滤。设备管理只展示支持命令的 Agent。工坊自行选择并持久化执行 Agent；HTTP 代理由主应用设置选择并按服务器、账号保存，子应用共用，工坊选择不改变代理选择。Agent 明细展示命令列表、代码工坊支持和代理支持。

## 打开模块

选择 Agent 后通过共享控制连接发送以下传输控制消息，不进入 Agent 命令分发器，也不包含业务命令 `method` 或 `params`。

```json
{"type":"module_open","id":"req-123","agentId":"AQHSX","body":{"module":"proxy","version":1}}
```

Sora 将其转发为独立的 `module_open` 帧，Agent 连接模块并确认就绪后发送 `module_response`。客户端收到：

```json
{"type":"reply","id":"req-123","status":200,"body":{"result":{"module":"proxy","version":1,"path":"/ws/proxy/client/AQHSX"}}}
```

客户端核对模块、版本和同源路径，再用既有 Console 鉴权打开该 WebSocket。代码工坊使用 `module:"workshop"`，客户端路径 `/ws/workshop/client`，独立连接内继续使用工坊协议。模块打开本身不执行 HTTP 目标请求、代码任务或其他业务动作；打开失败不得重放业务动作。局域网工坊直连沿用独立本地连接，无需 Sora 模块连接。

普通 Agent 命令仍采用原格式：

```json
{"type":"request","id":"req-124","agentId":"AQHSX","body":{"method":"query.system.metrics","version":1,"params":{}}}
```

模块打开与业务命令使用不同关联表，Agent 模块打开最多四个并发，普通命令最多十六个并发。代理拥有单独连接、请求配额和认证挑战域，断开代理不会使命令连接离线。更换公钥或撤销设备会关闭对应连接。

## 连接生命周期

Kage 启动时建立一条基础控制连接。工坊、代理各在首次打开时额外建立一条 Kage 到 Sora 的连接，之后保留并独立重连，直到 Agent 停止或配置改变；当前没有按页面退出关闭 Agent 模块的协议。iOS 的代理客户端连接空闲后关闭，下次按需重新打开，不自动重试目标请求。

后台工坊命令执行器运行时另有一条独立连接。Android 投屏沿用既有视频通道：局域网 iPhone 直连 Kage 不增加 Kage 到 Sora 的连接；外网投屏每个会话额外一条，视频与触摸控制共用该会话连接。因此常见为一到三条；后台执行器及一个外网投屏会话同时存在时最多五条。

新版 Kage 移除旧代理命令，版本线提升到 1.5.0。Sora 0.8.16 声明最低 Kage 1.5.0 和 iOS 0.8.134；新版客户端要求 Sora 至少 0.8.16。先更新服务端，再更新客户端；不提供旧代理命令回退。
