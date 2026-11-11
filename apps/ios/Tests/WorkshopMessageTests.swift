import Foundation

@main struct WorkshopMessageTests {
    static func main() {
        let command = "xkode tasks status 3cbd83c3c89b463098c2ef75065ada82 --details"
        let windows = #"Get-Item "C:\Users\xliqi\Code\hako""#
        let cases: [(String, [WorkshopMessagePart])] = [
            ("查询： `\(command)`", [.text("查询： `\(command)`")]),
            ("`\(windows)`", [.text("`\(windows)`")]),
            ("前文 `first` 和 `second`。", [.text("前文 `first` 和 `second`。")]),
            ("`` echo `tick` ``", [.text("`` echo `tick` ``")]),
            ("`one\ntwo`", [.text("`one\ntwo`")]),
            ("`  `", [.text("`  `")]),
            (#"转义 \`原文\`"#, [.text(#"转义 \`原文\`"#)]),
            ("普通文本与 `未闭合", [.text("普通文本与 `未闭合")]),
            ("```powershell\n\(windows) `\n  -Force\n```", [.code(windows + " `\n  -Force", language: "powershell")]),
            ("```sh\r\necho first\r\necho second\r\n```", [.code("echo first\necho second", language: "sh")]),
            ("````text\n```\ninside\n```\n````", [.code("```\ninside\n```", language: "text")]),
            ("~~~swift\nlet value = 1\n~~~~", [.code("let value = 1", language: "swift")]),
            ("```sh\necho streaming", [.code("echo streaming", language: "sh")]),
            ("```\n  keep spaces  \n\n```\nafter", [.code("  keep spaces  \n", language: nil), .text("after")]),
            ("\n\n", [])
        ]
        for (index, example) in cases.enumerated() {
            precondition(WorkshopMessage.parts(example.0) == example.1, "Message rendering case \(index) failed")
        }
        let summary = """
            已完成替换和推送：

            - Agent 已更新至 `1.0.11`，认证连接、指标采样正常。
            - 全部代码已推送到 `origin/master`，提交 `1a26249`，工作区干净。
            """
        precondition(WorkshopMessage.parts(summary) == [.text(summary)],
            "Inline versions, branches and commits must stay inside their sentences without code cards")
        precondition(WorkshopMessage.parts("版本 `1.0.11`\n```sh\necho ready\n```\n分支 `origin/master`") == [
            .text("版本 `1.0.11`\n"), .code("echo ready", language: "sh"), .text("分支 `origin/master`")
        ], "Only fenced code should interrupt the surrounding paragraphs")
        let reference = "\u{E200}visualize\u{E202}" + #"{"path":"C:/Users/xliqi/Code/hako/docs/prototypes/workshop-swipe-archive.html","mode":"wide"}"# + "\u{E201}"
        precondition(WorkshopMessage.parts("左滑归档。\n\n" + reference) == [.text("左滑归档。\n\n")],
            "Host references must not appear as missing-glyph boxes and JSON in native replies")
        precondition(WorkshopMessage.parts(reference + "\n" + reference).isEmpty)
        precondition(WorkshopMessage.parts("前文" + reference + "后文") == [.text("前文后文")])
        for length in 1...reference.count {
            precondition(WorkshopMessage.parts("正文\n" + reference.prefix(length)) == [.text("正文\n")],
                "Streaming host references must stay hidden, including a partial opening marker")
        }
        precondition(WorkshopMessage.parts("`" + reference + "`") == [.text("`" + reference + "`")],
            "Literal inline code examples must remain inside their paragraph and unchanged")
        precondition(WorkshopMessage.parts("```text\n" + reference + "\n```") == [.code(reference, language: "text")])
        precondition(WorkshopMessage.parts("普通 visualize 文本") == [.text("普通 visualize 文本")])
        print("PASS: inline Markdown paragraphs, versions, branches, commits, fenced snippets and streaming content")
    }
}
