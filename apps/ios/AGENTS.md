# iOS 界面规范

## 子应用设置入口

- 子应用页面的设置按钮统一参考「容器管理」，使用 SF Symbols `slider.horizontal.3`（滑杆图标）。
- 使用原生工具栏图标按钮，放在导航栏右上角：`ToolbarItem(placement: .topBarTrailing)`；同类入口保持系统默认的尺寸、颜色和按钮样式。
- 设置按钮必须提供描述具体用途的 `accessibilityLabel`，例如「Arcane 连接设置」「服务器与登录设置」。
- 新增或调整同类设置入口时沿用此规范，不单独改用齿轮等其他图标。
