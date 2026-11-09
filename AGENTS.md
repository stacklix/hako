# Hako 协作规范

## 三端版本兼容性

- 服务端、iOS 和 Agent 的发布版本统一使用 `主版本.次版本.补丁版本` 三段非负整数，逐段按数值比较。iOS 使用应用的营销版本，Agent 使用程序集版本。
- 每次修改代码都要在同一改动中更新受影响组件的发布版本。向后兼容的改动递增第三段。打破兼容性的改动递增第二段并将第三段归零。涉及多个组件时分别更新各自版本，最低版本只在实际兼容要求变化时调整。
- 版本入口分别为服务端 `apps/server/internal/server/version.go` 的 `releaseVersion`、iOS `apps/ios/Hako.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`（Debug 和 Release 同步），以及 Agent `apps/windows/src/Hako/Hako.csproj` 的 `Version`。
- 最低版本的前两段指定兼容版本线。实际版本的前两段必须与该版本线相同，第三段必须达到最低要求。例如最低要求为 `0.1.2` 时，`0.1.10` 兼容，`0.1.1` 和 `0.2.0` 均不兼容。修改中间段代表兼容性断开，旧版服务端和客户端需要协同升级。
- 服务端通过无需登录的 `GET /api/v1/version` 返回 `serverVersion`、`minimumIosVersion` 和 `minimumAgentVersion`。发布时维护 `apps/server/internal/server/version.go` 中的服务端版本和客户端要求。涉及兼容版本线变更时，同步维护两端客户端声明的最低服务端版本及对应测试。
- iOS 在启动及回到前台时检查，Agent 在连接时检查。客户端需同时检查自身版本和服务端版本，不兼容时弹框说明当前版本、兼容版本要求和需要升级的一方。
