# Nami

Nami 是 Android 应用的产品名称。Android application ID、原生包路径、平台通道和已有存储标识沿用既有值，覆盖升级可保留设备密钥、配置及系统授权。

本应用已纳入 Hako，目录为 `apps/android`。Android Agent 的接入、命令和验证说明见 [Android Agent](../../docs/android-agent.md)。在「系统设置 → Nami Agent」生成设备公钥并登记到 Hako，配置服务器和账号后启用。远程短信、拨号各自需要在手机上开启，默认关闭。

应用 ID 为 `me.stackli.doppel`，显示名为 `Nami`。与原版使用相同 ID；签名不同时，需要先备份并卸载旧版再安装，系统权限需重新授权。

`query.all` 与实时订阅仅包含当前状态；短信、通话和操作记录使用独立查询，不参与状态聚合。Agent 连接和执行均位于 Kotlin 层，Flutter 界面退出后前台服务继续运行。

Nami 是一个个人 Android/Flutter 应用，用于接收短信和来电事件，并按配置把事件转发到短信、邮箱或 HTTP 目标。它也支持来自白名单号码的短信指令，用于触发拨号或代发短信。

## 主要功能

- 接收短信广播并记录短信事件。
- 监听来电状态并记录来电事件。
- 将普通短信转发到已启用的手机号、邮箱和 HTTP Webhook。
- 将来电通知转发到已启用的手机号和邮箱。
- 支持选择用于转发短信的 SIM 卡。
- 支持配置 SMTP 发件信息和邮箱收件人。
- 支持白名单短信指令：
  - CALL 指令：按配置权限发起拨号。
  - SMS 指令：按配置权限发送短信。
- 在应用内展示运行状态、事件指标、转发配置、指令配置和日志。

## 项目结构

```text
lib/
  main.dart                         Flutter 入口
  app.dart                          应用壳、页面导航、快照刷新和权限提示
  models/app_models.dart            UI 使用的数据模型
  platform/nami_platform.dart     doppel/platform 平台通道封装
  pages/                            首页、转发、指令、日志、设置页面
  pages/agent_settings_page.dart     Nami Agent 连接、密钥和操作权限
  widgets/                          页面复用控件和弹窗

android/app/src/main/
  AndroidManifest.xml               权限、Activity、Receiver 声明
  kotlin/me/stackli/doppel/
    MainActivity.kt                 平台通道、权限请求、快照构建
    agent/                          独立守护连接、私有 Binder、命令和持久化回执
    SmsReceiver.kt                  短信广播接收
    PhoneStateReceiver.kt           电话状态广播接收
    SmsProcessingWorker.kt          短信后台任务
    CallProcessingWorker.kt         来电后台任务
    SmsPipeline.kt                  去重、指令、转发和事件写入主流程
    SmsSentReceiver.kt              短信发送结果处理
    DoppelEvents.kt                 原生广播 action 和 extra 常量
```

## 数据流

1. Android 系统广播触发 `SmsReceiver` 或 `PhoneStateReceiver`。
2. Receiver 把事件交给 WorkManager 后台任务。
3. `SmsPipeline` 读取配置、去重、识别短信指令，并执行转发或指令动作。
4. 配置和事件写入 Android `SharedPreferences`，名称为 `doppel`。
5. Flutter 通过 `doppel/platform` 调用 `getSnapshot` 读取权限、配置、SIM 卡和事件。
6. 原生侧数据变化后发送 `me.stackli.doppel.action.SNAPSHOT_CHANGED`，再通过 `snapshotChanged` 推送给 Flutter。

## 配置与存储

- 配置 key：`config_json`
- 事件 key：`events_json`
- 平台通道：`doppel/platform`
- 主要通道方法：
  - `getSnapshot`
  - `saveConfig`
  - `requestRequiredPermissions`

实时短信事件应尽量包含：

- `type`
- `timestamp`
- `detail`
- `from`
- `to`
- `content`

## 权限

应用当前会用到以下 Android 能力：

- 接收、读取和发送短信
- 读取电话状态和本机号码
- 读取通话记录
- 发起电话呼叫
- 网络访问，用于 HTTP 和 SMTP 转发

首次进入应用时，如果必要权限未授予，Flutter 页面会提示用户授权。权限请求和权限状态由 `MainActivity.kt` 与 `PlatformPermissions` 共同维护。

## 本地开发

### 系统设置快捷入口

手机内的“系统设置 → 后台运行与系统设置”提供开机自启动、后台省电策略、电池优化、通知设置及应用权限与详情入口。自启动和应用省电策略目前支持检测小米系统对应页面，入口不可用时会说明从应用详情查找；其余入口使用 Android 系统设置页面。

快捷入口只打开设置页，具体开关由用户在系统页面中确认。应用不推测自启动是否已开启，返回后会刷新可以读取的电池优化、通知和权限状态。

使用本地 Flutter SDK：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

如需运行到设备，可使用：

```bash
flutter run
```

不要默认执行 `adb install`。需要安装 APK 到手机时，请由使用者手动安装，或在明确需要时再执行。

### 远程 HTTP 页面

远程 HTTP 管理页使用 React 和 Lucide 图标实现，源码位于 `remote-ui/`，构建产物会输出到 Android assets 的 `android/app/src/main/assets/remote/`。页面沿用确认的原型样式，左侧菜单为首页、配置、操作和日志；配置包含转发配置、指令配置和连接配置。

转发目标和可信号码通过弹窗添加，SMTP、HTTP 认证及 Hako 连接配置默认为显示态，通过编辑弹窗修改。短信指令与 HTTP 指令保留在同一指令配置页。连接配置用于连接 Hako 服务端，可生成设备密钥、查看和复制公钥，以及设置 Hako 远程操作权限。

Nami 网页配置复用手机设置页的原生存储和 Android Keystore：`GET/POST /api/agent/settings` 读取或保存配置，`POST /api/agent/key` 在密钥不存在时生成密钥。接口沿用 HTTP 管理服务的登录态或 Token 鉴权，响应只含公钥，不导出私钥。

修改远程页面后，先构建静态资源：

```bash
npm run build:remote
```

构建后运行网页交互检查（需要本机 Chrome，也可通过 `CHROME_BIN` 指定路径）：

```bash
python test/remote_ui_browser_test.py
```

检查使用独立无头浏览器配置，在 1056、430、320 像素视口中运行生产构建，验证登录、配置保存、失败草稿保留、公钥复制、操作和日志。请求使用内存模拟数据，不连接手机、不发送短信或拨号。

`npm run build:remote` 会把远程 HTTP 页面打包到 `android/app/src/main/assets/remote/`。随后再构建 Android APK，这些静态资源会随 Android assets 一起进入 APK。

调试包：

```bash
npm run build:remote
flutter build apk --debug
```

发布包：

```bash
npm run build:remote
flutter build apk --release
```

如果只修改了 `remote-ui/` 下的网页代码，也需要重新执行 `npm run build:remote`，否则 APK 中仍然会使用上一次生成的远程页面资源。

需要在电脑上快速调试页面时，可以启动 mock 服务：

```bash
DOPPEL_MOCK_PORT=18082 node test/remote_control_mock_server.js
```

然后访问：

```text
http://127.0.0.1:18082/
```

mock 登录密码为 `dev`。如果端口被占用，可以把 `DOPPEL_MOCK_PORT` 改成其他端口。

真机使用时，需要先在手机 App 中开启远程 HTTP 控制，并确保手机和访问端在可互通的网络中。开启后访问：

```text
http://手机IP:配置端口/
```

远程 HTTP 接口对外可访问，但需要使用页面登录态或接口 token；不要把管理密码、token 或完整授权头写入日志和文档。

## 开发注意事项

- Flutter/Dart 侧聚焦 UI、配置表单、日志展示和平台通道封装。
- Android/Kotlin 侧负责短信、来电、WorkManager、SIM 卡、短信发送结果、短信历史和通话记录等系统集成。
- 不要把后台短信 / 来电处理迁移到 Dart，除非明确接受 Flutter engine / isolate 带来的复杂度和可靠性取舍。
- 修改转发目标或配置结构时，要同步更新 Dart 模型、Flutter 表单、Kotlin JSON 读取和快照映射。
- 应用内日志应展示业务事件，避免暴露 SMTP 协议步骤、WorkManager 生命周期噪声或目标数量内部细节。
- 不要记录 SMTP 密码、认证 token、完整 HTTP 凭据或完整授权头。
