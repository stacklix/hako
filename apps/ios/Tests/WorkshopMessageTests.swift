import Foundation

@main struct WorkshopMessageTests {
    static func main() {
        let command = "xkode tasks status 3cbd83c3c89b463098c2ef75065ada82 --details"
        let windows = #"Get-Item "C:\Users\xliqi\Code\hako""#
        let cases: [(String, [WorkshopMessagePart])] = [
            ("查询： `\(command)`", [.text("查询： "), .code(command, language: nil)]),
            ("`\(windows)`", [.code(windows, language: nil)]),
            ("前文 `first` 和 `second`。", [.text("前文 "), .code("first", language: nil), .text(" 和 "), .code("second", language: nil), .text("。")]),
            ("`` echo `tick` ``", [.code("echo `tick`", language: nil)]),
            ("`one\ntwo`", [.code("one two", language: nil)]),
            ("`  `", [.code("  ", language: nil)]),
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
        let reference = "\u{E200}visualize\u{E202}" + #"{"path":"C:/Users/xliqi/Code/hako/docs/prototypes/workshop-swipe-archive.html","mode":"wide"}"# + "\u{E201}"
        precondition(WorkshopMessage.parts("左滑归档。\n\n" + reference) == [.text("左滑归档。\n\n")],
            "Host references must not appear as missing-glyph boxes and JSON in native replies")
        precondition(WorkshopMessage.parts(reference + "\n" + reference).isEmpty)
        precondition(WorkshopMessage.parts("前文" + reference + "后文") == [.text("前文后文")])
        for length in 1...reference.count {
            precondition(WorkshopMessage.parts("正文\n" + reference.prefix(length)) == [.text("正文\n")],
                "Streaming host references must stay hidden, including a partial opening marker")
        }
        precondition(WorkshopMessage.parts("`" + reference + "`") == [.code(reference, language: nil)],
            "Literal code examples must remain copyable and unchanged")
        precondition(WorkshopMessage.parts("```text\n" + reference + "\n```") == [.code(reference, language: "text")])
        precondition(WorkshopMessage.parts("普通 visualize 文本") == [.text("普通 visualize 文本")])
        print("PASS: copyable commands, Windows paths, inline delimiters, escaped text, fenced code and streaming content")
    }
}
