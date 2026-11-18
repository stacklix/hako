# Doppel

Doppel 是一个个人 Android/Flutter 应用，用于接收短信和来电事件，并按配置把事件转发到短信、邮箱或 HTTP 目标。它也支持来自白名单号码的短信指令，用于触发拨号或代发短信。

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
  platform/doppel_platform.dart     doppel/platform 平台通道封装
  pages/                            首页、转发、指令、日志、设置页面
  widgets/                          页面复用控件和弹窗

android/app/src/main/
  AndroidManifest.xml               权限、Activity、Receiver 声明
  kotlin/me/stackli/doppel/
    MainActivity.kt                 平台通道、权限请求、快照构建
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

使用本地 Flutter SDK：

```bash
/Users/liqiao/sdk/flutter/bin/flutter pub get
/Users/liqiao/sdk/flutter/bin/flutter analyze
/Users/liqiao/sdk/flutter/bin/flutter test test/widget_test.dart
/Users/liqiao/sdk/flutter/bin/flutter build apk --debug
```

如需运行到设备，可使用：

```bash
/Users/liqiao/sdk/flutter/bin/flutter run
```

不要默认执行 `adb install`。需要安装 APK 到手机时，请由使用者手动安装，或在明确需要时再执行。

### 远程 HTTP 页面

远程 HTTP 管理页使用 React、Tailwind CSS 和 shadcn/ui 风格组件实现，源码位于 `remote-ui/`，构建产物会输出到 Android assets 的 `android/app/src/main/assets/remote/`。

修改远程页面后，先构建静态资源：

```bash
npm run build:remote
```

`npm run build:remote` 会把远程 HTTP 页面打包到 `android/app/src/main/assets/remote/`。随后再构建 Android APK，这些静态资源会随 Android assets 一起进入 APK。

调试包：

```bash
npm run build:remote
/Users/liqiao/sdk/flutter/bin/flutter build apk --debug
```

发布包：

```bash
npm run build:remote
/Users/liqiao/sdk/flutter/bin/flutter build apk --release
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
