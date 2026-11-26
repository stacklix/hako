# 数据备份配置

主应用统一管理备份目的地、账号、凭据和父目录，当前支持 Google Drive 与 WebDAV。可以同时启用多个目的地；子应用提交一次备份，主应用会尝试所有已启用的目的地，并分别保存成功或失败结果。

子应用只通过 `HakoDataBackupAccess` 提交数据、稳定应用标识、子目录、文件名和 MIME 类型，不引用任何存储供应商的类型、连接或凭据。

## 配置 Google Drive

1. 打开 [Google Cloud Console](https://console.cloud.google.com/)，创建或选择一个项目。
2. 在「API 和服务 → 库」搜索 **Google Drive API** 并启用。
3. 打开「Google Auth Platform → Branding」，填写应用名称（例如 Hako）、支持邮箱和开发者联系邮箱。
4. 在 Audience 选择 **External**。Testing 阶段把自己的 Google 账号加入 Test users。
5. 在 Data Access 添加 `https://www.googleapis.com/auth/drive.file`。只需此权限，不需要整个网盘的完整读写权限。
6. 在 Clients 点击 Create client，类型选择 **iOS**。Bundle ID 填 `me.stackli.hako`；如要求 Team ID，当前工程团队为 `A23G28RL2L`。App Store ID 可留空（若未上架）。
7. 复制生成的 Client ID（以 `.apps.googleusercontent.com` 结尾）。不需要 client secret、服务账号私钥或后端回调地址。
8. 在 Hako「设置 → 数据备份 → Google Drive 连接与配置说明」添加连接，填写连接名称和 Client ID，点击连接，在系统认证窗口选择 Google 账号并授权。
9. 返回「数据备份 → 添加备份目的地」，填写目的地名称，选择 Google Drive、已授权连接和父目录（默认 `Hako`），启用后保存。

正式对外发布时，在 Google Auth Platform → Branding 填写后端的公网 HTTPS 链接：Application home page 使用 `/`，Privacy policy 使用 `/privacy`，Terms of service 使用 `/terms`，均以实际 Hako 后端地址为前缀。这三个页面无需登录，随 Sora 服务端一同发布。域名需由项目维护者在 Google Search Console 验证，并加入 Authorized domains；填写链接不等于已通过品牌验证。

同一个 iOS Client ID 可供不同 Google 账号分别授权。连接与目的地分开管理，同一连接可配置多个父目录，无需重复授权。

长期自动化运行前，在 Audience 将外部 OAuth 应用发布状态改为 **In production**。Testing 状态下涉及 Drive 权限的 refresh token 通常 7 天后过期；应用发布状态与 Google 是否要求验证是不同事项。首次授权、授权失效后的重新连接须在主应用前台完成。

OAuth 使用系统 `ASWebAuthenticationSession`、随机 state 和 PKCE S256。令牌按连接 ID 隔离，保存在本机钥匙串，允许设备首次解锁后的后台访问，不发送到 Hako 服务端，不同步至 iCloud。断开连接仅清除该连接的本机令牌，不影响同一账号的其他本机连接；需要撤销 Google 端授权时，在 Google 账号的第三方应用授权管理中操作。

Drive 父目录从「我的云端硬盘」开始自动创建，使用 `/` 分层。仅管理 Hako 创建或已获得授权的目录；直接填写一个已有目录名称不会授予该目录权限，因此可能创建 Hako 自己的同名目录。多个可见同名目录会明确报错，避免选错位置。固定文件名只更新同目录内由同一子应用标记的文件。

## 配置 WebDAV

在「设置 → 数据备份 → 添加备份目的地」选择 WebDAV，填写：

- 目的地名称，例如「家庭 NAS」。
- WebDAV 目录地址，例如 `https://nas.example.com/remote.php/dav/files/backup/`。此地址必须是已经存在且可访问的 WebDAV 目录，不是网页登录页。
- 用户名和密码；支持时优先使用应用专用密码。
- 备份父目录，例如 `Hako`；留空使用 WebDAV 目录地址本身。

点击「验证 WebDAV 目录」会执行只读 PROPFIND，确认账号能读取该目录；备份时自动创建父目录和子目录。上传完成后下载回查，逐字节确认内容一致。固定文件名会更新同路径文件。使用 HTTPS；密码仅保存到本机专用钥匙串，编辑时密码留空保留已有值。

## 投资记账与统一快捷指令

在投资记账「设置 → 数据备份」配置子目录和文件名。默认相对路径：

```text
投资记账/投资记账-{date}-{time}.zip
```

`{date}` 为北京时间 `yyyy-MM-dd`，`{time}` 为北京时间 `HHmmssSSS`。主应用将每个目的地的父目录拼到此相对路径前。子应用不选择备份类型或账号。

快捷指令只保留统一的 **同步 Hako 数据** 入口，其中 **记账投资数据备份** 是普通子任务。通过快捷指令执行该子任务时，按北京时间判断星期：

- 周日：从已登录的 Hako 服务端导出账本 ZIP，调用主应用备份接口，分发至所有启用目的地。
- 其他日期：直接记录为「已跳过」，不读取服务端、不导出文件，也不访问备份目的地。

子应用设置中的「执行备份子任务」为手动运行，立即备份，不受星期限制，结果仍写入快捷指令执行历史。可在快捷指令个人自动化中每天运行统一入口，其他同步任务每天照常执行；在执行历史里查看各子任务结果和跳过原因。

账本 ZIP 包含服务端已保存的全部表 CSV 和 `schema.sql`，不包含尚未保存的编辑。统一入口会先执行当前的投资账本更新，再执行投资数据备份。备份不另外刷新行情或结算定投。

子任务由各子应用注册分组和正整数序号。不同分组并行，同组按序号从小到大串行；同组序号和子任务名称不得重复，注册错误会在整批开始前报告。使用时间属于 `usage` 组，加密资产属于 `crypto` 组，均为序号 1；投资账本更新和投资数据备份属于 `investment` 组，分别为序号 1、2。某个子任务失败或自身取消后仍继续同组后续任务，整批取消则停止所有分组。单独触发备份只执行备份，执行历史重试也只重跑未完成的子任务。执行进度同时显示所有运行中的子任务，各任务独立保存日志与本次耗时。快捷指令页和执行详情的子任务列表在状态下方显示本次耗时，执行中每秒更新，结束后使用实际起止时间计算，精确到两位小数秒；不累加并行步骤耗时，缺少起止时间时显示未记录。

## 多目的地结果与重试

主应用按配置顺序尝试所有已启用目的地。某个目的地失败不会阻止后续目的地；仅当全部启用目的地成功才报告该备份子任务成功。部分成功、上传中断或校验失败会保留已有目的地结果，便于检查。

Google Drive 上传后回查文件大小和 MD5；WebDAV 下载回查原始字节。上传请求不自动重放，响应丢失时先检查远端文件，再决定是否重试。统一同步入口（包括 App 内「立即同步 Hako 数据」）和执行历史中的重试均遵守子任务计划，投资备份仅在北京时间周日执行；非周日重试到备份时会按计划跳过，不导出或上传。只有在投资备份设置中单独点击「执行备份子任务」，才显式跳过星期限制。重试不重新执行成功或按计划跳过的子任务；实际备份时提交到所有启用目的地，带时间的文件名可能产生新的备份副本。

运行需要网络、有效的 Hako 服务端登录和足够的快捷指令执行时间。设备重启后须先解锁一次，才能读取钥匙串凭据。同一天多次手动运行或周日多次运行快捷指令会多次备份；当前不做每周去重，也不自动删除历史文件。

## 子应用接口

```swift
let report = try await AppServices.dataBackup().backup(
    data: archive,
    applicationID: "investment",
    file: HakoBackupFile(
        subdirectory: "投资记账",
        fileName: "投资记账-{date}-{time}.zip"
    ),
    mimeType: "application/zip",
    at: Date()
)
```

共享接口为 `HakoDataBackupAccess`，可用测试替身独立验证子应用。连接、目的地分发和上传校验属于主应用；周日运行规则属于投资记账子任务。

参考：[Google iOS 客户端配置](https://developers.google.com/identity/sign-in/ios/start-integrating)、[Drive 权限](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)、[OAuth 令牌有效期](https://developers.google.com/identity/protocols/oauth2#expiration)、[WebDAV 标准 RFC 4918](https://www.rfc-editor.org/rfc/rfc4918)。
