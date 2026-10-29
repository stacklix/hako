# Hako Windows

Hako 工具集合的 Windows 应用，使用 C# / WPF / .NET 10。主应用管理工具入口、服务器配置、托盘、长连接和请求分发；第一个子应用为「设备监控」。

## 使用

1. 服务器设置填写 HTTPS 根地址和唯一账号。
2. 点击「生成公私钥对」生成 RSA 3072 位密钥，也可导入至少 2048 位的未加密 PKCS#8 / PKCS#1 PEM 私钥。密钥立即加密保存，无需先填写或连接服务器。
3. 导出公钥，在服务端 `/admin/` 管理页登记 Agent，即时生效。
4. 保存并连接。主应用使用 WSS 和一次性 RSA-PSS 挑战完成认证，连接成功后等待查询。

私钥及配置通过当前 Windows 用户的 DPAPI 加密保存在 `%LOCALAPPDATA%/Hako/agent.dat`，私钥不上传。身份验证失败暂停重连，修改配置或点击“重新连接”后重试；网络中断采用退避重连。

导出为标准 SPKI PEM 公钥文件，默认名 `desktop.public.pem`。生成或导入新密钥需确认替换，并断开旧连接；更新服务端登记的公钥后重新连接。生成或导入密钥只保存密钥，URL 和账号的编辑内容仍通过「保存并连接」保存。

关闭窗口后保留系统托盘和长连接，通过托盘“退出”结束进程。首版不安装 Windows Service、不自动配置开机启动。

Agent 使用 WebSocket v3，在认证时上报注册动作与版本。`Core/AgentDispatcher.cs` 统一注册和分发动作，新增动作时维护此注册表即可同步更新能力清单；服务端透传 JSON 参数、结果和结构化业务错误，无需为每个动作升级。当前注册 `query.system.metrics` v1 与 `query.codex.usage` v1（参数均为 `{}`），以及 `action.network.http.check` v1（参数 `url`），并支持 `query.all` v1 聚合全部查询。旧 Agent v1/v2 不兼容，部署时同步更新服务端与客户端。

「设备监控」支持本地刷新和远程查询，CPU 使用率为约 1 秒窗口内的整机平均值，使用可跨语言系统和处理器组的 PDH 计数器；内存为总物理内存减去可用物理内存。网络上下行速度使用同一采样过程前后的物理网卡 64 位字节计数器差值，按实际经过时间计算，`network` 字段返回 B/s、网卡数量和可用状态；包含局域网，排除非物理、过滤、回环与隧道接口，网卡变化或计数器重置时显示暂不可用。GUI、CLI 与远程查询使用同一份指标。网络按需采样，不后台统计或保存今日累计流量；没有服务端请求时不会持续上传指标。

新增 `query.codex.usage` v1：Agent 运行时每分钟增量采集当前电脑的 Codex 用量，保留今天及之前 6 天的每日用户发送调用数、token 用量，并查询当前处理中会话数、项目名与显示标题。调用数按主会话中的用户消息 ID 去重，不把多轮模型请求或工具调用计为用户发送；自动上下文和内部审核消息不计数。只读取用量和运行状态元数据，缓存到当前配置目录的 `codex-usage.json`，不采集对话正文或凭据；旧版数据会标明估算或明细缺失。参数固定为 `{}`，支持单独查询及 `query.all`，手机按能力展示，网页使用通用 JSON 调用。详见 [统计口径与存储说明](../../docs/codex-usage.md)。

## 命令行

同一个 `Hako.exe` 支持 GUI 和 CLI。不带命令时打开窗口；CLI 复用当前用户已运行的实例，配置和连接状态与界面同步。没有实例时，查询和配置命令直接执行，`connect` 自动启动独立后台进程。

```powershell
# 总览、命令组帮助、指定命令帮助
.\Hako.exe help | Out-String
.\Hako.exe help key | Out-String
.\Hako.exe config set --help | Out-String

# 生成密钥、公钥导出、配置和连接
.\Hako.exe key generate | Out-String
.\Hako.exe key export-public --output desktop.public.pem | Out-String
.\Hako.exe config set --url https://monitor.example.com --account owner | Out-String
# 将导出的公钥登记到服务端后执行
.\Hako.exe connect | Out-String
.\Hako.exe status --json | ConvertFrom-Json
.\Hako.exe metrics --json | ConvertFrom-Json
.\Hako.exe disconnect | Out-String
.\Hako.exe exit | Out-String
```

`help` 的别名为 `--help`、`-h`；支持 `help config`、`help key export-public` 和各命令的 `--help`。命令总览如下：

| 命令 | 用途 |
| --- | --- |
| `help [命令]` | 用法、选项、示例和退出码 |
| `status` | 进程、连接状态、Agent ID 和公开配置 |
| `config show` | URL、账号、是否有私钥和密钥指纹 |
| `config set --url <URL> --account <账号>` | 更新配置，可只指定一个字段；断开旧连接 |
| `key generate [--force]` | 生成并立即加密保存 RSA 3072 位密钥 |
| `key import --input <文件> [--force]` | 从 PEM 文件导入私钥并加密保存 |
| `key export-public [--output <文件>] [--force]` | 导出公钥，省略文件时输出到终端 |
| `connect` | 启动或复用后台实例并发起连接 |
| `disconnect` | 断开并停止重试，保留进程和配置 |
| `metrics` | 采样本机 CPU、物理内存和网络上下行速度 |
| `exit` | 退出实例，保留配置和密钥 |

替换现有密钥或覆盖公钥文件必须显式使用 `--force`。CLI 不接受私钥文本参数，也不输出私钥。`connect` 成功表示已发起连接，请查询 `status` 的 `connectionState`，值为 `connected` 时才表示服务端身份验证通过。修改配置或密钥后需重新执行 `connect`。

所有命令支持 `--json`，包含帮助和错误，格式为 `{"ok":true,"exitCode":0,"data":{...}}`；失败时包含 `error.code` 和 `error.message`。退出码为 `0` 成功、`1` 操作失败、`2` 参数错误、`3` 实例不可用、`4` 超时。超时后先查询状态再决定是否重试。

这是 GUI/CLI 共用的 Windows EXE，PowerShell 脚本应通过上述管道等待完成并读取输出；需要进程退出码时可用 `Start-Process -FilePath .\Hako.exe -ArgumentList 'status','--json' -Wait -PassThru` 的 `ExitCode`。机器读取时优先使用 `--json`。

`--data-dir <目录>` 可为任意命令选择独立配置和实例，默认仍为 `%LOCALAPPDATA%/Hako`。本机控制使用仅允许当前 Windows 用户的命名管道，不监听 TCP 端口；CLI 和运行中的应用应使用相同的用户和权限级别。

## 构建和验证

在 Windows 安装 .NET 10 SDK，从本目录执行：

```powershell
dotnet build src/Hako/Hako.csproj -c Release
dotnet run --project tests/Hako.Checks/Hako.Checks.csproj -c Release
dotnet run --project src/Hako/Hako.csproj -c Release
```

检查程序验证 DPAPI 加解密和篡改拒绝、RSA 3072 位密钥生成、公钥导出与验签、私钥导入、URL 约束、CLI 参数和帮助、配置隔离、命名管道控制，以及真实 Windows CPU/内存/网络采样。网络检查另覆盖网卡筛选（排除硬件不存在的 USB 接口记录，保留未连接的物理网卡）、多网卡汇总、真实时间窗口、64 位计数器精度、空闲、计数器重置、网卡增减和读取失败。

`query.all` 能力检查使用独立的临时 Codex 日志，验证已知调用数、Token 用量及日志缺失场景，避免本机真实日志量和运行状态影响聚合查询断言；CPU、内存、网络仍执行真实 Windows 采样。失败信息分别标识采样次数、结果结构和 Codex 用量错误。

发布包含 .NET 运行时的 Windows x64 单文件 EXE：

```powershell
./scripts/publish.ps1
./tests/cli-smoke.ps1 -Executable ../../dist/windows/Hako.exe
```

输出统一位于仓库根目录 `dist/windows/Hako.exe`，只需复制这个 EXE，无需安装 .NET。脚本校验发布结果恰好只有一个 EXE 后再更新产物，CI 使用同一脚本。

CLI 冒烟检查使用独立配置目录，验证发布 EXE 的帮助、JSON、退出码、密钥、指标和后台/GUI 实例控制，不改动当前用户的默认配置。

也可直接执行 `dotnet publish src/Hako/Hako.csproj -c Release -p:PublishProfile=Standalone`，输出相同位置。首次运行时，运行组件会自动解压到系统的应用缓存目录；配置和私钥仍保存在当前用户的本机加密配置中，不包含在 EXE 中。

协议和三端关系见 [设备监控协议](../../docs/device-monitoring.md)。

返回 [仓库说明](../../README.md)。

命令固定使用 `query.` / `action.` 前缀，详见 [命名规范](../../docs/agent-command-naming.md) 与 [v3 协议](../../docs/device-monitoring.md)。查询支持 `query.all` 聚合及 `query.system.metrics` 单项；操作 `action.network.http.check` v1 接收 `{ "url": "https://example.com/" }`，由 Agent 检测连通性。所有调用均包含独立 `version`。
