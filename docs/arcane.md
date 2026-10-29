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
| 拉取镜像并重新部署 | `containers:redeploy`，Compose 更新的额外授权以服务端为准 |
| 删除已停止的容器 | `containers:delete` |
| 操作期间的进度与日志（可选） | `activities:read` |

权限不足展示 403 提示，不自动扩大授权。未授权活动记录时仍可提交已有权限的操作，进度显示等待服务端响应。未实现创建／编辑容器、终端、Compose 编辑和自动更新开关。

列表加载完整分页（单次最多 10,000 项），按名称排序；顶部依次为紧凑的环境卡片、搜索框和独立圆角筛选按钮，选中项深色显示。可搜索名称、镜像、Compose 项目，筛选全部、异常、停止及有更新的容器；筛选按钮不展示数量，空间不足时可横向滚动。「容器」列表标题右侧显示「Compose 分组」复选框，勾选后按项目分组，取消后恢复按名称排列的列表。运行状态及其图标为绿色，停止为灰色，异常为红色；「有更新」显示在状态右侧。分组只改变展示方式，不对项目执行批量修改。列表前台可见时每 10 秒刷新，进入详情、打开设置或切后台时停止列表轮询。失败保留原数据和最近更新时间，支持下拉刷新。

进入详情立即加载数据，前台可见时每 10 秒刷新状态；移除导航栏刷新按钮，保留下拉刷新，同时重连实时资源及日志。详情加载期间先显示列表已有的容器状态，运行状态及图标为绿色，停止为灰色，异常为红色。CPU、内存及网络从单容器 WebSocket 读取，不把缺失值填成零。内存扣除 Docker 缓存后显示使用率及使用量；右侧网络以上行 `tx_bytes`、下行 `rx_bytes` 汇总所有接口，以两次采样的差值／时间间隔计算 B/s、KB/s、MB/s、GB/s，同时可展开累计流量。首次采样、重连、计数重置或间隔超过 30 秒时等待下一次有效采样；没有网络计数时明确显示不可用。累计值属于 Docker 当前容器计数，不是 Hako 历史流量。

日志仅在日志页前台且开启跟随时订阅，重连读取最近 100 行，内存中最多保留 500 行／512 KiB；长行有显示长度上限。离开详情、切后台或操作开始时取消实时订阅。导出通过下载接口获取 Docker 仍保留的日志，最多 256 MB，保存临时文件后由系统分享；离开页面清理该导出文件。环境变量默认遮蔽，用户可主动显示。

## 更新与操作结果

更新入口保留「拉取镜像并重新部署」，调用 `POST /api/environments/{env}/containers/{id}/redeploy`。Arcane v2.17.1 会对已登记的 Compose 服务使用项目配置更新；客户端不根据旧 inspect 结果自行拼装或创建容器。服务端返回新的容器 ID 后，详情、资源和日志订阅切换到新 ID。检查更新显示版本／摘要及检查状态，不把检查失败当作没有更新。

启停、重启、删除及重新部署均使用居中的系统 `alert` 确认框，包含环境、容器名称、操作影响、确认及取消按钮。删除只允许已停止等可删除状态，固定 `force=false`、`volumes=false`。停止／重启自动移除容器时单独提示 Docker 的自动删除行为。

同一时间只提交一个操作。提交前保存不含密钥的待确认记录；网络超时、服务端 5xx、已接受但未完成或重建响应缺少新 ID 时保留记录，阻止直接重复提交。不自动重试写操作，活动记录的成功状态也不代替实际请求结果。应用重启后提示核对状态，用户可刷新／在 Arcane 检查活动记录，再点击「已核对状态，清除此提示」。后台、关闭 App 或网络断开不代表服务端操作取消。

## 验证

Windows 本机跳过 iOS 编译、归档、签名和安装。可运行现有安装页测试：

```powershell
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

macOS CI 新增模拟网络测试，无真实服务器和容器写入：

```sh
cd apps/ios
swiftc Hako/Containers/ArcaneProtocol.swift Hako/Containers/ArcaneClient.swift Tests/ArcaneTests.swift -o /tmp/hako-arcane-tests
/tmp/hako-arcane-tests
```

测试覆盖配置与路径校验、Key 请求头、双类分页、容器模型、Docker CPU／内存／多接口网络计数、速率与计数重置、日志解码、权限错误、操作超时不重试、重建 ID、删除参数及重定向拒绝。SwiftUI、Keychain、ATS、本地网络权限及真实实例兼容性仍需 iPhone 验收。

官方参考：[API](https://getarcane.app/docs/reference/api)、[容器](https://getarcane.app/docs/docker/containers)、[权限](https://getarcane.app/docs/access/roles)、[v2.17.1 容器实现](https://github.com/getarcaneapp/arcane/blob/v2.17.1/backend/internal/container/service.go)。
