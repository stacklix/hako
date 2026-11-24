# Webhook 管理

iOS 主应用「设置 → Hako 服务 → Webhook 管理」使用当前 Sora Console 登录会话管理通知中心的 Webhook。

列表显示名称、允许渠道和启用状态。点击名称编辑，右上角创建；更多菜单提供编辑、启停、重置 Token 和删除。停用、重置和删除需确认。表单默认只显示名称与通知渠道，每分钟上限和过期时间收在「更多选项」中，修改沿用共享 Sheet 的未保存保护。微信绑定继续在 Sora 网页通知中心完成。

完整地址只在创建或重置后展示，不写入本地设置、日志或列表缓存。复制仅使用本机剪贴板并在两分钟后过期。关闭地址页面或进入后台后，需要重置 Token 才能重新取得完整地址。切换服务器、退出或切换登录会话后，清除旧会话的页面与地址。

网络错误后不自动重试写操作，避免重复创建或重复重置；先刷新列表核对实际结果。

## 原生接口

需要 Sora 0.8.19 或更高的 0.8.x 版本。所有接口使用可信 Console 会话、DPoP 签名和设备绑定，不接受管理 Cookie 或第三方应用令牌。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET / POST | `/api/v1/notifications/manage/webhooks` | 列出、创建 |
| GET / PATCH / DELETE | `/api/v1/notifications/manage/webhooks/{id}` | 查看、修改、删除 |
| POST | `/api/v1/notifications/manage/webhooks/{id}/rotate-token` | 重置 Token |
| GET | `/api/v1/notifications/manage/channels/wechat` | 读取微信绑定供表单选择 |

接口复用通知服务的校验和存储，仅开放 Webhook 配置与微信绑定查询。原生入口不提供发送测试、调用记录、推送私钥或微信生命周期管理。

测试覆盖原生认证边界、服务未启用、Webhook 生命周期、禁用地址拒绝发送、重置和删除使旧地址失效，以及客户端渠道、频率、过期时间和地址约束。
