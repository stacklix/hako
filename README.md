# Hako

个人模块化工具集合，包含 iOS、Windows 和服务端应用。各应用独立管理源码、依赖、资源、测试、脚本和构建流程，使用各自语言的项目组织惯例。

## 应用入口

| 应用 | 目录 | 当前状态 |
| --- | --- | --- |
| iOS | [apps/ios](apps/ios/README.md) | 主应用服务器登录与扫码；使用时间采集与 GitHub 同步；运动记录、趋势图及年度 GitHub 归档；设备监控 Console；Arcane 容器管理；青龙任务、脚本与订阅管理；阿里云 ECS 监控与终端 |
| Windows | [apps/windows](apps/windows/README.md) | WPF 工具箱、设备代理、CPU 与内存监控 |
| 服务端 | [apps/server](apps/server/README.md) | Hako 统一后端、Web 管理控制台、Docker 部署、公钥认证、通用 OIDC、设备请求转发与 Caddy 访问日志统计 |

## 仓库结构

```text
hako/
├─ apps/
│  ├─ ios/           # iOS 工程、测试、脚本及安装页
│  ├─ windows/       # Windows 应用
│  └─ server/        # 服务端应用
├─ docs/             # 整体架构、跨端协作及平台专项文档
├─ .github/
│  └─ workflows/     # 各应用独立的 CI 工作流
├─ .gitignore
└─ README.md
```

各应用使用不同语言开发，没有共享代码包。各自目录变化触发对应 CI，各类登录、凭据与流程图见[登录与身份认证总览](docs/login-authentication-overview.md)，接口细节见 [Hako 服务器认证协议](docs/server-authentication.md)，设备监控的三端接口见 [设备监控协议](docs/device-monitoring.md)。

## 构建产物

最终产物统一放在仓库根目录 `dist/`（已被 Git 忽略）：

```text
dist/
├─ windows/Hako.exe                    # 包含运行时的单文件 Windows 应用
├─ server/hako-server-linux-amd64       # 独立 Linux x64 服务端
└─ ios/
   ├─ Hako.ipa                        # macOS CI 签名导出
   ├─ Hako.app                        # macOS 本地安装脚本生成
   └─ site/                           # OTA 安装页及分发资源
```

Windows 打包执行 `apps/windows/scripts/publish.ps1`，服务端打包执行 `apps/server/scripts/publish.ps1`（Linux/macOS 使用同目录 `publish.sh`）。iOS 可使用 macOS/Xcode、GitHub Actions，或本机已配置的 xkode 工作台构建与签名。

## 开发与验证

iOS 的功能、权限、安装和验证说明见 [iOS README](apps/ios/README.md)，自动打包与网页安装见 [iOS 分发文档](docs/ios/ci-install.md)。iOS README 中的命令均从 `apps/ios/` 执行。

在仓库根目录可运行安装页测试（支持 Windows）：

```sh
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

涉及 iOS 源码、资源或工程配置的任务，使用当前可用工具链异步构建、签名和打包；不因 Windows 统一跳过。已授权、已配对且在线的设备可用时安装启动，分别记录各阶段实际结果。
