# Kage Windows Agent

Kage 是 Hako 的 Windows Agent，使用 C# / WPF / .NET 10，管理工具入口、服务器配置、托盘、长连接和请求分发。Android Agent 名称为 Doppel。可执行文件、守护进程、安装入口、配置目录、CLI、窗口和托盘统一使用 Kage 名称。

## 使用

局域网代码工坊也可独立使用：在「服务器设置」填写「局域网直连端口」，点击「保存局域网配置」。`0` 表示关闭，启用后无需服务器登录或密钥认证。iOS 在主应用「设置 → 网络 → 网络配置」登记当前内网 Wi-Fi，再填写代码工坊的电脑 IP 与相同端口。匹配 Wi-Fi 时直连，其他网络沿用服务器连接。

CLI 配置：`Kage.exe config set --direct-port <端口> --json`；查看 `Kage.exe status --json` 中的 `direct.listening` 和 `direct.port`。直连仅接受本机与本地网段客户端。代码工坊与加密设备查询复用监听端口，使用独立协议。设备查询通过 `query.network.lan` 上报当前地址及会话凭据，iOS 在同一 Wi-Fi 子网优先直连，失败时回到服务器转发。详细协议见 [Agent 局域网数据查询](../../docs/agent-lan.md)。

1. 服务器设置填写 HTTPS 根地址和唯一账号。
2. 点击「生成公私钥对」生成 RSA 3072 位密钥，也可导入至少 2048 位的未加密 PKCS#8 / PKCS#1 PEM 私钥。密钥立即加密保存，无需先填写或连接服务器。
3. 导出公钥，在服务端 `/admin/` 管理页登记 Agent，即时生效。
4. 保存并连接。主应用使用 WSS 和一次性 RSA-PSS 挑战完成认证，连接成功后等待查询。

私钥及配置通过当前 Windows 用户的 DPAPI 加密保存在 `%LOCALAPPDATA%/Kage/agent.dat`，私钥不上传。身份验证失败暂停重连，修改配置或点击“重新连接”后重试；网络中断采用退避重连。

版本不兼容时在左侧菜单下方显示原因，不弹出对话框。设备监控和代码工坊的云端连接暂停，每 30 秒重新检查服务端版本；版本兼容后自动连接并移除提示。版本检查请求失败时按网络错误重试。等待期间本机界面、CLI 和已配置的局域网功能继续可用，关闭或更新 Agent 无需处理版本提示。

本机更新流程在停止旧进程和替换文件前，使用待安装的 EXE 检查当前配置服务器的版本。服务端尚不满足新版 Agent 的兼容要求、版本信息无效或服务器不可访问时，更新被阻止，保留原进程、文件和配置；先更新服务端，再重新执行 Agent 更新。检查由候选版本自身完成，不使用旧进程的版本要求。

导出为标准 SPKI PEM 公钥文件，默认名 `desktop.public.pem`。生成或导入新密钥需确认替换，并断开旧连接；更新服务端登记的公钥后重新连接。生成或导入密钥只保存密钥，URL 和账号的编辑内容仍通过「保存并连接」保存。

关闭窗口后保留系统托盘和长连接，通过托盘“退出”结束进程。不安装 Windows Service，默认不启用自启动。

「服务器设置 → 启动设置」提供「登录 Windows 后自动启动」开关，切换后立即生效，无需保存服务器配置或管理员权限。开启后在当前用户的启动文件夹创建 `Kage Agent.lnk`，登录后在托盘后台运行并自动连接；关闭仅删除对应快捷方式，不退出当前 Agent。开关进入设置页时读取快捷方式的目标与参数，设置失败恢复实际状态并显示错误。独立 `--data-dir` 配置使用各自的启动项，互不影响。移动 EXE 后，在新位置重新开启以更新快捷方式。

EXE、窗口与系统托盘统一使用独立的 Kage 图标（`src/Hako/Assets/Kage.ico`，包含 16–256 像素尺寸）；矢量源文件和导出脚本位于 `branding/`。CLI `connect` 启动的后台实例也保留托盘入口，不自动弹出主窗口。

Agent 使用 WebSocket v4，在认证时上报注册动作与版本。`Core/AgentDispatcher.cs` 注册和分发主进程动作，新增动作时同步维护处理器与 `MainCapabilities`，测试核对二者一致；`GuardianDispatcher` 加入守护进程的管理能力。服务端透传 JSON 参数、结果和业务错误，无需为每个动作升级。当前注册 `query.system.metrics` v1、`query.codex.usage` v1 和 `query.network.listeners` v1（参数均为 `{}`），以及 `action.network.http.check` v1（参数 `url`），并支持 `query.all` v1 聚合常规查询。部署时同步更新服务端与客户端。

新版 Agent 的 Git 功能需要本机安装 Git，使用 Agent 当前 Windows 用户的 Git 身份与凭据。iOS 可查看 `~/Code` 下的仓库并创建提交、推送。操作仅针对手机确认的仓库、文件或分支。命令详见 [设备监控协议](../../docs/device-monitoring.md#git-仓库)。

「代码工坊」通过独立 `hako.workshop/1` WebSocket 连接使用当前用户已登录的 Codex CLI 管理项目会话、编程任务、审批与 HTML 原型。任务独立于手机连接执行，支持按请求 ID 去重及断线后读取进度。协议与限制见 [代码工坊](../../docs/code-workshop.md)。

「设备监控」支持本地刷新和远程查询，CPU 使用率为约 1 秒窗口内的整机平均值，使用可跨语言系统和处理器组的 PDH 计数器；内存为总物理内存减去可用物理内存。网络上下行速度使用同一采样过程前后的物理网卡 64 位字节计数器差值，按实际经过时间计算，`network` 字段返回 B/s、网卡数量和可用状态；包含局域网，排除非物理、过滤、回环与隧道接口，网卡变化或计数器重置时显示暂不可用。GUI、CLI 与远程查询使用同一份指标。网络按需采样，不后台统计或保存今日累计流量；没有服务端请求时不会持续上传指标。

新增 `query.codex.usage` v1：Agent 运行时每分钟增量采集当前电脑的 Codex 用量，保留今天及之前 6 天的每日用户发送调用数、token 用量，并查询当前处理中会话数、项目名与显示标题。调用数按主会话中的用户消息 ID 去重，不把多轮模型请求或工具调用计为用户发送；自动上下文和内部审核消息不计数。只读取用量和运行状态元数据，缓存到当前配置目录的 `codex-usage.json`，不采集对话正文或凭据；旧版数据会标明估算或明细缺失。参数固定为 `{}`，支持单独查询及 `query.all`，手机按能力展示，网页使用通用 JSON 调用。详见 [统计口径与存储说明](../../docs/codex-usage.md)。

`query.network.listeners` v1 按需读取本机 TCP LISTEN 和 UDP 绑定端口，覆盖 IPv4 / IPv6；同协议同端口合并为一项，在详情中按 PID 列出进程名、监听 IP、进程启动时间和采集时的运行时长。同端口不同进程均保留，TCP / UDP 分别展示。进程名和启动时间优先取系统进程快照，无需逐个打开高权限进程，因此普通用户也能查看系统服务的启动时间；快照不可用时回退逐进程读取。已退出或仍不可读取的字段返回 null，不影响端口显示，并附采集提示；运行时长是进程存活时间，不是端口监听时长。Windows「刷新本机状态」与 iOS「监听端口」卡片使用相同采集结果，网页可通过通用 JSON 调用。无后台扫描和历史存储，详见 [设备监控协议](../../docs/device-monitoring.md)。

监听端口详情按「用户 / 系统」排列，默认打开用户 Tab，带各自端口数：按程序来源分类，Windows 目录内的程序归系统，外部安装的程序及其后台服务归用户。路径不可读取时，仅已知 Windows 核心进程名归系统，其他有名称的程序归用户；不再用 Session 0 判断，因此 Python、Verge 的后台服务也属于用户。同端口存在两类进程时，各页只展示对应进程及 IP。无法确认名称与路径的进程暂列用户并提示，兼容尚未提供分类的旧 Agent。

Python / pythonw 在端口列表中显示正在运行的脚本名或 `-m` 模块名，展开可看脚本路径或模块名称；只采集入口，不上传脚本参数、完整命令、环境变量和 `-c` 代码。高权限进程的启动信息可能读取被拒绝，此时明确显示“启动信息暂不可用”，不影响 PID、监听地址和运行时长。可运行检查程序的 `network-listeners` 诊断模式查看相同的结构化结果。

## 更新与进程守护

`scripts/install-guardian.ps1` 将已验证的发布产物部署为独立的 `Kage.Guardian.exe` 固定副本，启动独立后台进程，并将当前配置的登录启动项交给守护程序。服务器设置中的自启动开关同步管理这个启动项，避免主 Agent 与守护程序重复启动。主 Agent 更新不会覆盖正在运行的守护程序，也不会停止守护进程中的命令任务。开发验证时可用 `-NoStartup` 不登记登录启动项。

默认每 5 秒检查主进程，每 5 分钟检查仓库 `stacklix/hako` 的 GitHub Releases。Windows 流水线在默认分支验证通过后发布带 `windows-agent-` 前缀的独立版本，包含 `Kage.exe` 和 `agent-update.json`；不覆盖其他平台的 latest release。守护程序校验发布来源、文件大小、SHA-256 和版本，拒绝降级以及早于最近一次本机直接安装的发布。

兼容更新仍由 Codex 验证后直接替换，无需等待 GitHub。只有服务端版本不兼容或无法确认时，才保留候选产物并登记到守护队列，待满足条件后安装。守护程序与本机直接安装共用 `update.lock`；替换前用候选 EXE 再次检查服务端版本，替换后回查新进程与本机接口。启动失败恢复原文件，保留备份、事务记录和被拒绝产物哈希，避免循环安装坏版本。中断的事务在守护程序重启后恢复。

安装工具应独立于即将退出的主 Agent 所属任务进程链。Windows 计划任务中的无限制 Job 不接受 `CREATE_BREAKAWAY_FROM_JOB`，独立进程启动器会先查询当前 Job 限制，仅在受限 Job 中请求脱离，查询失败则中止启动。命令任务的 Job 仍保留退出、取消和超时清理规则。正式替换前应先在隔离配置中验证启动路径，正常启动与回滚使用同一条已验证路径。

主 Agent 异常退出持续 30 秒后自动拉起，连续短时退出或启动失败时逐步退避，最长 5 分钟。版本等待和网络断开不属于主进程异常退出。守护进程同时负责服务端连接、命令执行与 `admin` 管理能力；命令模块不再启动独立执行器进程。用户通过 CLI 或托盘退出时暂停拉起，手动重新打开主 Agent 后恢复守护。下载和更新检查在后台执行，不阻塞主进程检查。

配置、状态和控制文件位于当前配置目录 `guardian/`，其中 `status.json` 包含守护 PID、主进程状态、更新状态和最近检查时间，`pending-update.json` 保留暂缓的本机候选版本。停止守护使用 `Kage.Guardian.exe --stop-guardian --config <配置目录>/guardian/config.json`；重新启动使用 `--start-guardian`。停止守护不会停止主 Agent。

主程序与守护副本内容不一致时，主程序启动独立的临时更新工具，先用候选版本验证服务端兼容性，再按 `update.lock`、`guardian/install.lock` 的顺序等待安装互斥。工具先备份和校验文件，从不可变的版本目录启动新版待命进程，完成运行时、配置和调度器预热；此时旧版继续维持连接，新版不占用正式通信入口、命令执行器或服务端连接。确认新版就绪后，才请求旧版停止接收新命令，等待已有命令结束（仍可查询和取消），原子替换用于下次启动的守护副本，再激活已经预热的新版进程并回查 PID 和本机通信接口。预热失败保留旧进程，接管失败恢复备份。WebSocket 在接管时重新认证，因此仍可能短暂断连。更新完成后工具退出，常驻仍为主 Agent 和守护进程两个进程。`guardian/refresh.json` 记录等待、预热、排空、启动及完成状态；失败保留错误类型和备份。主程序的本机接口先就绪，避免更新器等待主程序、主程序又等待守护程序的循环等待。

## 运行与退出记录

Agent 在当前配置目录的 `logs/` 保存 `agent-lifecycle.jsonl` 和 `agent-session.json`。默认位置为 `%LOCALAPPDATA%/Hako/logs/`，使用 `--data-dir` 时随配置隔离。

记录包括启动版本与进程号、就绪、每 30 秒一次的主线程心跳、CLI 或托盘退出请求、Windows 注销或关机，以及未处理异常的类型和调用栈。异常消息、配置、密钥和任务内容不写入日志。日志达到 1 MiB 后轮转，最多保留当前文件和 3 个历史文件。

如果进程被强制结束或机器断电，下次启动会记录 `previous_unclean_exit`，保留上一进程号和最后心跳时间。此记录说明上次未完成正常退出流程，具体原因需要结合 Windows 事件查看。

## 命令行

### 线上投资数据查询

管理员可在 Web 后台「设备代理」为指定设备开启「线上投资数据查询」，也可在手机「设备管理 → 设置」选择设备后开启「允许查询投资账本」。权限默认关闭，持久保存，修改后下一次请求立即生效；设备离线时也可配置。Agent 不能自行开启权限。

```powershell
Kage.exe server schema --json
Kage.exe server query --sql "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name" --json
Kage.exe server query --sql-file query.sql --limit 100 --offset 0 --json
```

CLI 直接使用当前配置中已加密保存的 Agent 密钥签名 HTTP 请求，不替换或断开现有设备连接。签名绑定服务端、账号、密钥指纹及完整查询内容，包含短时有效时间戳和一次性随机数；服务端校验权限并持久防重放。拒绝重定向，不把密钥、签名或查询内容写入诊断日志。查询仅限 `investment` 数据库，不能读取认证、通知或访问日志库。

仅支持单条 SELECT/WITH，写入、PRAGMA、ATTACH 和多语句由服务端拒绝；最多 5 秒、每页 1–200 行，默认 100 行，使用 `--offset` 分页。JSON 结果含 `columns`、`rows`、`hasMore`、`clipped` 等字段，长字段可能按服务端规则截断。`server schema` 返回表结构和数据库版本。SQL 文件须使用 UTF-8，查询最多 20000 字节。需要包含此接口的新版服务端，未升级或权限未开启会返回明确错误。

同一个 `Kage.exe` 支持 GUI 和 CLI。不带命令时打开窗口；CLI 复用当前用户已运行的实例，配置和连接状态与界面同步。没有实例时，查询和配置命令直接执行，`connect` 自动启动独立后台进程。

```powershell
# 总览、命令组帮助、指定命令帮助
.\Kage.exe help | Out-String
.\Kage.exe help key | Out-String
.\Kage.exe config set --help | Out-String

# 生成密钥、公钥导出、配置和连接
.\Kage.exe key generate | Out-String
.\Kage.exe key export-public --output desktop.public.pem | Out-String
.\Kage.exe config set --url https://monitor.example.com --account owner | Out-String
# 将导出的公钥登记到服务端后执行
.\Kage.exe connect | Out-String
.\Kage.exe status --json | ConvertFrom-Json
.\Kage.exe metrics --json | ConvertFrom-Json
.\Kage.exe disconnect | Out-String
.\Kage.exe exit | Out-String
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

这是 GUI/CLI 共用的 Windows EXE，PowerShell 脚本应通过上述管道等待完成并读取输出；需要进程退出码时可用 `Start-Process -FilePath .\Kage.exe -ArgumentList 'status','--json' -Wait -PassThru` 的 `ExitCode`。机器读取时优先使用 `--json`。

`--data-dir <目录>` 可为任意命令选择独立配置和实例，默认仍为 `%LOCALAPPDATA%/Hako`。本机控制使用仅允许当前 Windows 用户的命名管道，不监听 TCP 端口；CLI 和运行中的应用应使用相同的用户和权限级别。

## 源码目录

- `src/Hako/App/` 放主窗口、托盘和服务器设置界面。WPF 应用入口 `App.xaml` 位于项目根目录。
- `src/Hako/Core/` 管理 Agent 生命周期和能力分发。`Connection/` 放 WebSocket、版本检查和 SSH 隧道，`Configuration/` 放配置和密钥。
- `src/Hako/Cli/` 放命令解析、帮助、本地消息格式和命名管道。
- `src/Hako/Features/` 按功能组织系统监控、网络诊断、Git 仓库和 Codex 用量。
- `src/Hako/Platform/` 放 Windows 系统适配，例如加密存储、开机启动、控制台和进程检查。
- `tests/Hako.Checks/` 链接这些目录中的非界面源码，验证 Agent 能力和协议。

## 构建和验证

在 Windows 安装 .NET 10 SDK，从本目录执行：

```powershell
dotnet build src/Hako/Hako.csproj -c Release
dotnet run --project tests/Hako.Checks/Hako.Checks.csproj -c Release
dotnet run --project src/Hako/Hako.csproj -c Release
```

检查程序验证 DPAPI 加解密和篡改拒绝、RSA 3072 位密钥生成、公钥导出与验签、私钥导入、URL 约束、CLI 参数和帮助、配置隔离、命名管道控制，以及真实 Windows CPU/内存/网络采样。网络检查另覆盖网卡筛选（排除硬件不存在的 USB 接口记录，保留未连接的物理网卡）、多网卡汇总、真实时间窗口、64 位计数器精度、空闲、计数器重置、网卡增减和读取失败。

快捷命令由手机保存和传入，在守护进程内按需启用执行器，运行 PowerShell 7。守护进程使用独立程序副本并持有命令连接，主 Agent 更新时仍能查询日志；守护进程自身更新时停止接收新任务，等待现有任务结束。运行 `dotnet run --project tests/Hako.Checks/Hako.Checks.csproj -c Release -- command-tasks` 验证日志游标、去重、取消、超时和安装事务；命令协议与更新脚本集成见[代码工坊](../../docs/code-workshop.md#快捷命令)。

`query.all` 能力检查使用独立的临时 Codex 日志，验证已知调用数、Token 用量及日志缺失场景，避免本机真实日志量和运行状态影响聚合查询断言；CPU、内存、网络仍执行真实 Windows 采样。失败信息分别标识采样次数、结果结构和 Codex 用量错误。监听端口检查创建短期回环 TCP / UDP 套接字，验证 IPv4 / IPv6 及多 IP 合并、PID 和进程启动时长、非监听连接排除，并覆盖多进程、重复地址、未知进程信息、参数和取消处理。

发布包含 .NET 运行时的 Windows x64 单文件 EXE：

```powershell
./scripts/publish.ps1
./tests/cli-smoke.ps1 -Executable ../../dist/windows/Kage.exe
```

输出统一位于仓库根目录 `dist/windows/Kage.exe`，只需复制这个 EXE，无需安装 .NET。脚本校验发布结果恰好只有一个 EXE 后再更新产物，CI 使用同一脚本。

CLI 冒烟检查使用独立配置目录，验证发布 EXE 的帮助、JSON、退出码、密钥、指标和后台/GUI 实例控制，不改动当前用户的默认配置。

也可直接执行 `dotnet publish src/Hako/Hako.csproj -c Release -p:PublishProfile=Standalone`，输出相同位置。首次运行时，运行组件会自动解压到系统的应用缓存目录；配置和私钥仍保存在当前用户的本机加密配置中，不包含在 EXE 中。

协议和三端关系见 [设备监控协议](../../docs/device-monitoring.md)。

返回 [仓库说明](../../README.md)。

设备命令使用 `query.` / `action.` / `admin.` 前缀，前两类在主进程执行，管理命令在守护进程执行，详见 [命名规范](../../docs/agent-command-naming.md) 与 [v4 协议](../../docs/device-monitoring.md)。查询支持 `query.all` 聚合及 `query.system.metrics` 单项；操作 `action.network.http.check` v1 接收 `{ "url": "https://example.com/" }`，由 Agent 检测连通性。所有调用均包含独立 `version`。
