# Hako iOS

个人 iPhone 模块化工具箱，Bundle ID：`me.stackli.hako`。SwiftUI + SwiftData，最低 iOS 26.4，Xcode 26.4 或更新版本。无第三方依赖。首页包含「使用时间」模块；提供原始 Logo 和方形 App 图标。

本目录为 Hako 的 iOS 应用，以下命令均从 `apps/ios/` 执行。在仓库根目录先运行 `cd apps/ios`。返回 [仓库说明](../../README.md)。

## 当前功能

- 「容器管理」子应用：直接连接已有 Arcane 服务，独立配置地址和 API Key（仅保存于本机 Keychain），支持多 Docker 环境、完整分页、搜索与状态／更新筛选、Compose 分组、容器详情、CPU／内存使用率和网络上下行速率、实时日志与日志导出、启停重启及删除。更新入口为「拉取镜像并重新部署」，重建后跟随新容器 ID；写操作超时不自动重试，需先刷新状态核对。按 Arcane v2.17.1 接口实现，权限、HTTP 选项和验收说明见 [Arcane 容器管理](../../docs/arcane.md)。

- 设备详情底部固定“查询 / 操作”页签，各能力通过折叠列表展示，同时最多展开一项。Codex 合并为一项，处理中会话放在顶部，以小标题和数量徽标分组，每个会话卡片先显示项目名、再显示会话标题，下方以双轴分组柱状图显示最近 7 天用户调用数和 token 总量；点击柱子以浮层及图下读数显示当天完整数字，不显示每日详情表格。历史用量提示与时区、采集时间放在默认折叠的“数据说明”中。每次发送任务/消息计 1 次，不累计内部模型迭代，旧 Agent 未标明用户调用口径时提示更新。按设备时区统计，旧版估算、明细缺失和运行状态不可用均明确提示；需更新支持此能力的 Windows Agent，服务端无需新增业务接口。详见 [Codex 用量采集](../../docs/codex-usage.md)。

- 设置交互：设置页只展示功能入口、应用更新和构建状态，不提供保存按钮。「服务器与登录」「扫码登录」「GitHub 配置」均以 sheet 打开；服务器和 GitHub 配置只在点击右上角勾号后保存，保存成功关闭 sheet，验证或保存失败则保留输入。点击关闭或下拉关闭有修改的配置 sheet 时，弹窗选择继续编辑或放弃并关闭；输入不会自动保存。扫码 sheet 只提供关闭按钮，网页登录仍须在核对页明确确认。设备监控与扫码页中的服务器配置快捷入口也使用同一 sheet。
- Hako 主应用服务：在「设置 → 扫码登录」批准 Hako 网页登录；在「设置 → 服务器与登录」配置服务器、账号、本机公钥及登录管理。使用 Secure Enclave P-256 密钥，公钥在服务端文件登记后签名登录。所有 Console 都是管理员，无密码或 TOTP；本机凭据自动续期直到退出或撤销。「已登录设备」统一显示 Console 和有效网页会话，支持下拉刷新和单独移除网页登录；Console 项仅查看，不提供远程撤销入口，本机退出在「服务器与登录」操作。已登录时点击「扫码登录」打开相机，也可粘贴并解析请求；未配置、未登录或凭据待验证时先引导服务器配置与登录，验证后自动进入扫描。核对服务器、来源 IP 及两端确认码后确认或拒绝，无需额外 Face ID、Touch ID 或设备密码。相机权限只在打开扫描器时申请，相机不可用仍可粘贴；只接受当前服务器的请求，批准仅对原浏览器有效。共用连接、身份、会话及扫码代码位于 `Hako/Server/`，沿用已有 Keychain 与配置键，升级保留身份和会话。部署见 [服务端说明](../server/README.md)，协议见 [Hako 服务器认证协议](../../docs/server-authentication.md)。
- 「设备监控」子应用：复用主应用的 Hako 服务器登录，支持 Agent 登记、设备在线状态、CPU/内存查询和按设备能力调用。通过通用 `/agents/{id}/requests` 调用 `query.all` v1 并读取能力清单，需要搭配 WebSocket v3 服务端与 Windows Agent。协议见 [设备监控协议](../../docs/device-monitoring.md)。

- 读取手机当前时区最近 7 个完整自然日（不含今天），按系统的总活动时长统计，汇总各 App 的时长并取前五名。本地已有日期跳过，缺失日期才读取并插入；单日读取失败不阻塞其他日期，已成功记录会保存并同步，失败日期下次重试。
- SwiftData 本地持久化（SQLite）。采集汇总完成后，总时长及各 App 时长先四舍五入到整数秒再保存，GitHub 恢复的新记录也使用相同精度。先保存再上传，网络失败不会删除本地记录；「合并本地与 GitHub 记录」按日期双向补齐，并将合并结果保存到本地，无需屏幕使用时间授权。
- GitHub GraphQL `createCommitOnBranch`：`data/screen-time/2026.csv`，每年一份、每天一行；时长单位为秒，共 13 列，包含日期、时区、总时长及 5 组 bundle ID、时长，不导出名称。不足 5 个时留空。
- 读取远端 CSV 后按日期合并、排序；仅补入远端缺失日期，已有日期的整行保持不变；使用 `expectedHeadOid` 校验分支，遇到 `STALE_DATA` 重新读取并合并，最多尝试 3 次；无缺失日期时不重复提交。远端格式错误停止覆盖。
- 单独合并会扫描 `data/screen-time/` 下全部年度 CSV，合并远端年份与本地年份；本地为空或缺少整年时也能恢复历史记录。本地独有日期补到 GitHub，远端独有日期保存到本地；同一天内容冲突时以 GitHub 整行记录为准，保留匹配 bundle ID 的本地 App 名称和 token。每个年度成功后保存，后续年度失败不会丢失已经保存的记录；双方均为空时提示先采集。无效日期、时区或时长会停止该年度合并。
- 合并结果分别显示本地新增、GitHub 新增、本地更新的天数。时长按 CSV 的整数秒精度比较；历史本地记录仅小数精度、App 名称或 token 不同不算更新，也不覆盖这些相同的历史记录。数据相同时本地更新为 0；GitHub 新增仅统计本次成功提交补入的日期，并发重试时其他写入者补入的日期不计入。
- 新提交由 GitHub 自动签名，返回后检查 `isValid` 和 `wasSignedByGitHub`；如果尚未确认签名，会明确提示数据已提交及对应 commit ID，不冒充已验证。已有提交不重写。提交标题示例：`Update screen-time: 2026-10-08 ~ 2026-10-14`，正文列出本次实际新增日期，单日则仅显示该日期。
- 快捷指令仅提供「获取app使用时间并同步」一个入口，一次完成读取、本地保存和 GitHub 同步。双向合并入口保留在 App 内。
- GitHub Token 仅存储于设备 Keychain，不写入 CSV、UserDefaults 或日志。
- 设置页显示 `stacklix/hako` 主分支最新 GitHub Actions 构建状态、打包/部署任务及当前步骤；仅在设置页打开且 App 在前台时拉取，关闭设置页、打开设置 sheet 或 App 进入后台即取消请求和轮询；有排队、等待或执行中的任务时每 5 秒刷新，无任务或最新任务已结束时每 30 秒刷新，失败后退避至 120 秒，可手动刷新或打开 GitHub。私有源码仓库要求已保存的 Token 额外具备该仓库的 Actions 读取权限。构建进度与已发布的可安装版本分别显示。
- 设置 → 应用更新显示当前版本和构建号。仅当已发布构建号高于当前安装版本时显示绿色图标的「安装最新版」，同行展示最新版本号和构建号，下一行展示本地时区的构建时间；点击直接发起系统 OTA 安装。「查看下载页面」始终保留，可打开 [Ad Hoc 分发页](https://stacklix.github.io/hako/) 查看版本信息或下载 IPA。
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

「设备监控」主页进入时验证会话并更新设备列表，此后每 10 秒自动刷新设备及在线状态，不显示刷新按钮或 loading 行；离开主页、打开添加 Agent 或服务器配置 sheet，或 App 进入后台时停止轮询，返回前台主页后恢复。主页「添加 Agent」下一行保留共享的「服务器与登录」快捷入口，未配置或未登录时也可进入；扫码入口统一位于 Hako 主应用设置页。列表和详情均支持下拉刷新，保留系统原生反馈。单台设备详情右上角保留刷新按钮，请求期间图标旋转，页面内容不插入 loading 行，已有数据保持显示；完成或失败后停止旋转，失败保留错误提示。开启系统“减弱动态效果”时不旋转，辅助功能仍可读取刷新状态。详情直接调用一次 `query.all` 获取查询数据，不再先请求设备列表。进入详情时自动执行同样的查询，离线或不支持的动作由服务端返回提示，不使用列表中的旧状态阻止刷新；设备重新上线后可直接在详情刷新，无需返回列表。

设备列表中的离线设备保留名称、设备 ID 和离线状态，禁用详情入口；列表刷新为在线后恢复进入详情。已进入详情后断线仍保留当前页面及刷新能力。

Hako 主应用冷启动及返回前台时自动验证已保存的登录凭据，不加载设备列表；进入设备监控后验证会话并单独加载设备。页面显示状态或前后台状态变化引发任务重启时，后续调用复用正在进行的验证，请求不会随原页面任务取消。验证期间显示静态状态说明，不显示 loading 动画；正常的网络请求取消不作为错误展示。真实网络故障保留凭据和错误提示，由主页后续轮询或手动操作重试，仍需服务端验证成功才进入已登录状态。

登录 Hako 服务器后，点击「添加 Agent」，只需填写设备名称，粘贴或从文件导入 Agent 导出的 PEM 公钥。确认表单中的服务器和账号后点击「添加」，服务端自动生成 5 位设备 ID（大写字母和数字，以字母开头，例如 `A7K2Q`），公钥立即登记并刷新设备列表，无需打开网页或重启服务端；在对应设备的 Agent 中重新连接即可上线。名称最多 100 个 UTF-8 字节，公钥需为 RSA 2048–8192 位。私钥会在本地阻止提交；重复公钥及其他错误保留表单供修改。网络失败时先刷新设备列表确认是否已登记，避免重复提交。此功能需要同步更新服务端；iOS 本机 Console 公钥仍需事先在服务端文件登记。

主应用公钥入口为「设置 → 服务器与登录 → 本机设备身份 → 查看与导出公钥」。打开 sheet 后显示完整 PEM 公钥和设备 ID，可选中文本、复制公钥内容或导出 `iphone.public.pem` 文件。无需填写服务器地址、账号，也无需联网或登录；首次自动生成并保存本机 Secure Enclave 密钥，重复导出复用已有身份。之后填写连接信息并点击 sheet 右上角勾号保存，新服务器使用已准备的设备身份。升级后保留已有服务器绑定的密钥，不重新生成。

已有密钥时，同一区域显示独立的红色「重置密钥对」入口，打开专用确认 sheet，仅显示重置说明、确认和取消；公钥查看 sheet 不包含重置操作，重置 sheet 不包含公钥复制或导出。再次点击红色「确认重置密钥对」才会生成并保存新密钥，退出本机 Hako 服务器登录并清理旧身份和会话凭据；取消或关闭不会重置。重置成功后返回设置，可再打开「查看与导出公钥」获取新公钥。旧密钥不可恢复。重置可离线完成，之后需重新导出公钥，手工替换服务端旧公钥并重启，才能重新登录；服务端及关联网页会话会在旧公钥移除并重启后失效。生成、导出校验或保存失败时保留原密钥。新身份的保存与重置标记一同提交，清理中断也不会让旧服务器绑定恢复旧密钥。

1. 打开 `Hako.xcodeproj`，选择 Hako target → Signing & Capabilities → 自己的付费开发者 Team。使用匹配上述两个 entitlement 的开发描述文件。若签名报错，先解决开发者后台权限/profile，不能简单删除 entitlement 后宣称可导出。
2. 连接 iPhone，开启开发者模式，选择该设备并 Run。无需 App Store。
3. App → 使用时间 → 获取app使用时间并同步；首次点击会请求系统授权，获准后继续读取、保存和同步。已有数据导出授权时不会重复请求；拒绝或授权不足时停止并提示原因。授权由读取操作触发，设置页提供 GitHub 配置和应用更新入口。
4. 准备已初始化的 GitHub 仓库（例如创建时添加 README），同步使用设置中填写的分支，默认值为 `master`，该分支需已存在。创建 fine-grained PAT，仅授予目标仓库 Contents: Read and write。
5. 在「设置 → GitHub 配置」sheet 内填写仓库地址（例如 `https://github.com/stackli/personal-data`）、分支及 Token。所有数据统一放在仓库的 `data/` 下，子目录由各模块调用同步时传入，使用时间模块传入 `screen-time`，其他模块可使用自己的目录，支持带 `.git` 后缀的 HTTPS 仓库地址。不要将 Token 发到聊天或提交进仓库。点击 sheet 右上角对勾才会保存，设置主页没有保存按钮。
6. 使用时间 → 获取app使用时间并同步。确认本地记录及仓库年度 CSV。
7. 快捷指令 → 添加操作 → 搜索 Hako → 获取app使用时间并同步。可在个人自动化设每天早晨运行，并选择系统允许的立即运行模式。首次授权必须在 App 前台完成。后台冷启动的授权状态初始为 `notDetermined`，快捷指令会先调用系统授权 API 刷新，再检查是否取得数据访问权限，不依赖本地“曾授权”标记。后台刷新失败会提示解锁重试或回到 App 完成授权。

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

最终可安装 App 统一输出到仓库根目录 `dist/ios/Hako.app`；CI 导出的 IPA 位于 `dist/ios/Hako.ipa`，网页安装产物位于 `dist/ios/site/`。Windows 本机跳过 iOS 编译、签名和安装。

无签名编译：

```sh
xcodebuild -project Hako.xcodeproj -scheme Hako -sdk iphoneos -configuration Debug -derivedDataPath /tmp/hako-build CODE_SIGNING_ALLOWED=NO build
```

在 Apple Silicon Mac 上运行核心和模拟网络测试（无真实 GitHub 写入）：

```sh
swiftc -target arm64-apple-macos14.0 Hako/Models.swift Hako/CSV.swift Tests/CoreTests.swift -o /tmp/hako-core-tests
/tmp/hako-core-tests
swiftc -target arm64-apple-macos14.0 Hako/Models.swift Hako/CSV.swift Hako/GitHub.swift Hako/UsageSync.swift Hako/BuildStatus.swift Tests/GitHubTests.swift -o /tmp/hako-github-tests
/tmp/hako-github-tests
```

真机验收：核对系统「屏幕使用时间」最近 7 天每天的总量与 Top 5；重跑采集确认数据库/CSV 已有日期不变；核对跨年时生成对应年份文件；点击「合并本地与 GitHub 记录」确认空本地恢复、跨年历史恢复及双方缺失日期互补，同日冲突以 GitHub 为准，重复合并不产生提交；断网运行确认本地留存，恢复网络后重试；通过快捷指令实际触发。核心和模拟网络测试已接入 GitHub Actions。无签名构建与模拟测试不代表上述真机能力已经验证。

## GitHub Actions 自动打包与安装页

仅当默认分支推送包含 `apps/ios/` 目录下的文件变化时，自动导出签名 IPA，发布 GitHub Pages 安装页；也可手动运行。首次需配置证书、描述文件 Secrets 和 Pages，详见 [自动打包与网页安装](../../docs/ios/ci-install.md)。
