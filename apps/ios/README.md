# Hako iOS

个人 iPhone 模块化工具箱，Bundle ID：`me.stackli.hako`。SwiftUI + SwiftData，最低 iOS 26.4，Xcode 26.4 或更新版本。容器终端使用 SwiftTerm v1.99.2（Swift Package Manager 固定版本）。首页包含「使用时间」模块；提供原始 Logo 和方形 App 图标。

本目录为 Hako 的 iOS 应用，以下命令均从 `apps/ios/` 执行。在仓库根目录先运行 `cd apps/ios`。返回 [仓库说明](../../README.md)。

## 界面规范

子应用设置入口遵循 [iOS 界面规范](AGENTS.md)：统一在导航栏右上角使用 `slider.horizontal.3` 滑杆图标。

所有表单字段始终显示字段名称（key），填写后也保留；占位文字只提供示例或提示。敏感值继续遮蔽显示，具体布局见同一规范。

## 当前功能

- 「青龙面板」子应用：直接连接已有青龙 OpenAPI，一级 Tab 为任务、脚本、订阅和更多；支持多面板连接、独立两行 Client ID／Client Secret 和可选自定义请求头（默认留空）。支持任务管理与日志、脚本编辑及已保存版本调试、订阅管理；环境变量位于更多，另提供配置文件编辑、只读依赖和日志文件、权限检测。连接与凭据仅存本机 Keychain，沿用黑白主色与原生设置入口。接口、边界和验证见 [青龙面板](../../docs/qinglong.md)。

- 「云服务器」子应用：直接通过阿里云 ECS API 管理一台 Linux 实例，支持无公网终端、概览、整机网络趋势、网卡速率、监听端口、当前连接和进程 CPU / RSS 查询。RAM / STS 凭据仅保存于本机 Keychain；系统快照使用已有云助手、Python 3 与 ss，不新增付费服务、自建接口或第三方采集器。不可提供的流量项目不显示。配置、权限、统计口径和验证见 [阿里云 ECS](../../docs/ecs.md)。

- 「容器管理」子应用：直接连接已有 Arcane 服务，独立配置地址和 API Key（仅保存于本机 Keychain），支持多 Docker 环境、完整分页、搜索与状态／更新筛选、Compose 分组、容器详情、CPU／内存使用率和网络上下行速率、实时日志与日志导出、启停重启及删除。点击环境卡片的主机名称行查看「主机信息」，右侧下拉按钮切换服务器；支持查看本地或远程主机的实时 CPU、内存、磁盘和可用 GPU 指标，以及系统、Docker 信息。「文件」Tab 支持浏览 Compose 项目目录及子目录，查看和修改 YAML、`.env` 及其他文本文件；二进制仅显示文件信息，保存不会自动部署或重启。更新入口为「拉取镜像并重新部署」，重建后跟随新容器 ID；写操作超时不自动重试，需先刷新状态核对。按 Arcane v2.17.1 接口实现，权限、HTTP 选项和验收说明见 [Arcane 容器管理](../../docs/arcane.md)。

- 设备监控右上角滑杆图标（`slider.horizontal.3`）打开服务器与登录；有设备时在列表标题右侧用加号添加 Agent，空列表保留文字添加入口。设备详情保留下拉刷新，移除工具栏刷新按钮，系统指标新增物理网卡实时上下行速度。设备详情在导航栏下方顶部固定“查询 / 操作”页签，不显示查询成功提示行，每条命令一张卡片，全部同页展示、双列排列并支持搜索，大字号时改为单列。卡片默认收起，同时最多展开一张；需要时自动滚动显示展开内容，收起恢复原浏览位置。长按卡片标题区域即可拖动排序，没有排序按钮；成功放下后按服务器、账号、设备与分组保存本机顺序，取消拖动恢复原顺序。Codex 卡片内切换处理中会话与最近 7 天统计，调用数与 Token 在同一双轴分组柱状图展示，点击日期悬浮查看当天完整数字。历史用量提示与时区、采集时间放在默认折叠的“数据说明”中。每次发送任务/消息计 1 次，不累计内部模型迭代，旧 Agent 未标明用户调用口径时提示更新。按设备时区统计，旧版估算、明细缺失和运行状态不可用均明确提示；需更新支持此能力的 Windows Agent，服务端无需新增业务接口。详见 [设备监控协议](../../docs/device-monitoring.md) 与 [Codex 用量采集](../../docs/codex-usage.md)。

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

## 组网管理

首页「组网管理」通过 Headplane 的 API Key 登录管理 Headscale，提供设备、网络、访问控制和更多四个原型页面。支持设备操作、路由审批、HuJSON 策略编辑、接入密钥创建/过期，以及用户、DNS 和 Agent 只读查看。接入密钥支持用户归属或纯标签模式、自定义整数有效天数。设备详情提供 App 内官方 Web SSH 终端，独立使用 OIDC 登录，要求服务端 Agent、目标 Tailscale SSH 及访问策略支持。连接凭据独立保存在本机 Keychain；未知写入结果必须刷新核对后才能继续操作。

已核对 v0.6.2、v0.7.0、v0.8.0 和 v0.8.2 发布标签的 Headplane 页面数据协议，并通过 v0.8.2 本地契约测试，尚不保证开发分支兼容。配置、能力限制及验证方法见 [Headplane 组网管理](../../docs/headplane.md)。

## 应用日志

首页 → 工具 → 日志，可查看 Hako、云服务器、容器管理、设备监控和使用时间的本机运行日志。支持按子应用、级别和关键词筛选，查看详情、选择文本、分享当前筛选结果或单条日志，以及清空全部日志。前台打开日志页时自动更新。

日志保留最近 1,000 条，普通事件按条限制长度，本机保存并排除备份；不上传到 Hako 服务端。日志记录主要 API 请求的结果与耗时、终端连接状态及使用时间采集 / 同步结果，不汇集远端容器 stdout 或服务器系统日志。Headplane 的 HTTP 4xx / 5xx 和传输失败使用 error 级别，完整保留请求方法、地址、请求头和正文，以及响应状态、响应头和原始正文，不截断错误详情；传输失败标明未收到响应。API Key、认证头和 Cookie 脱敏，终端命令与输出不记录。连接 URL 的用户名、密码、片段和全部查询参数值均隐藏。

排查阿里云终端地址问题：点击终端「连接」后，返回首页 → 日志，筛选「云服务器」，打开「阿里云返回终端连接地址」。该事件在地址校验前记录，保留实际域名、显式端口和路径；会话 ID、Token 和 AccessKey 不写入日志。终端原样使用阿里云 `StartTerminalSession` 接口返回的 URL，不按地域拼接域名或限定固定域名格式；只检查地址包含主机、合法端口，使用 `wss` 协议且不含用户名密码。用于连接的域名、端口、路径和查询参数均不改写。

日志存储 / 脱敏 / 并发与保留上限测试位于 `Tests/HakoLogTests.swift`，阿里云拒绝地址仍记录日志并清理会话的回归测试位于 `Tests/ECSTests.swift`；均接入 GitHub Actions 的 Swift 验证步骤。

## 运动记录

主页的「运动记录」是独立子应用，支持手动新增、查看详情、编辑和确认删除。同一天可有多条记录，日期显示为 `yyyyMMdd`；类型使用英文，预设为 `Swimming`、`Biking`、`Hiking`、`Walking`，从 GitHub 导入的其他英文类型也会保留。距离单位为 km，时长为正整数分钟，无距离运动填 0。

运动界面沿用已确认的原型：标题旁提供「记录运动」，下划线标签与紧凑年份筛选独立排布；四项指标横排（辅助功能大字号时调整为两列），图表标题和单位置于卡片内，使用低饱和度类型配色和左侧纵轴。列表、详情与编辑表单沿用相同卡片样式。

概览展示运动次数、距离、时长、天数，以及每月次数和时长图。趋势页展示次数、时长、距离的月度及年内累计图，均按类型区分；图表点击月份或年份后，仅在图内显示定位线并高亮所选柱形或数据点；具体合计和各运动类型数值显示在图表下方的自适应数据面板，不覆盖柱线。再次点击同一位置或点击「收起」可关闭面板。月份和年份使用分类坐标，确保柱形有实际宽度。概览和趋势图表均可选择「总体 · 全部年份」：指标统计全部记录，图表改为按年汇总，累计值从最早记录年份起连续计算。选择具体年份时按月统计且累计值从该年一月重新计算。记录列表保持按年和月筛选。

运动模块沿用主应用的 GitHub 仓库、分支与 Token，不设置独立配置或手动同步按钮。数据按年保存至 `data/sports/<年份>.csv`，表头为 `id,date,type,distance_km,duration_minutes`。`id` 为 UUID，编辑日期或类型不改变 ID；页面不显示内部 ID。新模块不预填演示记录。

每次从 Hako 主页进入运动模块，自动拉取所有年度记录，以远端快照为基础；本地新增、修改和删除操作的时间晚于对应年度 CSV 最后提交时间时保留，否则以 GitHub 为准（相同时间也以 GitHub 为准）。删除通过本地操作日志保留标记，不能因拉取而无条件恢复。跨年编辑同时比较涉及文件的提交时间，并在一次提交中更新两个年度文件。仓库其他文件的提交不影响判断。

合并后自动上传保留的本地变更，无变更时只刷新。保存和删除先持久化在本地，下一次进入模块时同步。GitHub 分支发生并发变动时，重新读取并按相同规则合并，最多尝试三次；网络请求结果不确定时不自动重复提交。同步失败显示页面内错误，保留本地数据和待同步操作；上传失败仍保留已成功读取的远端数据。已确认成功的提交才清除操作日志。未配置 GitHub 时仍可记录运动，之后配置好主应用 GitHub 再进入即可同步。

本地运动数据及操作日志按仓库和分支隔离，采用原子写入；损坏数据不会被空记录覆盖。进入详情、编辑后返回运动列表不会重复触发入口同步。

代码边界：主应用只负责应用入口、导航注册、全局设置与通用服务。`AppServices.gitHub()` 向子应用提供 `GitHubRepositoryAccess` 接口：读取目录快照、读取指定快照的文本文件及其最后提交时间、基于预期 HEAD 批量提交文件，并报告并发更新。`GitHubService.swift` 内部管理配置、Token、GraphQL 请求与响应、路径校验和提交签名验证；这些实现及凭据不向子应用暴露。子应用通过接口注入访问 GitHub，不读取主应用的配置或 Token，不创建网络客户端、不构造 GraphQL 请求、不扩展具体传输类。`CSV.swift` 只做通用编解码。

`Sports/` 独立负责运动数据、校验、合并、统计、持久化与界面；`Usage/` 独立负责屏幕时间页面、数据模型、数据库、采集、快捷指令、CSV 合并和 GitHub 业务适配。年度文件命名、模块目录和冲突策略均由子应用决定，主应用服务不识别运动或屏幕时间业务类型。使用时间的数据库仅进入该子应用时初始化，损坏或打不开不会阻塞首页和其他子应用。模型类及默认数据库位置保持不变，以保留已有记录。两个子应用不互相引用业务代码。

主应用通过 `AuthenticatedServerAccess` 提供登录状态、会话上下文、变更通知及已认证请求，`ConsoleClient` 仅实现身份与会话管理。设备监控的 `DeviceMonitorClient`、ECS 访问统计的 `ECSAccessAPI` 均注入该接口，不引用或扩展主应用具体客户端。业务路径、参数、解析和错误翻译留在各自子应用。缓存按服务器、账号和会话隔离，切换身份后的旧请求结果被丢弃。日志来源由调用方传入，主应用不解析子应用 URL。

主应用的 `SecureStorage` 提供按 service 命名空间隔离的 `SecretStorage` 接口，统一负责 Keychain 读写、删除和账号枚举。原有 service/account、JSON 格式和可访问策略保持不变：GitHub Token 使用首次解锁后可访问，其余凭据使用解锁时可访问，均仅限本机。子应用保留自身凭据模型、校验、编码和错误提示，可注入内存存储验证业务，无需访问真实 Keychain。

`HTTPTransport` 统一创建无 Cookie、缓存和自动凭据存储的临时网络会话，并拒绝重定向，避免凭据被转发。Arcane 保留较长操作超时；主应用服务器、GitHub 和 ECS 共用同一基础策略。阿里云签名、Arcane API 与终端协议仍由各子应用实现。客户端只负责释放自己创建的会话，不关闭外部注入的会话。`Tests/test_subapp_boundaries.py` 检查上述依赖边界及 CI 源文件路径；`CredentialStorageTests.swift` 验证凭据适配器的校验、规范化和失败时保留数据。

运动核心和模拟 GitHub 测试分别位于 `Tests/SportsTests.swift`、`Tests/SportsGitHubTests.swift`，已接入 iOS CI；两项测试仅依赖主应用通用层和运动模块，不依赖屏幕时间的数据模型。

`Tests/SportsRepositoryTests.swift` 仅链接主应用接口和运动业务代码，使用内存假服务测试，无需链接 GitHub 配置、Token 存储或具体网络实现；架构检查会阻止子应用重新直接访问凭据或具体传输类。

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
swiftc -target arm64-apple-macos14.0 Hako/HakoError.swift Hako/Usage/UsageModels.swift Hako/CSV.swift Hako/Usage/UsageCSV.swift Tests/CoreTests.swift -o /tmp/hako-core-tests
/tmp/hako-core-tests
swiftc -target arm64-apple-macos14.0 Hako/HakoError.swift Hako/Usage/UsageModels.swift Hako/CSV.swift Hako/GitHubSettings.swift Hako/GitHubTokenStore.swift Hako/GitHubRepository.swift Hako/GitHubService.swift Hako/Usage/UsageCSV.swift Hako/Usage/UsageGitHub.swift Hako/Usage/UsageSync.swift Hako/BuildStatus.swift Tests/GitHubTests.swift -o /tmp/hako-github-tests
/tmp/hako-github-tests
swiftc Hako/DeviceManagement/DeviceCardPresentation.swift Tests/DeviceCardPresentationTests.swift -o /tmp/hako-device-card-tests
/tmp/hako-device-card-tests
```

真机验收：核对系统「屏幕使用时间」最近 7 天每天的总量与 Top 5；重跑采集确认数据库/CSV 已有日期不变；核对跨年时生成对应年份文件；点击「合并本地与 GitHub 记录」确认空本地恢复、跨年历史恢复及双方缺失日期互补，同日冲突以 GitHub 为准，重复合并不产生提交；断网运行确认本地留存，恢复网络后重试；通过快捷指令实际触发。设备详情需核对轻点与长按不冲突、拖动至边缘滚动、放下后重进保持顺序、取消拖动恢复原顺序、两分组独立，以及滚动后展开 / 收起恢复位置、底部卡片、大字号和减少动态效果。核心、模拟网络及设备卡片顺序 / 布局 / 位置计算测试已接入 GitHub Actions。无签名构建与模拟测试不代表上述真机能力已经验证。

## GitHub Actions 自动打包与安装页

仅当默认分支推送包含 `apps/ios/` 目录下的文件变化时，自动导出签名 IPA，发布 GitHub Pages 安装页；也可手动运行。首次需配置证书、描述文件 Secrets 和 Pages，详见 [自动打包与网页安装](../../docs/ios/ci-install.md)。
