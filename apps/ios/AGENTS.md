# iOS 界面规范

## 重要操作按钮

- 重要的表单提交、确认、创建、保存和流程完成操作，统一使用 `HakoActionButtonStyle()`，外观以组网管理「生成密钥」按钮为准：占满可用宽度、最小高度 44pt、10pt 圆角、15pt 水平内边距、subheadline medium 字重。
- 保存、确认等主操作使用高对比度的实心按钮。浅色模式为深底浅字，深色模式为浅底深字。普通次要按钮使用中性配色，深色模式为深灰底 `#262629` 和浅色文字。按下及禁用时降低透明度。重要操作统一采用上述按钮尺寸和圆角。
- 取消构建任务、删除等危险操作保留 `.destructive` 语义。使用全宽实心按钮时，采用 `HakoActionButtonStyle(destructive: true)`。浅色模式使用浅红底、深红字；深色模式使用暗红底 `#331D22`、浅红字 `#FF9DA8` 和暗红描边 `#62323B`。危险配色优先于主次配色。
- 取消与确认同时出现时，在同一行等宽排列，取消在左、确认在右，间距 12pt。返回或关闭用 `HakoActionButtonStyle(primary: false)`，右侧确认按实际动作选择主样式或危险样式。
- 普通导航栏图标、菜单项和列表入口继续使用原生样式；本规范针对重要操作按钮。新建或修改相关页面时遵守，不要求无关页面整体重做。

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

## 列表分隔线

- Form / List 分组内的行分隔线必须完整对齐整行内容区两端，不能从右侧状态文字、标签或图标处开始。
- 自定义行（尤其是包含 HStack、Spacer、Label、配置状态的 NavigationLink）须在整行视图上显式设置 `.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }` 和 `.alignmentGuide(.listRowSeparatorTrailing) { $0.width }`，并占满可用宽度；不要只给内部文字设置。
- 同一分组统一行内边距。已采用零行内边距、内容自行 padding 的通栏分隔线行继续保持通栏。
