# Hako

个人 iPhone 模块化工具箱，Bundle ID：`me.stackli.hako`。SwiftUI + SwiftData，最低 iOS 26.4，Xcode 26.4 或更新版本。无第三方依赖。首页包含「使用时间」模块；提供原始 Logo 和方形 App 图标。

## 当前功能

- 读取手机当前时区最近 7 个完整自然日（不含今天），按系统的总活动时长统计，汇总各 App 的时长并取前五名。本地已有日期跳过，缺失日期才读取并插入；单日读取失败不阻塞其他日期，已成功记录会保存并同步，失败日期下次重试。
- SwiftData 本地持久化（SQLite）。先保存再上传，网络失败不会删除本地记录；支持单独重试同步。
- GitHub GraphQL `createCommitOnBranch`：`data/screen-time/2026.csv`，每年一份、每天一行；时长单位为秒，共 13 列，包含日期、时区、总时长及 5 组 bundle ID、时长，不导出名称。不足 5 个时留空。
- 读取远端 CSV 后按日期合并、排序；仅补入远端缺失日期，已有日期的整行保持不变；使用 `expectedHeadOid` 校验分支，遇到 `STALE_DATA` 重新读取并合并，最多尝试 3 次；无缺失日期时不重复提交。远端格式错误停止覆盖。
- 新提交由 GitHub 自动签名，返回后检查 `isValid` 和 `wasSignedByGitHub`；如果尚未确认签名，会明确提示数据已提交及对应 commit ID，不冒充已验证。已有提交不重写。提交标题示例：`Update screen-time: 2026-10-08 ~ 2026-10-14`，正文列出本次实际新增日期，单日则仅显示该日期。
- 快捷指令仅提供「获取app使用时间并同步」一个入口，一次完成读取、本地保存和 GitHub 同步。单独重试同步保留在 App 内。
- GitHub Token 仅存储于设备 Keychain，不写入 CSV、UserDefaults 或日志。
- 设置 → 应用更新显示当前版本和构建号，点击「安装最新版」直接发起系统 OTA 安装，确认后下载安装最新构建；「查看下载页面」打开 [Ad Hoc 分发页](https://stacklix.github.io/hako/)，查看版本信息或下载 IPA。
- 使用时间列表优先显示名称；名称字符串不可用时通过系统 `Label(ApplicationToken)` 展示。App token 仅保存在本地，不上传 CSV；名称仅用于 App 内展示，不写入 CSV。

当前处于开发阶段，以当前数据结构为准，不维护旧数据兼容或迁移逻辑。需要调整数据结构时，可清空开发数据后重新采集。

## 首先确认 Apple 的数据访问授权

普通 `DeviceActivityReport` 被沙箱限制，不能把敏感使用时间写出报表扩展。此项目使用 iOS 26.4 的 `DeviceActivityData.activityData(filteredBy:using:)` 官方导出 API。

需要 `com.apple.developer.family-controls` 和 `com.apple.developer.family-controls.app-and-website-usage`，并取得 `approvedWithDataAccess`。工程已声明 entitlement，但声明不等于 Apple 已授予签名权限。付费开发者账号、不上架或个人侧载均不自动保证该权限可用。

Apple 文档说明：开发测试可以使用 Apple 提供的 provisioning profile 在任意地区进行；客户安装要求设备位于欧盟且 Apple Account 地区为欧盟。必须用自己的开发者 Team 和支持该能力的 provisioning profile 真机验证。若无法取得该权限，当前全自动方案不能运行，需另行选择截图识别或手动录入方案；本版本不会假装采集成功。

来源：
- [导出 API 与区域限制](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata%28filteredby%3Ausing%3A%29)
- [数据访问授权](https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess)
- [App and Website Usage entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage)
- [报表扩展隐私沙箱](https://developer.apple.com/documentation/deviceactivity/deviceactivityreport)
- [GitHub GraphQL 提交与自动签名](https://docs.github.com/en/graphql/reference/commits)

## 安装及配置

1. 打开 `Hako.xcodeproj`，选择 Hako target → Signing & Capabilities → 自己的付费开发者 Team。使用匹配上述两个 entitlement 的开发描述文件。若签名报错，先解决开发者后台权限/profile，不能简单删除 entitlement 后宣称可导出。
2. 连接 iPhone，开启开发者模式，选择该设备并 Run。无需 App Store。
3. App → 使用时间 → 获取app使用时间并同步；首次点击会请求系统授权，获准后继续读取、保存和同步。已有数据导出授权时不会重复请求；拒绝或授权不足时停止并提示原因。授权由读取操作触发，设置页提供 GitHub 配置和应用更新入口。
4. 准备已初始化的 GitHub 仓库（例如创建时添加 README），同步使用设置中填写的分支，默认值为 `master`，该分支需已存在。创建 fine-grained PAT，仅授予目标仓库 Contents: Read and write。
5. 在 App 内填写仓库地址（例如 `https://github.com/stackli/personal-data`）、分支及 Token。所有数据统一放在仓库的 `data/` 下，子目录由各模块调用同步时传入，使用时间模块传入 `screen-time`，其他模块可使用自己的目录，支持带 `.git` 后缀的 HTTPS 仓库地址。不要将 Token 发到聊天或提交进仓库。点击右上角对勾保存。
6. 使用时间 → 获取app使用时间并同步。确认本地记录及仓库年度 CSV。
7. 快捷指令 → 添加操作 → 搜索 Hako → 获取app使用时间并同步。可在个人自动化设每天早晨运行，并选择系统允许的立即运行模式。首次授权必须在 App 前台完成。安装此版本后，先在 App 内成功运行一次，以记录曾取得数据访问授权；之后后台冷启动遇到初始 `notDetermined` 时，会先调用系统授权 API 刷新，再检查权限。该标记不代替系统授权；后台刷新失败会提示解锁重试或回到 App 处理。

重启后需先解锁一次才能访问 Keychain。后台运行和系统数据就绪时机受 iOS 控制；若数据未就绪或任务被终止，稍后重试。没有数据时明确报错，不将空数据写成零。采集使用 `.live` 策略；每次补采最近 7 天中缺失的日期；没有按天后台调度服务，定时触发由快捷指令负责。

按当前时区定义最近 7 个完整自然日，按日期判断是否存在；跨时区运行也不覆盖已有日期；这是面向单用户单手机的模型。总时长直接使用系统 segment 的 totalActivityDuration，不把 App 与网站时长相加。App 排行按 bundle ID 聚合；同秒时按 bundle ID 排序。

## 验证

### 一键安装到 iPhone

连接并解锁已配对的 iPhone，在项目目录执行：

```sh
./scripts/install.sh
```

脚本自动选择唯一连接的 iPhone，使用工程现有 Team 编译并签名，安装后打开 Hako。支持 Xcode 已配置的无线设备连接。首次仍需在 Xcode 登录账号并配置好签名能力；脚本会允许 Xcode 更新所需开发描述文件，不能自动获得 Apple 尚未授予的 entitlement。

```sh
./scripts/install.sh --list                    # 查看设备
./scripts/install.sh --device "你的 iPhone 名称" # 多设备时指定，也支持 UDID
./scripts/install.sh --no-launch               # 安装后不自动打开
./scripts/install.sh --build-only              # 只编译签名
```

增量构建及日志位于被 Git 忽略的 `build/install/`。编译失败不会继续安装；详细日志见 `build/install/build.log`。

无签名编译：

```sh
xcodebuild -project Hako.xcodeproj -scheme Hako -sdk iphoneos -configuration Debug -derivedDataPath /tmp/hako-build CODE_SIGNING_ALLOWED=NO build
```

在 Apple Silicon Mac 上运行核心和模拟网络测试（无真实 GitHub 写入）：

```sh
swiftc -target arm64-apple-macos14.0 Hako/Models.swift Hako/CSV.swift Tests/CoreTests.swift -o /tmp/hako-core-tests
/tmp/hako-core-tests
swiftc -target arm64-apple-macos14.0 Hako/Models.swift Hako/CSV.swift Hako/GitHub.swift Tests/GitHubTests.swift -o /tmp/hako-github-tests
/tmp/hako-github-tests
```

真机验收：核对系统「屏幕使用时间」最近 7 天每天的总量与 Top 5；重跑确认数据库/CSV 已有日期不变；核对跨年时生成对应年份文件；断网运行确认本地留存，恢复网络后重试；通过快捷指令实际触发。无签名构建与模拟测试不代表上述真机能力已经验证。

## GitHub Actions 自动打包与安装页

默认分支 push 后自动导出签名 IPA，发布 GitHub Pages 安装页。首次需配置证书、描述文件 Secrets 和 Pages，详见 [自动打包与网页安装](docs/ci-install.md)。
