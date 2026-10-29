# Arcane 容器管理

iOS 首页的「容器管理」直接连接用户已有的 Arcane Manager，独立于 Hako 服务器登录。无需在 Hako 服务端增加 Docker Socket、代理或保存 Arcane 凭据。首版提供单个 Arcane 连接及其多个 Docker 环境；接口按 Arcane v2.17.1 实现，其他版本需用实例 `/api/openapi.json` 核对。

## 配置

1. 在 Arcane 的 Settings → API Keys 创建 API Key。
2. Hako → 容器管理 → 配置 Arcane 连接（或右上角设置），填写连接名称、服务地址和 API Key。地址可以包含反向代理基础路径，也接受以 `/api` 结尾的地址；不要填写 `/api/docs`、前端页面或查询参数。
3. 点击「测试连接」，确认可访问的环境；点击右上角勾号保存。测试不保存输入；关闭有修改的 sheet 会询问是否放弃。
4. 选择 Docker 环境，查看列表。手机必须能直接访问 Arcane；外网使用需自行提供 HTTPS 或 VPN。

名称、地址、HTTP 选项与 API Key 作为一个配置保存在独立的系统 Keychain 项目 `me.stackli.hako.arcane`，仅限本机解锁时读取。API Key 不进入 UserDefaults、Hako 后端、URL 查询或应用日志。配置及网络会话不与 Hako、GitHub 共用。

默认要求 HTTPS，使用系统证书校验，不忽略证书错误。HTTP 必须明确开启「允许不加密的 HTTP 连接」，仅用于可信网络；API Key 将明文传输。由于地址由用户动态配置，Info.plist 提供 ATS HTTP 例外，实际是否发送 HTTP 仍由客户端配置校验。所有重定向均拒绝，不把 Key 转发到其他地址。局域网连接首次可能触发 iOS 本地网络授权。

## 功能与权限

| 功能 | 所需权限 |
| --- | --- |
| 环境选择 | API Key 对相应环境有授权；环境列表按 Arcane 返回 |
| 容器列表、搜索、状态／更新筛选、Compose 分组 | `containers:list` |
| 详情、配置及 CPU／内存／网络监控 | `containers:read` |
| 实时日志、导出 Docker 留存日志 | `containers:logs` |
| 启动、停止、重启 | `containers:start`、`containers:stop`、`containers:restart` |
| 检查镜像更新 | `image-updates:check` |
| 查找 Compose 项目、浏览目录及读取文本文件 | `projects:list`、`projects:read` |
| 保存 Compose YAML、`.env` 及项目文本文件 | `projects:update` |
| 拉取镜像并重新部署 | `containers:redeploy`，Compose 更新的额外授权以服务端为准 |
| 删除已停止的容器 | `containers:delete` |
| 操作期间的日志（可选） | `activities:read` |

权限不足展示 403 提示，不自动扩大授权。未授权活动记录时仍可提交已有权限的操作，状态显示进行中并等待服务端响应。未实现创建容器、独立容器的配置重建编辑、终端和自动更新开关。

列表加载完整分页（单次最多 10,000 项），按名称排序；顶部依次为紧凑的环境卡片、搜索框和独立圆角筛选按钮，选中项深色显示。可搜索名称、镜像、Compose 项目，筛选全部、异常、停止及有更新的容器；筛选按钮不展示数量，空间不足时可横向滚动。「容器」列表标题右侧显示「Compose 分组」复选框，勾选后按项目分组，取消后恢复按名称排列的列表。运行状态及其图标为绿色，停止为灰色，异常为红色；「有更新」显示在状态右侧。分组只改变展示方式，不对项目执行批量修改。列表前台可见时每 10 秒刷新，进入详情、打开设置或切后台时停止列表轮询。失败保留原数据和最近更新时间，支持下拉刷新。

同一连接复用客户端及网络会话。首次加载环境后直接读取容器，自动选择默认环境不会取消并重启首轮加载；后续轮询直接请求容器，下拉刷新或环境卡片的刷新按钮同时重新读取环境元数据。

容器首页不显示「最近更新」、自动刷新频率或「正在刷新容器」提示；每 10 秒自动刷新静默进行，不显示刷新动画，不因轮询切换按钮颜色或让空列表提示反复消失。仅首次尚无数据时显示读取提示，手动下拉刷新保留系统反馈。在本客户端发起更新等操作后，列表顶部、对应容器行及详情顶部显示「更新中」「重启中」等状态，不显示百分比或进度条。更新时即使原容器暂时不在列表中，顶部状态仍保留；替换后的容器 ID 也能显示当前操作，直到状态刷新结束。结果不确定时改为「更新结果待确认」，不继续显示正在更新。

列表及详情各行分隔线统一对齐内容区两端。「有更新」的图标与文字紧凑排列。详情中的所有端口合并到一个「端口」行，多个端口在值区域逐项换行；未映射的端口显示 `80/tcp` 等容器端口，不显示无效的宿主机端口 `0`，有效映射显示 `8080 → 80/tcp`。端口固定按容器端口数字、协议、宿主端口和绑定地址排序，并合并重复显示的映射（包括 IPv4／IPv6 通配绑定）。TCP 与 UDP、不同宿主端口分别保留；特定地址的绑定显示 `127.0.0.1:8080 → 80/tcp` 或 `[::1]:8080 → 80/tcp`，避免与通配绑定混淆。

容器主页沿用交互原型的间距：页面左右 18 点，环境卡片到搜索框 16 点，搜索框到筛选胶囊约 12 点，筛选按钮之间 6 点；容器卡片每行左右 13 点、上下 15 点，最小行高 85 点。主页使用连续滚动布局和独立卡片背景，避免系统列表分区叠加额外空白或裁切筛选按钮。

进入详情立即展示列表已有的名称、镜像、状态、项目和资源采样，并行读取完整配置和订阅实时资源，不等待详情接口才显示资源区。列表采样明确标注来源，实时采样到达后替换。前台可见时每 10 秒刷新状态；移除导航栏刷新按钮，保留下拉刷新，同时重连实时资源及日志。取消后重新进入立即开始新请求，旧请求不能覆盖新数据、错误或加载状态。完整配置读取成功前不开放管理操作。运行状态及图标为绿色，停止为灰色，异常为红色。CPU、内存及网络从单容器 WebSocket 读取，不把缺失值填成零。内存扣除 Docker 缓存后显示使用率及使用量；右侧网络以上行 `tx_bytes`、下行 `rx_bytes` 汇总所有接口，以两次采样的差值／时间间隔计算 B/s、KB/s、MB/s、GB/s，同时可展开累计流量。首次采样、重连、计数重置或间隔超过 30 秒时等待下一次有效采样；没有网络计数时明确显示不可用。累计值属于 Docker 当前容器计数，不是 Hako 历史流量。

日志仅在日志页前台且开启跟随时订阅，重连读取最近 100 行，内存中最多保留 500 行／512 KiB；长行有显示长度上限。离开详情、切后台或操作开始时取消实时订阅。导出通过下载接口获取 Docker 仍保留的日志，最多 256 MB，保存临时文件后由系统分享；离开页面清理该导出文件。环境变量默认遮蔽，用户可主动显示。

## 项目文件

容器详情新增「文件」Tab，浏览 Compose 所在目录及子目录，支持搜索、逐级进入目录、读取和编辑 UTF-8 文本文件。Compose YAML、`.env` 和已有的 Compose override 文件与其他项目文件统一展示。没有关联到 Arcane 项目的容器显示说明，不猜测宿主机目录；同名项目优先按 Compose 工作目录匹配，无法唯一确定时停止加载。

按 [v2.17.1 官方项目接口](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/internal/project/module.go) 实现，路径均位于 `/api/environments/{environmentID}` 下：

| 能力 | 接口 |
| --- | --- |
| 查询项目 | `GET /projects` |
| 读取 Compose、`.env`、override | `GET /projects/{projectID}/compose` |
| 项目目录树 | `GET /projects/{projectID}/workspace` |
| 读取文本文件 | `GET /projects/{projectID}/workspace/file?relativePath=…` |
| 保存普通文本文件 | `PUT /projects/{projectID}/workspace`，multipart manifest + 文件内容及基线 |
| 保存 Compose、`.env`、override | `PUT /projects/{projectID}`，只发送变更的内容字段 |

二进制、特殊文件和符号链接只显示文件信息，不提供内容预览及编辑；Git 同步管理的源文件保持只读。Git 项目的有效 `.env` 通过 Arcane 专用保存接口处理覆盖层，不修改 `.env.git` 源文件。目录列表遵守服务端的忽略目录、最大深度、条目数和文件大小限制；返回截断标志时提示列表不完整。

文件页使用紧凑列表，不显示项目信息卡片、文件搜索框或快捷入口。「文件」标题沿用「管理」分区的系统字号，下方仅显示 Compose 所在文件夹名称（如 `frps`），不展示完整路径，并可通过目录导航返回上级目录；Compose、`.env` 与其他配置统一从列表打开。返回上级目录时定位到此前进入的目录项，关闭编辑器后保留浏览位置。管理区域继续保留。编辑器的信息按钮提供文件说明，不常驻文件列表底部。

编辑器由容器详情页的单一呈现入口打开，持有打开时的项目、文件和目录快照，不依赖异步刷新的列表分区。缺少 `.env` 时首次打开即进入空白可编辑状态，打开或关闭不创建文件，仅显式保存内容时写入服务端。

文本文件全屏打开，点击顶部文件名可搜索并切换项目文件。编辑器默认使用 12 点等宽字体，并跟随系统辅助字号缩放；YAML、`.env`、JSON、TOML／INI、Shell 和常见 `.conf` 配置提供轻量词法高亮，其他文件使用纯文本。高亮只调整显示属性，不格式化内容，不修改换行；关闭智能引号、智能破折号、自动纠错等输入替换。分词在后台计算，过期结果不会覆盖新输入，中文输入法组词期间不重设高亮。语法高亮不代替 Arcane 的内容校验。

普通文件保存携带 `fileTreeRevision` 及 `baselineIndex` 对应的原文，服务端拒绝目录变化和同文件并发修改。Compose／`.env` 专用接口没有版本参数，保存前重新读取并比对该字段，但这不能提供与 Workspace 基线相同的原子冲突保证。保存失败保留草稿；响应不确定时阻止重复保存，需重新读取核对。返回、重新读取或切换文件时，未保存修改提供「保存并继续／放弃修改／继续编辑」；保存失败停留原文件，保存成功后默认继续留在编辑器。草稿仅在当前编辑器内存中保留，不写入本地文件、UserDefaults 或日志。

保存只修改文件，不主动部署或重启容器。项目文件写入与已有容器操作互斥，防止保存和重建同时执行。

## 更新与操作结果

更新入口保留「拉取镜像并重新部署」，调用 `POST /api/environments/{env}/containers/{id}/redeploy`。Arcane v2.17.1 会对已登记的 Compose 服务使用项目配置更新；客户端不根据旧 inspect 结果自行拼装或创建容器。服务端返回新的容器 ID 后，详情、资源和日志订阅切换到新 ID。检查更新显示版本／摘要及检查状态，不把检查失败当作没有更新。

启停、重启、删除及重新部署均使用居中的系统 `alert` 确认框，标题明确具体操作（如「重启容器？」「停止容器？」），包含环境、容器名称、各操作的影响、确认及取消按钮。重启和停止保留同一行，使用各自独立的点击区域。删除只允许已停止等可删除状态，固定 `force=false`、`volumes=false`。停止／重启自动移除容器时单独提示 Docker 的自动删除行为。

Arcane 自身容器依据服务端的 `redeployDisabled` 保护标记隐藏整个「管理」分区，不提供启停、重启、重新部署或删除入口。所有容器详情均不展示底部「容器操作」分区；进行中状态仍在顶部显示，操作记录及结果核对入口保留在容器管理主页。

同一时间只提交一个操作。提交前保存不含密钥的待确认记录；网络超时、服务端 5xx、已接受但未完成或重建响应缺少新 ID 时保留记录，阻止直接重复提交。不自动重试写操作，活动记录的成功状态也不代替实际请求结果。应用重启后提示核对状态，用户可刷新／在 Arcane 检查活动记录，再点击「已核对状态，清除此提示」。后台、关闭 App 或网络断开不代表服务端操作取消。

## 验证

Windows 本机跳过 iOS 编译、归档、签名和安装。可运行现有安装页测试：

```powershell
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

macOS CI 新增模拟网络测试，无真实服务器和容器写入：

```sh
cd apps/ios
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneClient.swift Tests/ArcaneTests.swift -o /tmp/hako-arcane-tests
/tmp/hako-arcane-tests
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneClient.swift Hako/Containers/ArcaneKeychain.swift Hako/Containers/ArcaneStore.swift Hako/Containers/ArcaneFilesStore.swift Tests/ArcaneLoadingTests.swift -o /tmp/hako-arcane-loading-tests
/tmp/hako-arcane-loading-tests
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneClient.swift Tests/ArcaneWorkspaceTests.swift -o /tmp/hako-arcane-workspace-tests
/tmp/hako-arcane-workspace-tests
swiftc Hako/Containers/ArcaneSyntax.swift Tests/ArcaneSyntaxTests.swift -o /tmp/hako-arcane-syntax-tests
/tmp/hako-arcane-syntax-tests
```

测试覆盖配置与路径校验、Key 请求头、双类分页、容器模型、Docker CPU／内存／多接口网络计数、速率与计数重置、日志解码、权限错误、操作超时不重试、重建 ID、删除参数及重定向拒绝；加载回归测试覆盖会话复用、直接轮询容器、显式刷新环境、旧响应与旧错误隔离、取消后立即重载及容器替换。SwiftUI、Keychain、ATS、本地网络权限及真实实例兼容性仍需 iPhone 验收。

项目文件回归测试覆盖同名项目匹配、相对路径隔离、二进制／只读元数据、包含 Unicode 与特殊字符的文件名、multipart 上传与精确原文基线、专用配置接口只提交修改字段、保存冲突及不确定结果不重试。

官方参考：[API](https://getarcane.app/docs/reference/api)、[容器](https://getarcane.app/docs/docker/containers)、[权限](https://getarcane.app/docs/access/roles)、[v2.17.1 容器实现](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/internal/container/service.go)。
