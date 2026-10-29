# Hako Server

Hako 的统一后端，使用 Go、SQLite 和 WebSocket，为主应用及各子应用提供服务，内置 `/admin/` Web 管理控制台。服务器身份认证、会话和扫码登录属于应用级能力；设备管理与通用 Agent 请求转发是当前业务模块。设备代理（Agent）可运行在不同平台，仓库当前提供 Windows 实现；iOS 是管理客户端（Console）。服务端按需转发通用设备动作与 JSON 结果，当前 Agent 提供 CPU、内存查询，不保存历史指标。

两类客户端使用配置中的唯一账号及预先登记的设备公钥：Agent 使用 RSA-PSS/SHA-256，Console 使用 Secure Enclave P-256 和 DPoP。所有已登记 Console 都是管理员，可以批准网页登录。没有密码、TOTP、管理密钥登录或公开注册入口。

## Docker 部署

### 自动发布镜像到 GHCR

GitHub Actions 工作流 [Server Docker](../../.github/workflows/server-docker.yml) 自动构建 Linux amd64 镜像并发布到 `ghcr.io/stacklix/hako-server`，使用自带的 `GITHUB_TOKEN` 和仅授予发布任务的 `packages: write` 权限，无需另配仓库密码或 PAT。发布结果取代原来的镜像压缩包构建产物。

- `master`：在 `apps/server/` 或镜像工作流有变更时发布，对比本次推送前后的提交，镜像带有 `latest`、`master` 和 `sha-<短提交号>` 标签。仅修改 iOS、Windows 或仓库级文档时跳过。
- tag：推送任意 tag 都发布，不过滤路径，镜像带有对应 tag 和 `sha-<短提交号>` 标签。tag 名中的 `/` 等字符由 Docker metadata action 转换为合法镜像标签字符。
- 手动运行：在 Actions 中执行 Run workflow，按所选分支或 tag 生成标签；选择 `master` 时也更新 `latest`。
- 删除分支或 tag 时不发布。

服务器直接拉取：

```sh
docker pull ghcr.io/stacklix/hako-server:latest
```

GHCR 新建包默认私有。需要匿名拉取时，在包设置中将可见性改为 Public；私有包需要先通过 `docker login ghcr.io` 登录，使用拥有该包读取权限且具有 `read:packages` scope 的 PAT（classic），通过 `--password-stdin` 传入。工作流发布使用的 `GITHUB_TOKEN` 无需手工配置该 PAT。参见 [GHCR 官方文档](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)。

仓库的 `docker-compose.yaml` 默认使用发布镜像，容器名为 `hako-server`。完成下方配置初始化与 Console 公钥登记后执行 `docker compose up -d`。更新执行 `docker compose pull && docker compose up -d`。生产环境可使用 `sha-<短提交号>` 或 digest 固定版本。

### 部署配置与启动

以下命令从 `apps/server/` 执行，面向 Linux Docker 主机。

部署文件与示例：

```text
docker-compose.yaml
.env.example                 # 复制为 .env，填写实际 HTTPS 地址
config/server.example.json   # 配置格式示例；实际 server.json 由 init 生成
```

```sh
cp .env.example .env
# 编辑 .env，设置实际的 HAKO_PUBLIC_URL。
mkdir -p data config
docker compose pull
docker run --rm --user 0 \
  -v "$PWD/data:/app/data" \
  -v "$PWD/config:/app/config" \
  --entrypoint sh ghcr.io/stacklix/hako-server:latest \
  -c 'hako-server init && chown 10001:10001 /app/data /app/config /app/config/server.json && chmod 700 /app/data /app/config'
```

`init` 创建 `config/server.json`，自动生成 `masterKey`，账号默认为 `owner`，设备列表为空；已有配置文件不会被覆盖。`masterKey` 是 32 字节随机数据的 hex（十六进制）编码，共 64 个字符，读取时支持大小写，不带 `0x` 前缀，用于加密持久化业务状态和生成刷新令牌。配置与 SQLite 数据需要一起备份。

手工配置时，可运行以下命令生成密钥，将输出填入 `masterKey`：

```sh
openssl rand -hex 32
```

已有数据库升级时，需将原有 Base64URL 密钥解码为原来的 32 字节后再转成 hex，保持密钥字节不变；不能重新生成密钥，否则无法解密已有数据库。服务端启动只读取配置，不自动生成或写回密钥。

持久化文件均位于 `docker-compose.yaml` 旁，挂载关系如下：

| 宿主机路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `./data/` | `/app/data/` | SQLite 数据，允许服务端读写 |
| `./config/` | `/app/config/` | 主密钥、账号、设备配置与公钥，只读 |

主密钥与 Console 公钥配置统一保存在 `config/server.json`。手工配置时可参考 [config/server.example.json](config/server.example.json)，其 `masterKey` 留空，不能直接用于启动。建议先执行上述 `init` 生成随机密钥，再参照示例填写 Console 公钥。若选择复制模板为 `server.json`，需自行填入安全生成的实际密钥，且不要再运行 `init`。真实 `.env`、`config/server.json` 和公钥文件不纳入版本控制。

先在 iOS「设置 → 服务器与登录 → 本机设备身份」打开「查看与导出公钥」，在 sheet 中查看、复制 PEM 内容或导出 `iphone.public.pem`。无需配置服务器、联网或登录。把这个公钥放入服务器 `config/`，编辑 `config/server.json`：

```json
{
  "username": "owner",
  "masterKey": "保留 init 生成的 64 字符 hex 密钥",
  "agents": [],
  "consoles": [
    { "name": "我的 iPhone", "publicKeyFile": "/app/config/iphone.public.pem" }
  ]
}
```

可配置多台 Console，每台使用独立 P-256 公钥，均具有管理员权限；也可用 `publicKeyPem` 直接填写 PEM 公钥字符串。私钥始终保留在 iPhone。未登记 Console 时，网页会提示手工配置，不能登录。

Console 公钥**每次启动都以配置文件为准**，增删后重启生效，网页不展示管理客户端及其公钥。Agent 公钥首次启动时从配置导入，之后由数据库、Web 管理页和已登录的 iOS Console 即时维护；重启不重新引入已删除的 Agent 公钥。`agents` 初始可为空。

```sh
docker compose config --quiet
docker compose up -d
```

本目录提供 [.env.example](.env.example)，复制为 `.env` 后必须将 `HAKO_PUBLIC_URL` 改为外部客户端实际访问的 HTTPS 根地址，不带路径、查询或 fragment，三端地址需保持一致。Compose 仅将 HTTP 端口暴露到主机 `127.0.0.1:8080`。在主机配置 HTTPS 反向代理，Caddy 示例见 [deploy/Caddyfile.example](deploy/Caddyfile.example)，支持 WebSocket Upgrade。

编辑配置时保留 `init` 生成的 `masterKey`。容器使用非 root 用户、只读根文件系统、宿主机数据目录挂载、健康检查和自动重启。Windows Docker 或其他 UID 映射环境需要相应设置权限，确保容器 UID 10001 可读写 `data/`、可读 `config/` 中的配置与公钥。

## Web 管理页

1. 在 Hako iOS「设置 → 服务器与登录」使用本机密钥登录 Console。
2. 浏览器打开 `https://你的服务地址/admin/`，显示二维码和六位确认码。
3. Hako iOS 首页「扫码登录」直接扫描二维码，或在扫码区域下方粘贴并解析网页登录请求。
4. 在确认页核对服务器、来源 IP 及两端确认码，点击「确认登录」，使用设备签名和有效 Console 会话提交批准，无需额外的 Face ID、Touch ID 或设备密码验证。
5. 网页自动完成登录；只扫描不会登录。也可在 Console 拒绝请求。

确认页的「来源 IP」由服务端在浏览器创建二维码时记录，支持 IPv4/IPv6，不是扫码手机的 IP。它是服务端看到的来源地址；经过 NAT、VPN 时通常是出口地址，无法据此取得浏览器设备的局域网 IP。浏览器名称仍用于已登录设备列表，依据 HTTP User-Agent 判断，包含 iOS Chrome 的 `CriOS`、Firefox 的 `FxiOS` 和 Edge 的 `EdgiOS` 标识；该名称只是提示信息。

通过反向代理部署时，在 `.env` 设置 `HAKO_TRUSTED_PROXIES`，填写**服务端实际看到的代理 IP 或 CIDR**，多项以逗号分隔，并重建容器使环境变量生效。原生部署可使用 `127.0.0.1,::1`；Docker 下应填写实际网关/代理地址，不能直接照抄 loopback。默认留空，不信任转发头，显示直接连接地址。仅可信代理提供的 `X-Forwarded-For` 会被读取，并从右向左取首个不可信地址；代理须覆盖或正确追加该头。不要将所有地址设为可信，否则来源可能被伪造。来源 IP 仅通过已认证 Console 的请求详情返回，不写入二维码或公开轮询响应；需要同步更新 iOS 与服务端。

- Agent：查看在线/离线状态、最近活动时间、密钥指纹；粘贴或读取 PEM 公钥文件登记，查看和下载公钥，移除设备。
- 能力调用：下拉选项完全来自 Agent 上报的能力清单，显示能力名称与版本；用户填写 JSON 对象参数后提交，统一以 JSON 展示返回结果或业务错误。网页不内置具体业务能力、参数模板、字段校验或专用数据展示，也不额外插入清单以外的命令。状态每 10 秒刷新，不自动调用能力。
- 支持 Codex 统计的 Agent 会声明 `query.codex.usage` v1，网页选择该能力并提交 `{}` 即可获取近 7 天用户调用数/token 和处理中会话数、项目名与显示标题；服务端仅透传，不读取本机 Codex 文件或保存历史用量。[统计说明](../../docs/codex-usage.md)。
- 网页 `GET /admin/api/agents` 返回 `agents,updatedAt`，只展示 Agent，不展示管理客户端列表、数量、公钥或手机登录会话；设备列表接口不返回管理客户端信息。会话查看和网页登录撤销仅接受 iOS Console 的 DPoP 认证，Console 公钥在服务端配置文件中手工维护。
- Agent 修改即时生效，移除后关闭现有连接并拒绝后续认证。Console 从配置移除并重启后，清理其所有会话和未完成的登录挑战；重新加入不会恢复旧会话。

二维码有效期 90 秒，批准和领取只允许一次；二维码不包含浏览器私有 Cookie、Console 凭据或私钥。领取会话必须由原浏览器持有 HttpOnly Cookie 并从正确 origin 发起。刷新二维码废弃同一浏览器之前的请求。只扫描自己正在使用的网页，不批准他人转发的二维码；两端确认码核对参考 [RFC 8628 远程诱导防护](https://www.rfc-editor.org/rfc/rfc8628.html#section-5.4)。

管理页使用 HttpOnly、SameSite=Strict 的独立会话 Cookie，HTTPS 下启用 Secure 和 `__Host-`；修改请求还校验 origin 和 CSRF。网页会话闲置 30 分钟、登录 12 小时、主动退出或服务重启后失效，状态轮询不续期。网页还绑定批准它的 Console 会话：Console 退出、被撤销或重新主动登录替换旧会话后，关联网页会话失效。Console 长期凭据不会传给网页。

iOS「设置 → 服务器与登录 → 已登录设备」统一显示 Console 和有效的网页管理端登录，网页项显示浏览器、登录时间及最近活动时间，可下拉刷新。点击「移除网页登录」可单独撤销所选浏览器会话，该浏览器下次请求即需要重新扫码；其他网页和手机的登录不受影响。此功能需要同步更新服务端和 iOS。网页不提供登录会话列表，手机及网页登录会话统一在 iOS 中管理。

## 应用级接口与命名

认证使用 `/api/v1/auth/*`，会话管理使用 `/api/v1/sessions` 与 `/api/v1/web-sessions/{id}`，设备业务使用 `/api/v1/agents/*`，名称已按职责划分，继续沿用。Console 是管理客户端角色，不限定为设备监控。

扫码请求详情、批准和拒绝统一使用 `/api/v1/auth/web-login/requests/{id}` 及其 `/approve`、`/deny` 子路径，二维码使用 `hako://web-login?v=1&server=<origin>&request=<id>`。原 `/api/v1/admin-login/requests/*` 和 `hako://admin-login` 不再支持，服务端与 iOS 必须同步更新，更新后刷新网页二维码。`/admin/` 和 `/admin/api/*` 表示 Web 管理控制台及其 Cookie/CSRF 接口，继续沿用。完整约定见 [Hako 服务器认证协议](../../docs/server-authentication.md)。

网页 Agent 列表统一使用 `GET /admin/api/agents`，原 `/admin/api/overview` 已移除。账号信息仍由 `/admin/api/session` 返回。Console 会话可查看，但不再提供 `DELETE /api/v1/sessions/{id}`；本机退出使用 `/api/v1/auth/logout`。要禁止某台 Console 再次登录，应移除配置文件中的公钥并重启服务。

## 设备调用接口

- Console：`POST /api/v1/agents/{id}/requests`，使用 DPoP 会话认证。
- Console 登记 Agent：`POST /api/v1/agents`，使用同样的 DPoP 会话与设备签名认证，正文为 `{"name":"我的设备","publicKeyPem":"PEM 公钥"}`；服务端自动生成 5 位设备 ID（大写字母和数字，以字母开头），成功返回 HTTP 201 及 `id,keyId`，无需重启。iOS 和网页只需填写名称与公钥。接口仍接受可选的 `id`，格式为 `[A-Z][A-Z0-9]{0,4}`。与网页共用 RSA 公钥校验、重复检查及持久化；重复公钥或显式指定的 ID 返回 409，非法设备信息、公钥或私钥返回 400。需要同步更新服务端与 iOS。
- 网页：`POST /admin/api/agents/{id}/requests`，使用管理 Cookie 与 CSRF。
- 正文：`{"method":"query.all","version":1,"params":{}}`。
- HTTP 200 返回 `{"result":任意JSON值}` 或 `{"error":{"code":"错误码","message":"错误信息"}}`；转发及鉴权失败使用 HTTP 错误状态。
- Agent 使用 WebSocket v3，在 `hello.capabilities` 中声明动作名与版本；Console 和网页的设备列表接口返回最近一次成功认证的 `capabilities`（离线仍保留，首次连接前为 null）。服务端不依赖具体动作和指标模型，新增动作、参数和结果字段通常无需升级服务端。

超时、断线可能发生在动作已经执行之后，有副作用的动作应先确认结果再决定是否重试。具体格式及限制见[设备监控协议](../../docs/device-monitoring.md)。

## 登记设备

1. Windows → 服务器设置 → 生成密钥或导入 RSA 私钥 → 导出公钥，在已登录 iOS 的「设备监控 → 添加 Agent」填写设备名称，粘贴或导入 RSA 公钥；也可使用 Web 管理页「登记 Agent」，设备 ID 均由服务端自动生成。设置 Windows 服务地址和账号，保存并连接；认证失败后完成登记需重新连接。
2. iOS → 设置 → 服务器与登录 → 查看与导出公钥 → 复制内容或导出文件，手工配置到服务端 `consoles` 后重启；此操作不要求填写服务器信息或登录。
3. iOS → 设置 → 服务器与登录 → 填写 HTTPS 地址和账号 → 保存服务器配置 → 使用本机密钥登录，即可监控和批准网页登录。
4. iOS 选择在线设备，按设备声明的能力查询数据或发起操作；支持系统指标的设备可查看 CPU、物理内存和本次采样时间。

iOS 设备 ID 为公钥的 RFC 7638 JWK 指纹，无需另行配置。服务端从已登记公钥计算相同 ID，校验请求签名和会话绑定。

## 登录态与撤销

- 访问令牌 15 分钟有效，刷新凭据无固定或闲置到期时间；只有在未撤销、密钥匹配时才能续期。
- 刷新凭据轮换，保留上一轮的请求 ID，用于恢复丢失的响应；不同请求 ID 重用旧凭据会撤销整个会话。
- 每个业务请求都校验设备签名、时间、请求 JTI、访问令牌哈希及服务端会话。JTI 防重放记录持久保存。
- 同一设备重新主动登录会替换该设备旧会话。关闭 App 或重启服务端不等于退出。
- iOS 支持本机退出及单独撤销网页登录，不提供远程删除其他 Console 会话。离线退出立即停止本地使用，密封保存仅用于撤销的凭据，恢复网络后重试。
- 在配置文件删除 Console 公钥并重启，相关会话被清理；重新加入不会复活旧会话。

操作员需要撤销所有 Console 登录时，先停止服务，再操作数据库，避免运行中的内存状态覆盖撤销结果：

```sh
docker compose stop server
docker compose run --rm server revoke-consoles
docker compose up -d server
```

这不会删除已登记公钥，用户仍可主动用合法设备重新登录。设备遗失时应同时移除对应公钥。

## 本地开发与验证

需要 Go 1.26 或更新版本：

```sh
go test ./...
go vet ./...
go run ./cmd/hako-server init
go run ./cmd/hako-server
```

独立 Linux x64 二进制统一输出到仓库根目录 `dist/server/hako-server-linux-amd64`：Windows 执行 `./scripts/publish.ps1`，Linux/macOS 执行 `bash scripts/publish.sh`。CI 同时提供该产物；Docker 部署继续使用本目录的 Dockerfile 和 Compose 配置。

默认配置文件 `config/server.json`、数据目录 `data/`；可通过 `HAKO_CONFIG_FILE`、`HAKO_DATA_DIR` 覆盖。主密钥在配置文件的 `masterKey` 字段中维护。`HAKO_LISTEN` 默认 `:8080`。本地开发默认公开地址 `http://localhost:8080`；仅 loopback 允许 HTTP。iOS 始终要求 HTTPS。

测试覆盖 Console 和 Agent 认证、签名重放、长期会话、轮换恢复、退出、查询转发、离线和超时，以及二维码过期、拒绝、刷新、浏览器绑定、一次性领取、确认码与签名 nonce、Console 撤销联动、Cookie/CSRF、并发 Agent 登记及配置迁移。网页和二维码生成功能内嵌于二进制，无需 CDN 或前端运行依赖。

iOS 扫码、相机权限、会话列表和网页登录移除需在 iPhone 上验收；Windows 本机跳过 iOS 构建，macOS CI 执行协议测试、类型检查和打包。

Windows 真实联调可将 `HAKO_WINDOWS_CHECKS` 设置为 [Windows 检查程序](../windows/README.md) 的绝对路径后运行 `go test ./internal/server -run TestWindowsAgentEndToEnd -v`。该检查启动真实 C# 代理，验证 RSA 认证、请求转发及实际 CPU/内存采样。

协议见 [设备监控协议](../../docs/device-monitoring.md)。返回 [仓库说明](../../README.md)。

命令固定使用 `query.` / `action.` 前缀，详见 [命名规范](../../docs/agent-command-naming.md) 与 [v3 协议](../../docs/device-monitoring.md)。查询支持 `query.all` 聚合及 `query.system.metrics` 单项；操作 `action.network.http.check` v1 接收 `{ "url": "https://example.com/" }`，由 Agent 检测连通性。所有调用均包含独立 `version`。
