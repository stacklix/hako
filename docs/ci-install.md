# 自动打包与网页安装

默认分支每次 push 会编译 Release、导出已签名 IPA，并更新 GitHub Pages 安装页。也可从 Actions 手动运行。非默认分支不会发布。工作流使用 macos-26 的默认 Xcode，要求 Xcode 26.4 或更新。

## 首次配置

1. 将当前项目上传到你自己的 GitHub 仓库，保留 `.github/workflows/ios.yml`。
2. Apple Developer 后台登记手机 UDID，为 `me.stackli.hako` 创建 Development 或 Ad Hoc 描述文件。必须包含 Family Controls 和 App and Website Usage 两个 entitlement。下载描述文件。推荐先使用已在手机验证过的数据访问开发签名配置；分发签名仍受 Apple 的地区和授权限制。
3. 在 macOS「钥匙串访问」中找到匹配描述文件的 Apple Development 或 Apple Distribution 证书，连同私钥导出为带密码的 `.p12`。只有证书、没有私钥不能签名。
4. 仓库 Settings → Secrets and variables → Actions，添加以下 Repository secrets：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | P12 文件的 Base64 |
| `IOS_CERTIFICATE_PASSWORD` | 导出 P12 时设置的密码 |
| `IOS_PROFILE_BASE64` | mobileprovision 文件的 Base64 |

本地可用 `base64 -i /path/to/certificate.p12 | pbcopy` 和 `base64 -i /path/to/profile.mobileprovision | pbcopy` 复制对应内容，直接粘贴到 GitHub Secret。不要提交证书、私钥或描述文件。无需额外填写 Team ID，脚本从描述文件读取，并覆盖项目中的本地签名设置。

5. 仓库 Settings → Pages → Build and deployment → Source 选择 **GitHub Actions**。确认当前 GitHub 套餐支持该仓库使用 Pages。
6. 推送默认分支，或 Actions → Build and install Hako → Run workflow。完成后，进入 `github-pages` 环境中的 URL，在 iPhone Safari 打开，点击「安装 Hako」。标准地址通常是 `https://用户名.github.io/仓库名/`；自定义域名也支持，地址由 Pages 自动传入。

## 行为与限制

- 每次成功发布替换安装页，始终指向最新构建；IPA 与 manifest 使用内容哈希命名，避免缓存混用。旧安装链接不保证长期有效。
- 另发布固定入口 `manifest.plist`，指向本次构建的哈希 IPA；App 内「安装最新版」通过 `itms-services` 打开该入口，并附带时间参数以刷新缓存。系统仍需用户确认安装，安装进度与结果由 iOS 管理。
- Actions 同时保留 IPA artifact 14 天，可手动下载。构建号使用 GitHub run number。
- 发布时生成 `latest.json`，包含版本号、构建号与 UTC 构建时间（与 Pages 显示时间一致）；App 每次进入设置页都会重新请求，使用时间参数并绕过本地缓存，加载时清除上次读取的数据。仅当已发布构建号高于当前构建号时展示「安装最新版」及绿色图标，同行显示版本号和构建号，下一行按手机本地时区显示构建时间。读取失败或构建号无效时提示检查失败，不展示安装入口；「查看下载页面」始终可用。
- 只有已登记在描述文件中的设备才能安装；新增手机后需重新生成描述文件、更新 Secret 并重新打包。开发签名要求开启开发者模式。签名过期后也需更新并重建。
- Pages 页面和 IPA 默认可能公开可下载，即使源代码仓库私有也不能据此认定 Pages 私有。注册设备限制由 Apple 签名执行。OTA 安装需要手机能够直接通过 HTTPS 访问 manifest 和 IPA，登录保护可能导致系统安装失败。
- GitHub Actions 使用临时钥匙串，任务退出清理证书和描述文件；发布目录只含页面、IPA 和安装 manifest。IPA 本身包含 Apple 要求的描述文件。
- 此流程不会绕过屏幕时间数据导出的 entitlement、地区或系统授权要求，也不会自动发布到 App Store。

## 本地检查安装页

导出 IPA 后运行：

```sh
python3 scripts/build-install-page.py --ipa /path/to/Hako.ipa --url https://example.github.io/hako --output build/site
```

`build/site/index.html` 可本地预览；真正安装需部署到上述 HTTPS 地址。工作流首次真实签名和 OTA 安装需在配置 Secrets 并推送后验证。
