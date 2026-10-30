# 阿里云 ECS

iOS 首页「云服务器」直接调用阿里云 ECS API，当前保存一组地域、实例和 RAM 凭据。无需 Hako 服务端、ECS 公网 IP、SLS、VPC 流日志、OSS 或自建监控接口；不安装第三方采集器，不修改防火墙，不创建常驻进程或周期任务。

## 配置

打开「云服务器 → 右上角滑杆」填写连接名称、地域 ID（如 `cn-hangzhou`）、实例 ID（`i-...`）、Linux 用户名、RAM AccessKey ID / Secret。STS 凭据同时填写临时 AccessKey ID、Secret 和 Token；过期后更新整组凭据。点击「测试连接」只查询实例信息，点击右上角勾号才保存。

凭据保存在独立 Keychain 项 `me.stackli.hako.ecs`，仅本机解锁时可访问，不同步到其他设备、不上传 Hako 后端。ECS RPC 使用 HTTPS POST 和 HMAC-SHA1 签名，凭据不进入请求 URL；禁止自动重定向，不输出阿里云原始错误正文或签名材料。

## 实例前提

- 运行中的 Linux ECS；实例信息、基础监控使用官方接口。
- 已有阿里云云助手 Agent 在线。终端还需在阿里云控制台开启会话管理，Agent 版本需满足服务要求。
- 系统快照使用实例**已有 Python 3 标准库**读取 `/proc` 与文件系统，查询端口和连接还使用已有 `ss`（iproute2）。缺少依赖时报告查询错误，Hako 不会自动安装软件。
- 配置的 Linux 用户存在且具备所需读取权限。无法读取其他用户的 PID、磁盘 I/O 或可执行文件时隐藏对应字段，不将缺失值填成零。

RAM 身份至少需要以下实际使用的操作权限，授权范围与条件以各 API 的 RAM 授权说明为准；不要用主账号或直接套用 ECS 全权限：

| 用途 | API |
| --- | --- |
| 实例信息 | `ecs:DescribeInstances` |
| 分钟监控 | `ecs:DescribeInstanceMonitorData` |
| 读取系统快照 | `ecs:RunCommand`、`ecs:DescribeInvocationResults`、`ecs:StopInvocation` |
| 终端 | `ecs:StartTerminalSession`、`ecs:EndTerminalSession` |

注意 `RunCommand` 是命令执行权限，并非普通只读监控权限；Hako 发出的采样脚本只读取系统信息，但 RAM 身份拥有的权限边界仍按阿里云策略执行。

## 页面与数据口径

- **概览**：CPU、云盘读写带宽来自 ECS 基础监控；内存使用、挂载点使用量、负载、内核、架构和运行时长来自云助手一次性查询。内存已用为 `MemTotal - MemAvailable`；磁盘按文件系统实际块数统计，不把云盘容量当作使用量。同一文件系统按设备去重，优先展示根挂载而非 bind 别名；过滤 Docker / containerd 的容器 overlay，只有系统根目录自身为 overlay 时保留该根目录。
- **网络**：最近一小时实例内网收发趋势来自基础监控，最细 60 秒。`IntranetRX/TX` 是一个周期内的 kbits，转换为 Byte/s 时乘 `1000 / 8 / 60`；不当作瞬时值。网卡速率来自约 1 秒的计数差，累计来自 `/proc/net/dev`，网卡重建或系统重启可能重置。监听端口、当前连接及其 PID 来自 `ss`，范围是主机网络命名空间；不自动遍历容器命名空间。
- **进程**：列表标题右侧的原生菜单选择 CPU / 内存从高到低排序；标题下方保留一行轻量分类筛选，仅选中项显示底色，控件不再单独包成卡片。分类后同步更新进程数量，每条进程始终同时标注 CPU 和内存；缺少 CPU 采样时显示 `—`。CPU 在两次采样间计算，按单核 100% 计；多线程可能超过 100%。相同 PID 的启动时间变化时不计算差值，防止 PID 复用造成错误。内存为 RSS；I/O 为内核 `read_bytes/write_bytes` 累计计数。系统 / 用户类型是按内核线程标记、已知基础服务名称、用户会话与 UID 的推断，无法确认的保留「未分类」，不会将所有 root 进程归为系统。
- **终端**：SwiftTerm 原生输入，不提供单独命令输入框，也不显示「已连接 / 断开」状态栏。未连接时显示覆盖终端内容区的遮罩和「连接」按钮；连接中显示进度并可取消。连接异常、握手超时或远端结束会话后，遮罩显示错误和「重新连接」按钮，旧会话清理期间禁用重连。遮罩期间关闭键盘、屏蔽终端交互并隐藏快捷键，连接成功后移除遮罩。阿里云 AXT 二进制协议处理窗口尺寸、45 秒空输入心跳、序列号和同一通道同步；不会自动新建会话并重放命令。首次握手 25 秒超时。截图预览的 `.inactive` 和切换到后台的 `.background` 均不主动关闭连接或结束云端会话；截图后或窗口重新激活时恢复输入焦点，返回前台另做一次最长 5 秒的 WebSocket Ping 探测，仍可用则继续原会话，失效才显示重新连接。iOS 可能挂起后台 App，心跳和读写不能保证持续执行，因此保留会话不等于保证后台不断线。离开页面、切换 Tab 或打开配置时仍关闭当前屏幕的会话并调用 `EndTerminalSession`。创建会话期间退出仍消费迟到响应并清理；清理失败明确提示在阿里云控制台核对。

进入云服务器、切换非终端 Tab、关闭连接设置或返回前台时，立即自动读取当前页面的数据；页面可见、App 活跃且未打开设置时此后约每 30 秒查询一次，也支持下拉刷新。当前页面的同时刷新合并为同一请求；切换页面取消旧查询并等待退出，然后立即查询新页面，不因旧请求仍忙而跳过到下一轮。进入进程详情单独查询该 PID。查询失败保留旧数据及原快照时间，显示错误；新配置保存后清空旧实例数据。

云助手命令设置 `KeepCommand=false`、45 秒执行超时、`TerminationMode=ProcessTree`，不创建定时任务；取消和等待超时会尝试停止整个查询进程树。返回结果预算 20,000 字节，低于云助手 24 KiB 截断阈值。进程按 CPU 优先保留；结果过多时缩短记录并明确标记部分结果，不能当成完整清单。单个进程详情独立查询。

终端首个输出序号允许 0 或 1，后续重复包仍去重。原生视图使用非零初始尺寸并跳过临时过小布局；只在主题变化时更新解析后的颜色。键盘焦点在遮罩移除且视图进入窗口后恢复。当前会话输出仅在内存保留最近 1 MiB，视图暂未挂载或被重建时恢复显示，视图销毁不直接结束屏幕拥有的会话；新会话清空缓冲，不重放输入。日志只记录首包序号和字节数，不记录终端输出内容。

当前界面不显示端口 / 进程完整网络流量、流量排序、未采集历史、秒级基础监控等不可提供的项目。没有演示值或「不支持」功能占位。

## 验证

Windows 可运行所有 Python 测试：

```sh
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

`test_ecs_snapshot.py` 覆盖含括号进程名、PID 复用、root 分类、权限缺失、网卡计数重置、IPv6、容器 overlay 过滤、磁盘 bind 去重和输出预算；在 Linux 上额外读取真实 `/proc` 验证概览、网络和当前进程。Linux CI 执行同一套测试。`ECSLoadingTests.swift` 覆盖初次读取配置并加载、查询中切换 Tab、立即离开再进入及同页同时刷新合并。

macOS CI 在归档前对 ECS 非 UI 源码进行类型检查，并运行 `ECSTests.swift`：官方签名向量、百分号编码、STS 与 POST 参数、原始错误脱敏、监控单位转换、缺失字段、AXT 帧边界、0 / 1 首包序号、乱序同步、重复输出与输入确认，以及视图挂载前输出、渲染器替换、输出缓冲上限、新会话清空和连接探测成功 / 超时 / 重复回调。

Windows 不运行 iOS 编译、签名或安装；上述脚本测试不代表已经通过真机与真实 ECS 验证。真机还需验证输入法、粘贴、方向键、终端 resize、切换页面 / 前后台清理、权限不足、STS 过期及实际 RAM 策略。没有真实阿里云凭据时不尝试连接用户实例。

官方依据：[云助手](https://help.aliyun.com/zh/ecs/user-guide/overview-10)、[RunCommand](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-runcommand)、[基础监控](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describeinstancemonitordata)、[终端会话](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-startterminalsession)、[AXT 官方参考](https://github.com/aliyun/cloud-assistant-starter/tree/master/src/main/resources/static/components/session)。
