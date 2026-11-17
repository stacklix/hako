import Foundation

@main struct AssistantReplyChoicesTests {
    static func main() throws {
        let question = AssistantHTML("""
            <h2>录入前需要确认资金来源</h2><ol>
            <li><strong>补记一笔转入 39,110.06 CNY</strong><p>转入日期默认 2026-08-17；买入后余额为 543.56。</p></li>
            <li><strong>允许自动补入现金</strong>：仅补足 38,566.50 CNY，买入后余额为 0。</li>
            </ol><p>请回复选择哪种方式。</p>
            """)!
        let options = AssistantReplyChoices(question)
        precondition(options.choices.count == 2)
        precondition(options.choices[0].text.contains("39,110.06 CNY") && options.choices[0].text.contains("2026-08-17"))
        precondition(options.choices[1].reply == "我选择：允许自动补入现金：仅补足 38,566.50 CNY，买入后余额为 0。")
        precondition(options.fragment.contains("hako-choice://select/0") && options.fragment.contains("hako-choice://select/1"))
        precondition(!question.fragment.contains("hako-choice"), "Saved model HTML stays sanitized and inactive")
        let nested = AssistantReplyChoices(AssistantHTML("<p>请选择：</p><ol start='3'><li>账户甲<ul><li>说明甲</li></ul></li><li>账户乙 &amp; 备注</li></ol>")!)
        precondition(nested.choices.count == 2 && nested.choices[1].text == "账户乙 & 备注")
        precondition(nested.fragment.contains("start=\"3\""))
        for html in ["<p>操作步骤</p><ol><li>打开账户</li><li>填写金额</li></ol>",
                     "<p>请选择：</p><ol><li>唯一项</li></ol>",
                     "<p>请选择：</p><pre><ol><li>示例一</li><li>示例二</li></ol></pre>"] {
            precondition(AssistantReplyChoices(AssistantHTML(html)!).choices.isEmpty)
        }
        let malicious = AssistantReplyChoices(AssistantHTML("<p>请选择</p><ol><li><a href='https://evil.test' onclick='bad()'>甲</a></li><li>乙<script>bad()</script></li></ol>")!)
        precondition(!malicious.fragment.contains("evil.test") && !malicious.fragment.contains("bad()"))
        precondition(AssistantReplyChoices.selection(URL(string: "hako-choice://select/1")!) == 1)
        for url in ["https://evil.test/1", "hako-choice://other/1", "hako-choice://select/-1", "hako-choice://select/16",
                    "hako-choice://select/1?write=true", "hako-choice://select/1#x", "hako-choice://user@select/1", "hako-choice://select/"] {
            precondition(AssistantReplyChoices.selection(URL(string: url)!) == nil)
        }
        print("Assistant reply choices: full answers, nested lists, explicit questions and safe navigation passed")
    }
}
