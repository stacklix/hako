# iOS 界面规范

## 子应用设置入口

- 子应用页面的设置按钮统一参考「容器管理」，使用 SF Symbols `slider.horizontal.3`（滑杆图标）。
- 使用原生工具栏图标按钮，放在导航栏右上角：`ToolbarItem(placement: .topBarTrailing)`；同类入口保持系统默认的尺寸、颜色和按钮样式。
- 设置按钮必须提供描述具体用途的 `accessibilityLabel`，例如「Arcane 连接设置」「服务器与登录设置」。
- 新增或调整同类设置入口时沿用此规范，不单独改用齿轮等其他图标。

## 表单字段名称

- 所有表单字段必须始终显示字段名称（key），包括空值、已填写、编辑中及禁用状态；不能仅用输入框占位文字说明字段用途。
- 文本、密码和多行输入优先采用上下布局：上方为字段名称，下方为输入控件，使用 `VStack(alignment: .leading, spacing: 6)`；名称使用 `.font(.subheadline).foregroundStyle(.secondary)`。名称可由明确的独立分组标题提供，多字段分组仍须逐项标注。
- 占位文字仅用于输入提示或示例，填写后字段名称仍须保留。字段内容和名称应支持大字号及换行。
- 密码、API Key、Token 等敏感值继续使用 `SecureField` 遮蔽内容，字段名称照常显示；“显示 key”指显示字段名称。
- 输入控件保留明确的 `accessibilityLabel`，与可见字段名称含义一致。新增或修改表单时检查所有字段是否符合此规范。
