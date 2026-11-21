# Kage Android 管理

Kage 在 Windows 本机执行 ADB 操作，Hako iOS 提供远程入口。服务端继续只做通用命令鉴权与透传，不解释 Android 参数或结果。手机需要允许电脑调试，Android 11 以上可通过无线调试配对；亮屏不会绕过锁屏。

## 界面

- Kage 原生窗口的「Android 管理」提供设备发现、无线配对、连接、状态、屏幕操作及 Nami 维护。未找到 ADB 时可下载 Google 官方平台工具，也可使用 Android SDK 环境变量或 PATH 中的 ADB。
- Hako 在 Kage 的设备详情增加「Android」页签。主页卡片只显示名称、系统、连接方式及 ADB / Nami 状态，不显示屏幕或电池。
- 点击手机卡片通过 `SettingsSheet` 打开 Android 数据，页签为「概览、控制、维护、记录」。实时刷新在手机信息区，默认关闭；概览支持下拉刷新。
- Nami 关联由使用者从已登记 Android Agent 中选择，保存在 Kage。应用进程、Agent 进程和服务器确认的 Agent 在线状态分别显示，不把启动回执作为已上线。

## 命令 v1

| 命令 | 参数及用途 |
| --- | --- |
| `query.android.devices` | `{}`，ADB 环境、设备及连接列表；不参与 `query.all`，实时订阅约每 10 秒更新 |
| `query.android.device` | `deviceId`、可选 `serial`；屏幕、电池、内存、存储、开机时长与 Nami 进程、版本 |
| `query.android.operations` | `deviceId`；最近操作 |
| `query.android.operation` | `requestId`；原任务状态 |
| `query.android.logs` | `deviceId`、可选 `serial`；Nami Agent 当前进程近期日志，按需读取并遮蔽带敏感字段的行 |
| `query.android.artifact` | `requestId`、`offset`；分块读取已完成任务的截图 |
| `query.android.preview` | `requestId`；一次读取不超过 40 KB 的 JPEG 预览，原始 PNG 保持不变 |
| `action.android.stream` | `operation=start/relay/stop`、`sessionId`；创建、接通或结束独立视频会话 |
| `action.android.execute` | UUID `requestId`、`operation`，以及所需设备、连接或配对参数；立即返回独立任务 |
| `action.android.upload` | UUID `uploadId`、`fileName`、`length`、`sha256`、`offset`、`data`；顺序上传 APK |

`operation` 为 `wake`、`sleep`、`screenshot`、`start`、`restart`、`install`、`pair`、`connect`、`associate` 或 `tools`。设备操作要求 `deviceId`；可选 `serial` 选择具体连接。配对 / 连接要求私网 IPv4 的 `address`，配对另需 6 位 `code`，通过 ADB 标准输入传递。安装使用 `uploadId`；关联使用 `agentId`。

相同物理序列号的 USB、无线连接合并显示。每次操作固定一条已授权连接，不因中断切换连接重复执行。操作编号先落盘，相同编号及相同内容只执行一次，内容冲突则拒绝。状态为 `queued`、`running`、`completed`、`failed`、`unknown`。Kage 重启后未结束的任务标记结果待确认，不重放；网络超时后应查询原编号和设备状态。收起 iOS 页面不终止已提交的电脑任务。

APK 最大 256 MB，每块最多 8192 字节；块重传必须与已有字节一致，完成后校验 SHA-256。Kage 解析二进制 manifest，限定包名为 `me.stackli.doppel`，拒绝低于已安装版本的 APK。覆盖安装只使用 `adb install -r`，签名由 Android 安装器校验；不自动卸载、清空数据或降级。截图最大 16 MB，按需生成，操作与文件留在当前用户的 Kage 数据目录。上传缓存有数量上限，达到上限时会明确提示在电脑上清理。

## 实时屏幕

iOS 的 Android 设备 Sheet →「投屏」独立 Tab 显示连续 H.264 视频，点击「开启投屏」才连接，进入页面不自动连接。Kage 在通过视频通道认证后自动亮屏并回查状态，再启动编码；点击「关闭投屏」、离开页面、切换连接、进入后台或连接中断时，先关闭视频源并清理 ADB 转发，再自动息屏并回查。息屏完成前不允许新会话接管同一手机；未能确认息屏时明确显示错误。手机需要允许 ADB 输入控制，亮屏不会解除锁屏。视频不轮询截图，不持久保存录像，不包含声音。

连接后可直接点击、长按和单指滑动画面；坐标按当前视频像素尺寸换算，横竖屏使用编码器实际尺寸。触控使用 scrcpy 控制 socket，与视频共用该会话的 ADB forward，不逐次启动 `adb shell input`。部分设备须开启「USB 调试（安全设置）」才允许输入注入；不绕过锁屏或系统授权。停止时尽力取消尚未结束的手势，再清理控制和视频连接。

收到投屏画面后才显示右上角全屏图标。全屏与卡片复用同一视频会话，按原比例扩展到整个屏幕，不保留标题栏、说明区或内容内边距；屏幕比例不同时仅保留必要黑边。全屏中只显示悬浮的「退出全屏」按钮，默认位于左上角，可拖动到安全区内其他位置，点击返回卡片后继续投屏；连接结束时自动返回卡片查看状态。在卡片内点击「关闭投屏」结束会话并自动息屏。未连接时显示紧凑的 16:9 占位，卡片内已连接画面最高 360pt。

Kage 内嵌官方 scrcpy 3.3.4 手机端编码器（Apache-2.0，许可证位于 `apps/windows/src/Hako/Assets/scrcpy-LICENSE.txt`），固定 SHA-256 `8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e`。连接时经 ADB 推送到独立的临时路径，通过 `app_process` 启动；H.264 上限 1280 像素、30 fps、2 Mbps，MediaCodec 保留完整帧边界和参数集。断开后关闭专属进程、移除该会话的 ADB forward 和临时文件，不终止 ADB 服务或其他会话。

`start` 参数为 `sessionId`、`deviceId`、可选 `serial`；返回单会话随机 AES-256 密钥、局域网端口/地址及 `/agent/v1/streams/{sessionId}`。局域网 WebSocket 首包为 AES-GCM 加密的 `{sessionId,timestamp}`，AAD 为 `hako-agent-lan-v1:video-client:{sessionId}`。服务端包的 AAD 为 `hako-agent-lan-v1:video-server:{sessionId}`，明文为 8 字节大端递增序号、1 字节类型及负载：0=视频字节、1=错误、2=ready、3=alive。每包视频负载不超过 32768 字节，每 10 秒发送心跳；客户端拒绝乱序或重复包。密钥只经已鉴权命令交付，不放在 URL 或明文 HTTP 中。

认证后的客户端触控包使用独立 AAD `hako-agent-lan-v1:video-input:{sessionId}`，明文为从 0 递增的 8 字节大端序号和 32 字节 scrcpy 触控消息（类型 2）。Kage 校验单指按下/移动/抬起/取消的顺序、坐标范围、压力、指针编号及空按钮字段，拒绝重放、乱序、任意其他 scrcpy 命令和剪贴板数据。iOS 串行发送；发送不及时合并中间移动，保留按下和抬起事件，队列有界且不自动重放操作。

同一 Wi-Fi 子网优先直连现有 Kage 端口。外网经 Console 鉴权 WebSocket `/ws/streams` 创建通用二进制转发通道，获得一次性生产者凭据后以 `relay` 操作传给 Kage；Kage 只能连接已配置服务端的 `/ws/streams/{id}`，不接受任意目的 URL。服务器双向转发密文，不解释 Android 命令、媒体或能力。视频转发从服务端 0.8.10 起提供，反向触控转发需要 0.8.12；局域网直连不依赖此接口。服务器在两个方向均限制单包最多 64 KB、只接受非空二进制帧，并在每次转发与心跳时核对会话授权；生产者尚未接通时至多暂存一个有界帧。

每台手机仅允许一个视频源，每个 Kage 最多两个会话，待连接 30 秒过期，单次最长一小时。服务端最多八个转发会话、生产者票据一次有效、媒体包最大 64 KB，并持续检查 Console 会话授权；任一方断开时关闭对应通道。原始视频协议见 [scrcpy 开发文档](https://github.com/Genymobile/scrcpy/blob/v3.3.4/doc/develop.md)。

## 验证

Windows 检查程序的 `android` 模式使用假的 ADB 验证连接合并、单位、状态未知、请求去重、固定连接、任务互斥、块校验、配对码不落盘及重启不重放，不控制真实设备。`DeviceKageAndroidTests.swift` 验证 iOS 模型的边界、可选数据与未知操作结果。
