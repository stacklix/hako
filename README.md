# Hako

个人模块化工具集合，包含 iOS、Windows 和服务端应用。各应用独立管理源码、依赖、资源、测试、脚本和构建流程，使用各自语言的项目组织惯例。

## 应用入口

| 应用 | 目录 | 当前状态 |
| --- | --- | --- |
| iOS | [apps/ios](apps/ios/README.md) | 主应用服务器登录与扫码；使用时间采集与 GitHub 同步；设备监控 Console；Arcane 容器管理；阿里云 ECS 监控与终端 |
| Windows | [apps/windows](apps/windows/README.md) | WPF 工具箱、设备代理、CPU 与内存监控 |
| 服务端 | [apps/server](apps/server/README.md) | Hako 统一后端、Web 管理控制台、Docker 部署、公钥认证与设备请求转发 |

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

各应用使用不同语言开发，没有共享代码包。各自目录变化触发对应 CI，应用级认证、会话和扫码登录见 [Hako 服务器认证协议](docs/server-authentication.md)，设备监控的三端接口见 [设备监控协议](docs/device-monitoring.md)。

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

Windows 打包执行 `apps/windows/scripts/publish.ps1`，服务端打包执行 `apps/server/scripts/publish.ps1`（Linux/macOS 使用同目录 `publish.sh`）。iOS 打包需在 macOS/Xcode 或 GitHub Actions 中执行。

## 开发与验证

iOS 的功能、权限、安装和验证说明见 [iOS README](apps/ios/README.md)，自动打包与网页安装见 [iOS 分发文档](docs/ios/ci-install.md)。iOS README 中的命令均从 `apps/ios/` 执行。

在仓库根目录可运行安装页测试（支持 Windows）：

```sh
python -m unittest discover -s apps/ios/Tests -p 'test_*.py'
```

iOS 编译、归档、签名及设备安装需要 macOS 和 Xcode，在 Windows 上跳过；可在 Windows 上执行的验证仍正常运行。
