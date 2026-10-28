# Hako Server

单用户设备管理服务，使用 Go、SQLite 和 WebSocket，内置 `/admin/` Web 管理页。Windows 是设备代理（Agent），iOS 是管理客户端（Console）。服务端按需转发通用设备动作与 JSON 结果，当前 Agent 提供 CPU、内存查询，不保存历史指标。

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

先在 iOS「设备监控 → 设置 → 本机设备身份」打开「查看与导出公钥」，在 sheet 中查看、复制 PEM 内容或导出 `iphone.public.pem`。无需配置服务器、联网或登录。把这个公钥放入服务器 `config/`，编辑 `config/server.json`：

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

Console 公钥**每次启动都以配置文件为准**，增删后重启生效，网页只读。Agent 公钥首次启动时从配置导入，之后由数据库和 Web 管理页即时维护；重启不重新引入已删除的 Agent 公钥。`agents` 初始可为空。

```sh
docker compose config --quiet
docker compose up -d
```

本目录提供 [.env.example](.env.example)，复制为 `.env` 后必须将 `HAKO_PUBLIC_URL` 改为外部客户端实际访问的 HTTPS 根地址，不带路径、查询或 fragment，三端地址需保持一致。Compose 仅将 HTTP 端口暴露到主机 `127.0.0.1:8080`。在主机配置 HTTPS 反向代理，Caddy 示例见 [deploy/Caddyfile.example](deploy/Caddyfile.example)，支持 WebSocket Upgrade。

编辑配置时保留 `init` 生成的 `masterKey`。容器使用非 root 用户、只读根文件系统、宿主机数据目录挂载、健康检查和自动重启。Windows Docker 或其他 UID 映射环境需要相应设置权限，确保容器 UID 10001 可读写 `data/`、可读 `config/` 中的配置与公钥。

## Web 管理页

1. iOS「设备监控」使用本机密钥登录 Console。
2. 浏览器打开 `https://你的服务地址/admin/`，显示二维码和六位确认码。
3. iOS「设备监控 → 扫码登录管理页」扫描二维码，或复制网页登录请求后在该页粘贴解析。
4. 核对服务器、浏览器及两端确认码，勾选已核对后批准。批准前用 Face ID / Touch ID 或设备密码验证本机身份，随后使用设备签名和有效 Console 会话提交批准。
5. 网页自动完成登录；只扫描不会登录。也可在 Console 拒绝请求。

- Agent：查看在线/离线状态、最近活动时间、密钥指纹；粘贴或读取 PEM 公钥文件登记，查看和下载公钥，移除设备。
- 指标与动作：对在线 Agent 按需查询 CPU、物理内存及采样时间，也可从 Agent 上报的能力清单选择动作、填写 JSON 参数并查看 JSON 结果。状态每 10 秒刷新，指标不自动持续采集。
- Console：只读查看和下载公钥；查看和撤销登录会话。HTTP 客户端没有实时在线标识。所有 Console 公钥必须在文件中手工维护。
- Agent 修改即时生效，移除后关闭现有连接并拒绝后续认证。Console 从配置移除并重启后，清理其所有会话和未完成的登录挑战；重新加入不会恢复旧会话。

二维码有效期 90 秒，批准和领取只允许一次；二维码不包含浏览器私有 Cookie、Console 凭据或私钥。领取会话必须由原浏览器持有 HttpOnly Cookie 并从正确 origin 发起。刷新二维码废弃同一浏览器之前的请求。只扫描自己正在使用的网页，不批准他人转发的二维码；两端确认码核对参考 [RFC 8628 远程诱导防护](https://www.rfc-editor.org/rfc/rfc8628.html#section-5.4)。

管理页使用 HttpOnly、SameSite=Strict 的独立会话 Cookie，HTTPS 下启用 Secure 和 `__Host-`；修改请求还校验 origin 和 CSRF。网页会话闲置 30 分钟、登录 12 小时、主动退出或服务重启后失效，状态轮询不续期。网页还绑定批准它的 Console 会话：Console 退出、被撤销或重新主动登录替换旧会话后，关联网页会话失效。Console 长期凭据不会传给网页。

## 设备调用接口

- Console：`POST /api/v1/agents/{id}/requests`，使用 DPoP 会话认证。
- 网页：`POST /admin/api/agents/{id}/requests`，使用管理 Cookie 与 CSRF。
- 正文：`{"method":"system.metrics","params":{}}`。
- HTTP 200 返回 `{"result":任意JSON值}` 或 `{"error":{"code":"错误码","message":"错误信息"}}`；转发及鉴权失败使用 HTTP 错误状态。
- Agent 使用 WebSocket v2，在 `hello.methods` 中声明动作名与版本；设备列表和管理概览返回当前连接的 `methods`。服务端不依赖具体动作和指标模型，新增动作、参数和结果字段通常无需升级服务端。

超时、断线可能发生在动作已经执行之后，有副作用的动作应先确认结果再决定是否重试。具体格式及限制见[设备监控协议](../../docs/device-monitoring.md)。

## 登记设备

1. Windows → 服务器设置 → 生成密钥或导入 RSA 私钥 → 导出公钥，在 Web 管理页「登记 Agent」填写设备 ID、名称和 RSA 公钥。设置 Windows 服务地址和账号，保存并连接。
2. iOS → 设备监控 → 设置 → 查看与导出公钥 → 复制内容或导出文件，手工配置到服务端 `consoles` 后重启；此操作不要求填写服务器信息或登录。
3. iOS → 设备监控 → 设置 → 填写 HTTPS 地址和账号 → 保存服务器配置 → 使用本机密钥登录，即可监控和批准网页登录。
4. iOS 选择在线电脑，查询 CPU、物理内存和本次采样时间。

iOS 设备 ID 为公钥的 RFC 7638 JWK 指纹，无需另行配置。服务端从已登记公钥计算相同 ID，校验请求签名和会话绑定。

## 登录态与撤销

- 访问令牌 15 分钟有效，刷新凭据无固定或闲置到期时间；只有在未撤销、密钥匹配时才能续期。
- 刷新凭据轮换，保留上一轮的请求 ID，用于恢复丢失的响应；不同请求 ID 重用旧凭据会撤销整个会话。
- 每个业务请求都校验设备签名、时间、请求 JTI、访问令牌哈希及服务端会话。JTI 防重放记录持久保存。
- 同一设备重新主动登录会替换该设备旧会话。关闭 App 或重启服务端不等于退出。
- iOS 支持退出和撤销其他管理客户端会话。离线退出立即停止本地使用，密封保存仅用于撤销的凭据，恢复网络后重试。
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

iOS 扫码、相机权限和本机身份验证需在 iPhone 上验收；Windows 本机跳过 iOS 构建，macOS CI 执行协议测试、类型检查和打包。

Windows 真实联调可将 `HAKO_WINDOWS_CHECKS` 设置为 [Windows 检查程序](../windows/README.md) 的绝对路径后运行 `go test ./internal/server -run TestWindowsAgentEndToEnd -v`。该检查启动真实 C# 代理，验证 RSA 认证、请求转发及实际 CPU/内存采样。

协议见 [设备监控协议](../../docs/device-monitoring.md)。返回 [仓库说明](../../README.md)。
