import Foundation

@main
struct AssistantRenderingTests {
    static func main() throws {
        let screenshotReply = """
        抱歉，这里需要向你说明清楚：

        1. **表单确实缺成交价**：开空流水的“成交价”是必填项。
        2. **我后面的处理**：截图中的开仓均价为 0.319505，使用前应说明取值依据。
        3. **当前状态**：请在应用中核对预览与确认结果。

        标的 `TRXUSD•S•HTX`，数量 36,087.2 TRX，保证金 7,217.4 TRX。
        如需更正，请继续补充。
        """
        let html = AssistantHTML(screenshotReply)!.fragment
        precondition(html.components(separatedBy: "<li>").count == 4 && html.contains("<ol>"))
        precondition(html.contains("<strong>表单确实缺成交价</strong>") && !html.contains("**"))
        precondition(html.contains("<code>TRXUSD•S•HTX</code>") && html.contains("<br>如需更正"))
        let text = AssistantHTML.streamingText(screenshotReply)
        precondition(text.contains("1. 表单确实缺成交价") && text.contains("\n2. 我后面的处理") && text.contains("\n3. 当前状态"))
        precondition(!text.contains("**") && text.contains("36,087.2 TRX"))

        let nested = AssistantHTML("## 说明\n\n- **账户**\n  - 已核对\n- *标的*\n\n> 请核对。")!.fragment
        precondition(nested.contains("<h2>说明</h2>") && nested.contains("<ul><li><p><strong>账户</strong></p>\n<ul>"))
        precondition(nested.contains("<em>标的</em>") && nested.contains("<blockquote><p>请核对。</p></blockquote>"))
        precondition(AssistantHTML.streamingText("5. 第五项\n6. 第六项") == "5. 第五项\n6. 第六项")
        precondition(AssistantHTML("<ol start='5' onclick='bad()'><li>内容</li></ol>")?.fragment == "<ol start=\"5\"><li>内容</li></ol>")

        let code = AssistantHTML("```swift\nlet x = \"**raw** <script>attack()</script>\"\nlet task_name = \"a&b\"\n```")!.fragment
        precondition(code.hasPrefix("<pre><code>") && !code.contains("<strong>") && !code.contains("<script>"))
        precondition(AssistantHTML.streamingText(code).contains("**raw** <script>attack()</script>"))
        let mixed = AssistantHTML("<p>**强调**与 `task_name`</p><pre>**原样代码**</pre>")!.fragment
        precondition(mixed.contains("<strong>强调</strong>") && mixed.contains("<pre>**原样代码**</pre>"))
        let escaped = AssistantHTML(#"\*不是斜体\*，a_b_c 与 **加粗**。"#)!.fragment
        precondition(!escaped.contains("<em>") && escaped.contains("<strong>加粗</strong>"))
        let links = AssistantHTML("[资料](https://example.test) ![图片](https://example.test/a.png)")!.fragment
        precondition(!links.contains("https://") && !links.contains("<a") && !links.contains("<img"))
        precondition(AssistantHTML("<script>attack()</script><p> </p>") == nil)
        precondition(AssistantHTML("<p onclick='bad()'>安全</p><img src='https://example.test'>")?.fragment == "<p>安全</p>")
        precondition(AssistantHTML(String(repeating: "a", count: 128_001)) == nil)
        for fragment in [html, nested, code, mixed, escaped, links] {
            precondition(AssistantHTML(fragment)?.fragment == fragment, "Formatting must be stable after saving and reopening")
            let saved = try PropertyListEncoder().encode([AssistantHTML(fragment)!])
            let restored = try PropertyListDecoder().decode([AssistantHTML].self, from: saved)
            precondition(restored.first?.fragment == fragment)
        }
        if CommandLine.arguments.count == 2 {
            try html.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print("Assistant rendering tests passed")
    }
}
