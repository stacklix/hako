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
| 主机资源、系统与 Docker 信息 | `system:read`，授予对应环境 |
| 主机信息中的网络端口 | `containers:list`，授予对应环境 |
| 容器终端、预设与自定义命令 | `containers:exec`，以及执行前状态核对所需的 `containers:read` |
| 实时日志、导出 Docker 留存日志 | `containers:logs` |
| 启动、停止、重启 | `containers:start`、`containers:stop`、`containers:restart` |
| 检查镜像更新 | `image-updates:check` |
| 查找 Compose 项目、浏览目录及读取文本文件 | `projects:list`、`projects:read` |
| 保存 Compose YAML、`.env` 及项目文本文件 | `projects:update` |
| 新建文件／文件夹、重命名 | `projects:read`、`projects:update` |
| 拉取镜像并重新部署 | `containers:redeploy`，Compose 更新的额外授权以服务端为准 |
| 删除已停止的容器 | `containers:delete` |
| 操作期间的日志（可选） | `activities:read` |

权限不足展示 403 提示，不自动扩大授权。未授权活动记录时仍可提交已有权限的操作，状态显示进行中并等待服务端响应。未实现创建容器、独立容器的配置重建编辑、终端和自动更新开关。

列表加载完整分页（单次最多 10,000 项），按名称排序；顶部依次为紧凑的环境卡片、搜索框和独立圆角筛选按钮，选中项深色显示。可搜索名称、镜像、Compose 项目，筛选全部、异常、停止及有更新的容器；筛选按钮不展示数量，空间不足时可横向滚动。「容器」列表标题右侧显示「Compose 分组」复选框，勾选后按项目分组，取消后恢复按名称排列的列表。运行状态及其图标为绿色，停止为灰色，异常为红色；「有更新」显示在状态右侧。分组只改变展示方式，不对项目执行批量修改。列表前台可见时每 10 秒刷新，进入详情、打开设置或切后台时停止列表轮询。失败保留原数据和最近更新时间，支持下拉刷新。

同一连接复用客户端及网络会话。首次加载环境后直接读取容器，自动选择默认环境不会取消并重启首轮加载；后续轮询直接请求容器。环境卡片不显示刷新按钮，下拉刷新同时重新读取环境元数据和容器列表。

容器首页不显示「最近更新」、自动刷新频率或「正在刷新容器」提示；每 10 秒自动刷新静默进行，不显示刷新动画，不因轮询切换按钮颜色或让空列表提示反复消失。仅首次尚无数据时显示读取提示，手动下拉刷新保留系统反馈。在本客户端发起更新等操作后，列表顶部、对应容器行及详情顶部显示「更新中」「重启中」等状态，不显示百分比或进度条。更新时即使原容器暂时不在列表中，顶部状态仍保留；替换后的容器 ID 也能显示当前操作，直到状态刷新结束。结果不确定时改为「更新结果待确认」，不继续显示正在更新。

列表及详情各行分隔线统一对齐内容区两端。「有更新」的图标与文字紧凑排列。详情中的所有端口合并到一个「端口」行，多个端口在值区域逐项换行；未映射的端口显示 `80/tcp` 等容器端口，不显示无效的宿主机端口 `0`，有效映射显示 `8080 → 80/tcp`。端口固定按容器端口数字、协议、宿主端口和绑定地址排序，并合并重复显示的映射（包括 IPv4／IPv6 通配绑定）。TCP 与 UDP、不同宿主端口分别保留；特定地址的绑定显示 `127.0.0.1:8080 → 80/tcp` 或 `[::1]:8080 → 80/tcp`，避免与通配绑定混淆。

容器主页沿用交互原型的间距：页面左右 18 点，环境卡片到搜索框 16 点，搜索框到筛选胶囊约 12 点，筛选按钮之间 6 点；容器卡片每行左右 13 点、上下 15 点，最小行高 85 点。主页使用连续滚动布局和独立卡片背景，避免系统列表分区叠加额外空白或裁切筛选按钮。

进入详情立即展示列表已有的名称、镜像、状态、项目和资源采样，并行读取完整配置和订阅实时资源，不等待详情接口才显示资源区。列表采样明确标注来源，实时采样到达后替换。前台可见时每 10 秒刷新状态；移除导航栏刷新按钮，保留下拉刷新，同时重连实时资源及日志。取消后重新进入立即开始新请求，旧请求不能覆盖新数据、错误或加载状态。完整配置读取成功前不开放管理操作。运行状态及图标为绿色，停止为灰色，异常为红色。CPU、内存及网络从单容器 WebSocket 读取，不把缺失值填成零。内存扣除 Docker 缓存后显示使用率及使用量；右侧网络以上行 `tx_bytes`、下行 `rx_bytes` 汇总所有接口，以两次采样的差值／时间间隔计算 B/s、KB/s、MB/s、GB/s，同时可展开累计流量。首次采样、重连、计数重置或间隔超过 30 秒时等待下一次有效采样；没有网络计数时明确显示不可用。累计值属于 Docker 当前容器计数，不是 Hako 历史流量。

日志仅在日志页前台且开启跟随时订阅，重连读取最近 100 行，内存中最多保留 500 行／512 KiB；长行有显示长度上限。离开详情、切后台或操作开始时取消实时订阅。导出通过下载接口获取 Docker 仍保留的日志，最多 256 MB，保存临时文件后由系统分享；离开页面清理该导出文件。环境变量默认遮蔽，用户可主动显示。

## 主机信息

点击环境卡片的主机名称及状态行打开当前环境的「主机信息」，不单独增加入口行；卡片右侧的独立下拉按钮选择服务器，两个点击区域互不嵌套。本地 Manager 和远程 Agent 均通过同一个 Manager 地址访问，客户端不另外连接各主机。系统及 Docker 信息使用 `GET /api/environments/{id}/system/docker/info`；该接口返回平铺的 Docker Info，不是通用 `data` 包装。实时资源使用 `GET /api/environments/{id}/ws/system/stats?interval=2`，需要对应环境的 `system:read` 权限。接口依据 [Arcane v2.17.1 系统路由](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/internal/system/module.go) 与 [主机指标实现](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/api/ws/system_stats.go)。

详情展示 CPU 使用率及核心数、内存与磁盘已用／总量和百分比；服务端启用并返回 GPU 信息时展示各 GPU 显存使用量。系统信息包括主机名、操作系统、内核和架构，Docker 信息包括版本、存储／日志驱动、数据目录、容器与镜像数量。磁盘仅代表 Arcane 配置的统计路径所在文件系统，默认 `/`，不是所有磁盘的容量汇总。缺失指标显示 `—`，不伪造零使用率。

「网络端口」分区读取当前环境的 `GET /api/environments/{id}/ports`，完整分页并使用服务端支持的 `hostPort` 排序字段。按容器 ID 分组、容器名排序，展示 Docker 声明的所有有效端口，包括未映射到宿主机的端口。每行左侧为容器名、右侧为端口，多个端口在右侧换行；映射显示 `8080 → 80/tcp`，未映射只显示 `2019/tcp`，不展示绑定 IP、未映射提示或宿主端口 `0`。容器内按容器端口数字、协议、宿主端口固定排序；同一容器同一映射的重复条目合并，TCP／UDP、不同容器与不同目标端口分别展示。此接口提供 Docker 容器的端口，不是整机监听扫描，不包含 SSH 等宿主进程的端口，也不代表已通过防火墙对公网开放。端口列表在进入页面、返回前台和下拉刷新时更新；读取失败保留原结果并独立显示错误，不影响 CPU 等实时指标。

CPU、内存、磁盘及可用 GPU 指标每约 2 秒通过 WebSocket 更新；系统、Docker 版本及容器／镜像数量在进入页面、返回前台或下拉刷新时读取，不定时轮询。进入页面自动读取并订阅，保留下拉刷新；离开页面或进入后台取消订阅，返回后重新连接。网络断线保留上次样本并标记状态，每 5 秒重连；401／403／404 停止自动重连，显示错误并允许下拉重试。超过 15 秒没有新样本时不再标为实时。连接、环境切换及新请求会隔离旧响应，防止串用主机数据。主机资源仅查询，不触发 Docker 变更。

## 项目文件

容器详情新增「文件」Tab，浏览 Compose 所在目录及子目录，支持逐级进入目录、读取和编辑 UTF-8 文本文件。Compose YAML、`.env` 和已有的 Compose override 文件与其他项目文件统一展示。没有关联到 Arcane 项目的容器显示说明，不猜测宿主机目录；同名项目优先按 Compose 工作目录匹配，无法唯一确定时停止加载。

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

文件页使用紧凑列表，不显示项目信息卡片、文件搜索框或快捷入口。「文件」标题沿用「管理」分区的系统字号，下方仅显示 Compose 所在文件夹名称（如 `frps`），不展示完整路径，并可通过目录导航返回上级目录；Compose、`.env` 与其他配置统一从列表打开。返回上级目录时定位到此前进入的目录项，关闭编辑器后保留浏览位置。管理区域继续保留。

「文件」标题下方的目录路径与右侧加号同一行，标题与路径紧凑排列；加号可在当前目录新建空文件或文件夹；长按文件／目录整行打开重命名窗口，也提供辅助功能的「重命名」动作。窗口持有当前连接、环境、项目及目录版本的快照，名称字段始终显示标签。仅接受单个名称，检查路径穿越、控制字符、长度和同名冲突。提交前重新读取项目和目录版本，结构变化时要求刷新后再操作；文件创建使用 `create_file` 和一个空内容上传，目录使用 `create_folder`，重命名使用 `rename`／`newName`，均通过 Workspace multipart 接口提交，不执行部署或重启。

Arcane 的 Compose、`.env` 等保护配置不能重命名，窗口显示具体原因并禁用提交。Git 同步拥有的文件及含这些文件的目录、归档项目和符号链接也保持只读。二进制及过大文件可修改名称而不读取内容，是否允许操作最终由 Arcane 校验。所有目录修改与文件保存、容器操作互斥；失败保留名称，不自动重复写请求，结果不确定时需关闭窗口并刷新核对。成功后刷新当前目录。

编辑器由容器详情页的单一呈现入口打开，持有打开时的项目和文件快照，不依赖异步刷新的列表分区。缺少 `.env` 时首次打开即进入空白可编辑状态，打开或关闭不创建文件，仅显式保存内容时写入服务端。

文本文件全屏打开，顶部仅显示当前文件名，不提供文件切换。编辑器左侧显示随内容滚动的实际行号，长行自动折行时不重复编号，空文件与末尾空行也有行号。默认使用 12 点等宽字体，并跟随系统辅助字号缩放；YAML、`.env`、JSON、TOML／INI、Shell 和常见 `.conf` 配置提供轻量词法高亮，其他文件使用纯文本。高亮只调整显示属性，不格式化内容，不修改换行；关闭智能引号、智能破折号、自动纠错等输入替换。分词在后台计算，过期结果不会覆盖新输入，中文输入法组词期间不重设高亮。语法高亮不代替 Arcane 的内容校验。

底部仅保留「覆盖粘贴」，点击时读取剪贴板文本并替换整个文件草稿，仍需点击右上角「保存」才写入服务端。剪贴板没有可读取文本时提示并保留原内容；只读、加载或保存期间禁用覆盖粘贴。键盘上方提供「收起键盘」，也支持向下拖动编辑区交互收起键盘。

普通文件保存携带 `fileTreeRevision` 及 `baselineIndex` 对应的原文，服务端拒绝目录变化和同文件并发修改。Compose／`.env` 专用接口没有版本参数，保存前重新读取并比对该字段，但这不能提供与 Workspace 基线相同的原子冲突保证。保存失败保留草稿；响应不确定时阻止重复保存，需重新读取核对。正常编辑时不显示重新读取按钮，读取或保存失败时在错误提示下提供「重新读取服务器文件」。返回或重新读取时，未保存修改提供「保存并继续／放弃修改／继续编辑」；保存失败停留原文件，保存成功后默认继续留在编辑器。草稿仅在当前编辑器内存中保留，不写入本地文件、UserDefaults 或日志。

保存只修改文件，不主动部署或重启容器。项目文件写入与已有容器操作互斥，防止保存和重建同时执行。

## 更新与操作结果

更新入口保留「拉取镜像并重新部署」，调用 `POST /api/environments/{env}/containers/{id}/redeploy`。Arcane v2.17.1 会对已登记的 Compose 服务使用项目配置更新；客户端不根据旧 inspect 结果自行拼装或创建容器。服务端返回新的容器 ID 后，详情、资源和日志订阅切换到新 ID。检查更新显示版本／摘要及检查状态，不把检查失败当作没有更新。

启停、重启、删除及重新部署均使用居中的系统 `alert` 确认框，标题明确具体操作（如「重启容器？」「停止容器？」），包含环境、容器名称、各操作的影响、确认及取消按钮。重启和停止保留同一行，使用各自独立的点击区域。删除只允许已停止等可删除状态，固定 `force=false`、`volumes=false`。停止／重启自动移除容器时单独提示 Docker 的自动删除行为。

Arcane 自身容器依据服务端的 `redeployDisabled` 保护标记隐藏整个「管理」分区，不提供启停、重启、重新部署或删除入口。所有容器详情均不展示底部「容器操作」分区；进行中状态仍在顶部显示，操作记录及结果核对入口保留在容器管理主页。

客户端对名称为 `caddy` 的容器增加停止保护（忽略大小写及 Docker 名称前导 `/`）：详情页禁用「停止」并显示说明，操作提交层再次校验，拒绝发送停止请求或写入待确认记录。该规则只禁止停止，启动、重启与重新部署等操作仍按现有权限及状态判断。

同一时间只提交一个操作。提交前保存不含密钥的待确认记录；网络超时、服务端 5xx、已接受但未完成或重建响应缺少新 ID 时保留记录，阻止直接重复提交。不自动重试写操作，活动记录的成功状态也不代替实际请求结果。重启请求保存操作前的服务端启动时间；结果待确认时，以及后续列表刷新后，额外查询容器详情。仅在同一容器当前运行、启动时间确实晚于基线时清除待确认记录，并说明已核对当前状态；旧记录无基线时要求启动时间晚于保存的请求时间。单凭「运行中」、活动记录或列表中缺少容器均不自动判断成功。顶部提示卡片提供「核对状态」「已核对，清除提示」，后者供用户独立核对后手动清除。后台、关闭 App 或网络断开不代表服务端操作取消。

## 容器操作与终端

终端弹层由容器详情页根视图持有，使用独立会话标识和打开时的容器快照，不依附于列表中的动态 Section。列表刷新或旧渲染视图释放不关闭会话；关闭终端页面时统一断开。页面不显示连接状态或单独的断开按钮，导航栏最右侧提供 Shell 菜单；选择后关闭当前会话并连接所选 Shell，不重放上一次输入。自定义路径在独立表单中校验，确认后才切换。

执行页直接展示展开后的命令，使用跟随当前主题的「执行命令」按钮；连接、Shell 初始化和执行阶段均显示状态。终端连接不以 Ping/Pong 作为输入前置条件。Shell 初始化单独限时 10 秒，超时后不发送实际命令；收到 Arcane 的 Exec 创建／附加错误时直接展示 Shell 启动失败原因。初始化成功后的执行仍受总计 120 秒的期限约束。

详情新增「操作」Tab，原有「管理」区域保留。Caddy（按镜像仓库末段或容器名识别）提供「配置检查」「重载配置」，默认容器内路径为 `/etc/caddy/Caddyfile`，重载前使用包含主机、容器及操作名称的原生 Alert 确认。Caddyfile 格式带 `--adapter caddyfile`，选择原生 JSON 时省略 adapter；重载使用可配置的管理地址，默认 `localhost:2019`。

每个容器可新增、编辑、删除自定义操作。模板中的 `{{参数标识}}` 是参数列表的唯一来源，重复标识合并，修改模板自动同步列表；参数本身没有增删或修改标识的控件。名称、类型、默认值、必填和选项仍可设置，同一编辑会话暂时移除再加回的标识保留设置。支持文本、数字、选项、开关和密码，密码默认值与执行值不写入 UserDefaults。模板保存在本机，按连接、环境和 Compose 项目／服务隔离；非 Compose 容器按容器名关联，重建后可继续使用。

参数按 POSIX shell 单个字面量转义；占位符必须在引号外独立使用（或写成 `--option={{value}}`），不支持在带参数模板中使用 here-document 或反引号。单项最多 24 个参数，展开并包装后的单行执行脚本最多 3500 字节。交互式命令应从「进入终端」执行。

命令与交互终端均连接 `GET /api/environments/{env}/ws/containers/{id}/terminal`，API Key 仅在请求头中传递。执行前重新核对容器仍处于运行状态。预设命令在 `/bin/sh` 中执行，先用 `stty -echo` 关闭输入回显，确认初始化后才发送实际命令；容器缺少 sh／stty 时显示错误，不发送实际命令。利用随机控制记录读取退出码，支持分帧、UTF-8 跨帧和非零退出码；不会将连接关闭或输出中的文字当作成功。等待超过 120 秒或发送后断线显示「结果待确认」，不重试；该页面需用户核对后才允许再次执行。

结果同页显示输出、退出码、开始时间及耗时，支持复制。每个容器保留本次 App 运行期间最近 20 次结果，最多显示前 256 KB 输出；记录不跨 App 重启恢复。密码参数操作在完成后显示脱敏输出，其他操作逐步显示输出；API Key 与密码不进入可复制结果。

交互终端使用原生 UIKit [SwiftTerm v1.99.2](https://github.com/migueldeicaza/SwiftTerm/tree/v1.99.2)，固定依赖版本，通过 Swift Package Manager 引入。直接在终端光标处输入，支持原生终端控制序列、Unicode、选择复制和粘贴。底部快捷栏提供 Ctrl、Esc、Tab、Ctrl+C、方向键、粘贴和回车。方向键使用当前终端模式的序列，回车发送 CR；输入逐字节传输，保留服务端 Shell 的当前目录、历史与补全行为，`vim`／`top` 等交互程序需容器内存在。窗口与键盘导致的行列变化通过 resize 消息传递。

终端可选择 sh、bash、ash 或自定义绝对路径。sh／bash／ash／zsh 会话自动设置 `TERM=xterm-256color`，Arcane 当前没有 Exec 环境变量参数，因此通过一次 Shell 初始化命令设置。会话意外结束（包括 Shell 自行退出）弹出原生 Alert，提供「退出」「重新连接」，不自动重连或重放输入。关闭、进入后台和连接配置变化均释放会话；临时 inactive（如系统弹窗）不关闭会话，后台返回时提示重新连接；主动关闭时使用原生 Alert 确认。终端／命令执行期间，与文件写入和容器生命周期操作互斥；每个连接租约有独立标识，旧任务不能释放新会话。第三方许可随 App 打包于 `Resources/SwiftTerm-LICENSE.txt`。SwiftTerm 的构建插件需要 CI 非交互授权，归档脚本使用 `-skipPackagePluginValidation`；版本在 Xcode 工程中固定。

## 验证

Windows 本机跳过 iOS 编译、归档、签名和安装。可运行现有安装页测试：

```powershell
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

macOS CI 新增模拟网络测试，无真实服务器和容器写入：

```sh
cd apps/ios
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Tests/ArcaneTests.swift -o /tmp/hako-arcane-tests
/tmp/hako-arcane-tests
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Hako/Containers/ArcaneKeychain.swift Hako/Containers/ArcaneStore.swift Hako/Containers/ArcaneFilesStore.swift Tests/ArcaneLoadingTests.swift -o /tmp/hako-arcane-loading-tests
/tmp/hako-arcane-loading-tests
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Tests/ArcaneWorkspaceTests.swift -o /tmp/hako-arcane-workspace-tests
/tmp/hako-arcane-workspace-tests
swiftc Hako/Containers/ArcaneSyntax.swift Tests/ArcaneSyntaxTests.swift -o /tmp/hako-arcane-syntax-tests
/tmp/hako-arcane-syntax-tests
swiftc Hako/Containers/ArcaneEditorLines.swift Tests/ArcaneEditorLinesTests.swift -o /tmp/hako-arcane-editor-lines-tests
/tmp/hako-arcane-editor-lines-tests
swiftc -target arm64-apple-macos14.0 Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Hako/Containers/ArcaneHostData.swift Tests/ArcaneHostTests.swift -o /tmp/hako-arcane-host-tests
/tmp/hako-arcane-host-tests
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Hako/Containers/ArcaneCommandProtocol.swift Hako/Containers/ArcaneTerminalTransport.swift Tests/ArcaneCommandTests.swift -o /tmp/hako-arcane-command-tests
/tmp/hako-arcane-command-tests
swiftc -target arm64-apple-macos14.0 Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneWorkspaceProtocol.swift Hako/Containers/ArcaneHostProtocol.swift Hako/Containers/ArcaneClient.swift Hako/Containers/ArcaneKeychain.swift Hako/Containers/ArcaneStore.swift Hako/Containers/ArcaneFilesStore.swift Hako/Containers/ArcaneCommandProtocol.swift Hako/Containers/ArcaneTerminalTransport.swift Hako/Containers/ArcaneCommandsData.swift Tests/ArcaneCommandDataTests.swift -o /tmp/hako-arcane-command-data-tests
/tmp/hako-arcane-command-data-tests
```

测试覆盖配置与路径校验、Key 请求头、双类分页、容器模型、Docker CPU／内存／多接口网络计数、速率与计数重置、日志解码、权限错误、操作超时不重试、重建 ID、删除参数及重定向拒绝；加载回归测试覆盖会话复用、直接轮询容器、显式刷新环境、旧响应与旧错误隔离、取消后立即重载及容器替换。SwiftUI、Keychain、ATS、本地网络权限及真实实例兼容性仍需 iPhone 验收。

项目文件回归测试覆盖同名项目匹配、相对路径隔离、二进制／只读元数据、包含 Unicode 与特殊字符的文件名、multipart 上传与精确原文基线、专用配置接口只提交修改字段、保存冲突及不确定结果不重试。

编辑器行号测试覆盖空文件、末尾空行、连续空行、混合换行、Unicode／Emoji 的 UTF-16 偏移和行号查找，已接入 macOS CI。iPhone 验收需检查长行折行与滚动时行号对齐、中文输入、覆盖粘贴后保存／放弃、无文本剪贴板、只读文件，以及短文件和长文件编辑时点击「收起键盘」。

官方参考：[API](https://getarcane.app/docs/reference/api)、[容器](https://getarcane.app/docs/docker/containers)、[权限](https://getarcane.app/docs/access/roles)、[v2.17.1 容器实现](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/internal/container/service.go)。
