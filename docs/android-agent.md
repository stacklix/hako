# Android Agent

Android Agent 位于 `apps/android`，基于 Nami 的 Flutter UI 和 Kotlin 短信、电话能力。应用 ID 为 `me.stackli.doppel`，显示名为 `Nami`，与原版使用相同 ID；签名不同时需备份并卸载旧版后再安装，系统权限需重新授权。最低 Android 8.0（API 26）。Flutter 仅管理界面；独立 `:agent` 守护进程负责前台连接与认证，`query` / `action` 通过 App 私有 Binder 通道交给主进程的原生业务服务执行。主进程不可用时返回明确错误，不重放操作。配置和连接状态使用私有原子文件及跨进程独占锁，避免多进程 SharedPreferences 缓存不一致。

## 设备接入

1. 在 Nami 的「系统设置 → Nami Agent」生成设备密钥。
2. 复制公钥，在 Hako 设备管理中为相同账号登记设备。每台手机使用独立密钥。
3. 填入 HTTPS Hako 服务器地址与账号，开启 Agent 并保存。
4. 在手机上授予需要的短信、通话记录、电话和通知权限；在电池设置中允许不受电池优化限制，按设备要求允许自启动和后台运行。
5. 如需执行操作，分别开启远程短信、远程拨号开关。默认均关闭。

服务使用 `remoteMessaging` 类型，面向跨设备短信任务，显示常驻通知。网络变化和心跳超时后自动重连。系统禁止后台启动时显示需要打开应用的状态；重启后密钥及设置在首次解锁后可用。用户强制停止、设备省电限制和网络不可用仍可能造成离线，不能承诺永久在线。

## 协议与版本

使用 Hako v4 `/ws/agent`，RSA 3072 位设备密钥保存在 Android Keystore，私钥不可导出。公钥指纹为 SPKI DER 的 SHA-256 / base64url；挑战签名为 RSA-PSS、SHA-256、MGF1/SHA-256、32 字节 salt。校验挑战绑定的服务器、账号和公钥指纹，不接受 HTTP、跳转登录和未经验证的 TLS。

连接前检查 `/api/v1/version` 的 `serverVersion`，当前需要 `0.8.x`。Android 应用独立使用 `pubspec.yaml` 的版本，不套用 Windows 的 `minimumAgentVersion`。服务端没有增加任何短信、电话专用路由、参数校验或能力白名单。Android 不声明 SSH 或代码工坊能力。

## 命令

`query.network.lan` 上报当前局域网 IPv4 和加密数据查询入口；参加状态聚合。iOS 同一 Wi-Fi 子网优先直连，失败后回到云端查询。独立于原有远程 HTTP 控制开关，协议见 [Agent 局域网数据查询](agent-lan.md)。

所有命令版本为 1，参数为 JSON 对象；未知字段、无效版本和错误参数由设备拒绝。

`admin.agent.versions` 由 Android 守护进程直接处理，不依赖主进程，且不参与 `query.all` 或实时状态聚合。返回字段与 Windows 相同：`currentVersion`、`currentBuild`、`minimumServerVersion`、`latestVersion`、`latestBuildId`、`latestCheckedAt`、`latestCheckState`。iOS「关于」页可直接读取。当前版本来自 APK 的版本名，构建标识为 `版本名+versionCode`。

最新版本只检查同仓库的正式 GitHub Release：标签为 `android-agent-<三段版本>-<versionCode>`，且包含同标签目录下的 `Nami.apk` 发布附件；Actions 临时构建产物不算正式发布。没有符合条件的发布时返回 `no_release`，查询失败返回 `unavailable`，不影响当前版本信息。成功结果缓存 5 分钟，失败后 30 秒可重试。

| 命令 | 参数 | 加入 `query.all` / 实时状态订阅 |
| --- | --- | --- |
| `query.device.status` | `{}` | 是 |
| `query.device.storage` | `{}` | 是 |
| `query.device.battery` | `{}` | 是 |
| `query.network.wifi` | `{}` | 是 |
| `query.device.screen` | `{}` | 是 |
| `query.telephony.sims` | `{}` | 是 |
| `query.sms.messages` | `limit`（1–50，默认 20）、可选 `cursor` | 否 |
| `query.telephony.calls` | 同上 | 否 |
| `query.device.operation` | `requestId` | 否 |
| `action.sms.send` | `requestId`、`number`、`text`、可选 `subscriptionId` | 否 |
| `action.telephony.call` | `requestId`、`number` | 否 |

`query.all` 仅聚合当前设备状态、内部存储空间、电池信息、Wi-Fi 信息、屏幕状态、局域网入口和 SIM 状态，不读取短信、通话记录、操作历史或任何其他历史数据。某项状态读取失败时单独返回该项错误。实时订阅也仅采集这些状态，约每 10 秒推送一次。

`query.device.storage` 返回 `storageTotalBytes`、`storageAvailableBytes` 和 `sampledAt`。容量取 App 私有数据所在的内部数据分区，可用空间为普通应用可用的字节数，不包含系统保留块；不把共享/模拟存储重复相加，不等同于厂商标称的整机存储容量。iOS 将此能力合并展示在设备状态页，与运行内存分别标注。

`query.device.battery` 返回电量、充放电状态、供电方式、温度（°C）、电压（V）、瞬时电流（mA）、系统健康状态及采样时间。系统未提供的读数为 null；电流正值表示流入电池，负值表示放电；健康状态不是电池剩余寿命百分比。

`query.device.screen` 返回主屏幕的 `displayState`、设备是否可交互 `interactive` 和 `sampledAt`。显示状态为 `on`、`off`、`doze`、`doze_suspend`、`on_suspend`、`vr` 或 `unknown`；iOS 分别展示亮屏、熄屏、息屏显示等状态。无主屏幕或未知状态不当作熄屏；通话贴耳关屏时可交互状态也不代替屏幕状态。本能力只读，不唤醒设备、不控制屏幕，不需要新增运行时权限。

`query.network.wifi` 返回当前 Wi-Fi 的连接状态、SSID 及其可用状态、信号（dBm）、信号等级（0–4）、协商速率（Mbps）、频率（MHz）、互联网验证结果及采样时间。不扫描周边网络，不返回 BSSID、MAC、密码或 GPS 坐标。未连接时读数为 null；SSID 被系统隐藏时保留其他可用指标并说明权限、定位服务或后台访问限制。协商速率不代表实际下载速度。

Wi-Fi 名称授权位于 Nami「系统设置 → Wi-Fi 信息」，独立于短信、电话必需权限。读取名称需要精确位置授权和开启系统定位服务；后台读取可能还需要用户在系统位置权限中选择「始终允许」。不自动申请后台授权，不授权不影响其他功能。这两项查询与存储查询一样参加聚合和实时订阅；iOS 将其合并到设备状态页。

短信和通话记录按系统记录 `_id` 倒序分页，`nextCursor` 为下一页游标，结束时为 null。ID 和游标使用十进制字符串。时间戳为 Unix 毫秒。短信结果含 `number`、`text`、`timestamp`、系统 `type` 和 `subscriptionId`；通话结果含 `number`、`timestamp`、`durationSeconds` 和系统 `type`。单条响应最多 64 KiB，超出时返回 `result_too_large`，调用方应减小 `limit`。

操作 `requestId` 必须为小写标准 UUID。相同 ID 与相同参数重复调用返回已有记录；参数不同返回 `request_conflict`。记录先落盘再调用系统，重启后保留；不会自动重试结果不确定的发送或拨号。发送到不同 SIM 时应传入 `query.telephony.sims` 返回的 `subscriptionId`。

```json
{"method":"action.sms.send","version":1,"params":{"requestId":"b3480346-5a84-40d4-8f2c-c46fba2f6285","number":"+8613800000000","text":"测试短信","subscriptionId":1}}
```

操作结果字段为 `requestId`、`kind`、`status`、`message` 和 `updatedAt`。`submitting` 表示执行意图已持久化但结果未确认；`submitted` 仅表示系统调用已提交；短信全部分段收到成功回执后为 `sent`，不代表接收方送达；任一分段失败为 `failed`；系统调用异常为 `unknown`。拨号提交不代表呼叫接通。后续通过 `query.device.operation` 查询，不能因超时换新 ID 自动重发。

接口不会上传原有完整配置，也不会暴露 SMTP 密码、HTTP Token 或设备私钥。系统权限或本地操作开关关闭时返回明确错误。现有局域网 HTTP 控制继续使用独立的启用开关。

## 验证

在 `apps/android` 执行：

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
cd android
./gradlew testDebugUnitTest
```

Windows 使用 `gradlew.bat`。若克隆后没有 Gradle wrapper，先执行 `flutter build apk --debug` 让 Flutter 生成本机包装器。APK 不自动安装。正式分发前需要配置独立的 release 签名，现有 debug 签名不作为正式发布凭据。

真机验收需要覆盖 Android Keystore 挑战签名、双 SIM 发送回执、来电与短信查询权限、熄屏 Doze、重启首次解锁、Wi-Fi / 蜂窝网络切换，以及持续 24–72 小时在线与恢复行为。
