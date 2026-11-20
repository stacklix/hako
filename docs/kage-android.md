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
| `action.android.execute` | UUID `requestId`、`operation`，以及所需设备、连接或配对参数；立即返回独立任务 |
| `action.android.upload` | UUID `uploadId`、`fileName`、`length`、`sha256`、`offset`、`data`；顺序上传 APK |

`operation` 为 `wake`、`sleep`、`screenshot`、`start`、`restart`、`install`、`pair`、`connect`、`associate` 或 `tools`。设备操作要求 `deviceId`；可选 `serial` 选择具体连接。配对 / 连接要求私网 IPv4 的 `address`，配对另需 6 位 `code`，通过 ADB 标准输入传递。安装使用 `uploadId`；关联使用 `agentId`。

相同物理序列号的 USB、无线连接合并显示。每次操作固定一条已授权连接，不因中断切换连接重复执行。操作编号先落盘，相同编号及相同内容只执行一次，内容冲突则拒绝。状态为 `queued`、`running`、`completed`、`failed`、`unknown`。Kage 重启后未结束的任务标记结果待确认，不重放；网络超时后应查询原编号和设备状态。收起 iOS 页面不终止已提交的电脑任务。

APK 最大 256 MB，每块最多 8192 字节；块重传必须与已有字节一致，完成后校验 SHA-256。Kage 解析二进制 manifest，限定包名为 `me.stackli.doppel`，拒绝低于已安装版本的 APK。覆盖安装只使用 `adb install -r`，签名由 Android 安装器校验；不自动卸载、清空数据或降级。截图最大 16 MB，按需生成，操作与文件留在当前用户的 Kage 数据目录。上传缓存有数量上限，达到上限时会明确提示在电脑上清理。

## 验证

Windows 检查程序的 `android` 模式使用假的 ADB 验证连接合并、单位、状态未知、请求去重、固定连接、任务互斥、块校验、配对码不落盘及重启不重放，不控制真实设备。`DeviceKageAndroidTests.swift` 验证 iOS 模型的边界、可选数据与未知操作结果。
