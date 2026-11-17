# 大模型预设与协议

大模型设置提供 OpenAI、Claude、Gemini、DeepSeek、Kimi、MiniMax 的官方接口预设。选择服务商、模型、速度和推理强度后填写 Token 即可保存；配置名称可选，自定义接口仍可手动填写格式、地址和模型 ID。Kimi 和 MiniMax 可选择中国大陆或国际接口。切换凭据接收域名时清空原 Token，Token 只保存在本机钥匙串。

速度与推理选项按模型能力展示，不将各家的参数视为通用参数。没有独立加速档的模型显示标准速度；模型自动控制推理时不发送强度参数。快速档可能额外收费，可用模型和权限由账号决定。DeepSeek V4 Pro 不支持图片，连接测试将图片标记为“不支持”，发送图片前也会提示切换模型。

## 协议与续接

- OpenAI 预设使用 Responses API，支持文本、图片和函数调用。流式响应确认 `response.completed` 后才交付可执行的工具调用；后续请求保留完整输出项、加密推理项和 `call_id`，使用 `store: false`，不依赖服务端保存会话。
- Claude 使用 Messages API，推理强度写入 `output_config.effort`，支持的模型可选择 `speed: fast`。
- Gemini、DeepSeek、Kimi、MiniMax 使用各自的 OpenAI 兼容 Chat Completions 接口。Gemini 工具调用保留 `extra_content` 中的思考签名；工具续接保留服务商返回的思考内容。
- Kimi K3.1 Pro 快速档使用对应的 highspeed 模型 ID；MiniMax M3 使用准入层级选择速度，M3.1 Flash 不发送该参数。MiniMax M3 的思考开关与 Flash 的推理强度分别映射，不发送不支持的组合。
- HTTP 错误读取有界的服务商错误说明并在本机展示，隐藏凭据；请求日志不写错误响应正文、消息内容或 Token。

记账助手与青龙助手共用上述配置、流式解码和工具续接。切换模型、速度或推理强度后开启新对话，避免混用不同模型的上下文。

## 官方能力来源

预设按 2026-11-17 核对的官方文档维护；更新模型时同步更新参数回归测试。

| 服务商 | 模型与参数文档 |
| --- | --- |
| OpenAI | [模型](https://developers.openai.com/api/docs/models)、[函数调用](https://developers.openai.com/api/docs/guides/function-calling)、[快速](https://developers.openai.com/api/docs/guides/fast-mode)、[极速](https://developers.openai.com/api/docs/guides/ultrafast-mode) |
| Claude | [模型](https://platform.claude.com/docs/en/models/overview)、[推理强度](https://platform.claude.com/docs/en/build-with-claude/effort)、[快速模式](https://platform.claude.com/docs/en/build-with-claude/fast-mode) |
| Gemini | [模型](https://aistudio.google.com/docs/models)、[OpenAI 接口](https://aistudio.google.com/docs/openai) |
| DeepSeek | [模型与能力](https://api-docs.deepseek.com/quick_start/pricing/)、[思考模式](https://api-docs.deepseek.com/guides/thinking_mode/) |
| Kimi | [模型](https://platform.kimi.ai/docs/models)、[推理强度](https://platform.kimi.ai/docs/guide/use-reasoning-effort) |
| MiniMax | [国际接口](https://platform.minimax.io/docs/api-reference/text-openai-api)、[中国大陆接口](https://platform.minimax.cn/docs/api-reference/text-openai-api) |

`Tests/LanguageModelPresetAssertions.swift` 与现有记账助手测试共同覆盖参数组合、凭据隔离、Responses 流式完成、加密推理续接、工具调用 ID、Gemini 签名和错误脱敏。iOS CI 同时运行记账助手与青龙助手的协议检查。
