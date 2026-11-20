# AGENTS.md

本文件给在 Nami 仓库中工作的编码代理使用。请以当前代码为准，保持修改小而清晰，优先维护 Android 原生后台能力与 Flutter UI 展示之间的边界。

## 项目现状

Nami 是一个个人 Android/Flutter 应用，用于接收短信和来电事件，并按配置转发到短信、邮箱或 HTTP 目标。

- 应用名：`Nami`
- Android application id / namespace：`me.stackli.doppel`
- Flutter 入口：`lib/main.dart`
- Flutter 应用壳：`lib/app.dart`
- Flutter 页面：`lib/pages/overview_page.dart`、`forwarding_page.dart`、`commands_page.dart`、`logs_page.dart`、`settings_page.dart`
- Flutter 数据模型：`lib/models/app_models.dart`
- Flutter 平台通道封装：`lib/platform/nami_platform.dart`
- Android 原生代码：`android/app/src/main/kotlin/me/stackli/doppel`
- 平台通道名：`doppel/platform`

## 工作方式

- 先读相关代码再改，不要只根据 README 判断行为；当前 README 仍是 Flutter 模板内容。
- 搜索使用 `rg`。
- 手动编辑文件使用 `apply_patch`。
- 保持改动聚焦，不做顺手重构、格式化大面积无关文件或调整生成文件。
- 不要回退用户已有改动或本地生成状态，除非用户明确要求。
- 不要自动安装 APK 到设备；只有用户明确要求时才运行 `adb install`。
- 不要把 SMTP 密码、认证 token、HTTP 密钥或完整凭据写入日志、测试输出或文档。

## 验证命令

使用本机已配置且满足 `pubspec.yaml` 的 Flutter SDK：

```bash
flutter analyze
flutter test
flutter build apk --debug
```

如只修改文档，可以不运行 Flutter 验证，但最终说明中要说清楚。除非用户明确要求，不运行 `adb install`。

## 代码边界

Flutter/Dart 侧负责 UI、展示状态和配置表单：

- `NamiApp` / `NamiHome` 维护页面导航、权限提示、快照刷新和指标汇总。
- `NamiPlatform` 只封装 `MethodChannel` 调用和 `snapshotChanged` 回调。
- `app_models.dart` 定义配置、权限、SIM 卡、日志事件等 UI 可消费模型。
- 页面和 widget 负责配置编辑、日志展示、长内容查看、表单校验和用户文案。

Android/Kotlin 侧负责系统集成和后台业务：

- `MainActivity.kt` 提供 `getSnapshot`、`saveConfig`、`requestRequiredPermissions`，并把原生快照推给 Flutter。
- `SmsReceiver.kt` 和 `PhoneStateReceiver.kt` 接收系统广播。
- `SmsProcessingWorker.kt` 和 `CallProcessingWorker.kt` 通过 WorkManager 后台处理事件。
- `SmsPipeline.kt` 负责去重、指令解析、短信转发、邮件转发、HTTP 推送、来电通知和业务事件写入。
- `SmsSentReceiver.kt` 处理短信发送结果。
- `DoppelEvents.kt` 保存原生广播 action 和 extra 常量。

不要把短信 / 来电后台处理迁移到 Dart，除非用户明确接受 Flutter engine / isolate 带来的复杂度和可靠性取舍。

## 数据与配置

- 原生配置和事件保存在 Android `SharedPreferences`，名称为 `doppel`。
- 配置 key 为 `config_json`，事件 key 为 `events_json`。
- Flutter 通过 `getSnapshot` 获取 `permissions`、`config`、`simCards`、`events`。
- Flutter 保存配置时调用 `saveConfig`，原生侧会把传入 JSON 合并到已有配置。
- 快照变化通过 `me.stackli.doppel.action.SNAPSHOT_CHANGED` 广播触发，并经 `snapshotChanged` 推送到 Flutter。
- 实时短信事件尽量包含 `type`、`timestamp`、`detail`、`from`、`to`、`content`。
- `MainActivity` 会读取最近短信历史用于快照展示；不要随意新增迁移或回填逻辑，除非用户要求。

## 权限与系统能力

`AndroidManifest.xml` 当前涉及短信、电话、通话记录、电话状态、号码读取和网络权限。处理相关功能时要同时关注：

- 运行时权限请求：`MainActivity.REQUIRED_PERMISSIONS`
- 权限状态映射：`PlatformPermissions`
- Manifest 中的 receiver、action、exported 设置
- Android 版本差异，例如 receiver 注册 flag、电话号读取能力、SIM 卡信息读取限制

如果改动包名或应用身份，必须同步更新：

- `android/app/build.gradle.kts` 的 `namespace`
- `android/app/build.gradle.kts` 的 `applicationId`
- Kotlin package 声明和源码目录
- `DoppelEvents.kt` 中显式 action 字符串
- `AndroidManifest.xml` 中对应 action 和组件声明

修改 `applicationId` 会让 Android 把它视为新应用，已有权限和 SharedPreferences 不会自动继承。

## 日志约定

- 应用内日志页应以业务事件为主，避免暴露底层流水线噪声。
- 适合进入 UI 的事件包括短信收到、来电收到、短信转发提交 / 成功 / 失败、HTTP 转发完成 / 失败、指令未执行等用户能理解的结果。
- Logcat 可以包含更细的转发流程诊断，例如目标数量、启用目标数量、跳过原因、发送提交摘要。
- 不要在 UI 日志中显示 SMTP `EHLO`、`AUTH`、`RCPT`、`DATA` 等协议步骤。
- 永远不要记录 SMTP 密码、认证 token、完整 HTTP 凭据或完整授权头。

## 转发与指令行为

- 普通短信由 `SmsPipeline.processIncomingSms` 记录并转发到已启用的短信、邮箱和 HTTP 目标。
- 来电由 `SmsPipeline.processIncomingCall` 记录并转发通知到短信和邮箱目标。
- 短信指令只应对白名单号码生效，白名单权限由 `TrustedNumber` / `CommandsConfig` 建模。
- 短信发送卡选择依赖 `selectedSmsSim` 与 `SubscriptionManager` 的匹配结果。
- 修改转发目标结构时，要同步更新 Dart 模型、Flutter 表单、Kotlin JSON 读取和快照映射。

## UI 约定

- 当前 UI 使用 Material 主题，主色为 `0xFF0F766E`，卡片圆角为 8。
- 页面逻辑应尽量留在 `lib/pages`，可复用控件放在 `lib/widgets`。
- 不要把平台通道调用散落到页面中，优先通过 `NamiPlatform`。
- 面向用户的中文文案保持简洁，错误提示要说明用户能采取的动作。
- 日志和详情展示要兼顾长短信内容，避免单行溢出或截断后不可查看。

## 依赖与构建

- Dart 依赖当前很少，新增 package 前先确认是否真的需要。
- Android 侧当前使用 `androidx.work:work-runtime-ktx`。
- `android/app/build.gradle.kts` 中如发现重复依赖块，修改时要小心验证 Gradle 行为。
- 不要提交本地机器专属配置、签名文件、密钥或临时构建产物。

## Hako Android Agent

- Agent 原生代码在 `android/app/src/main/kotlin/me/stackli/doppel/agent`，配置通过 `NamiPlatform` 和 `AgentSettingsPage` 管理。
- 独立 `:agent` 守护进程只处理连接与认证；`query` / `action` 经 App 私有 Binder 交给主进程，不在守护进程直接执行。跨进程配置和状态使用带独占锁的原子文件，不使用 SharedPreferences 缓存通信。
- `query.all` 和实时订阅只能读取当前状态，不聚合短信、通话记录、操作记录等历史数据。历史查询独立分页。
- 服务端仅做鉴权和通用转发，不为 Android 命令新增服务端白名单、参数解释或专用业务路由。
- 私钥保存在 Android Keystore，不返回 Flutter，不写日志或导出。远程操作默认关闭。
- 发短信、拨号先持久化 `requestId`，相同操作不得重复执行；提交、发送回执、实际接通或送达须如实区分。
- 原生协议与连接测试：在 `android` 目录运行 `./gradlew testDebugUnitTest`，Windows 使用 `gradlew.bat`。
