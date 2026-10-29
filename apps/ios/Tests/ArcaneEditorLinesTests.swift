import Foundation

@main struct ArcaneEditorLinesTests {
    static func main() {
        precondition(ArcaneEditorLines("").starts == [0])
        precondition(ArcaneEditorLines("long wrapped line without newline").starts == [0])
        precondition(ArcaneEditorLines("a\nb").starts == [0, 2])
        precondition(ArcaneEditorLines("a\n\n").starts == [0, 2, 3])
        precondition(ArcaneEditorLines("a\r\nb\rc\n").starts == [0, 3, 5, 7])
        precondition(ArcaneEditorLines("a\u{2028}b\u{2029}").starts == [0, 2, 4])
        let unicode = ArcaneEditorLines("😀中文\r\ne\u{301}\nend")
        precondition(unicode.starts == [0, 6, 9])
        for offset in 0..<6 { precondition(unicode.index(containingUTF16Offset: offset) == 0) }
        for offset in 6..<9 { precondition(unicode.index(containingUTF16Offset: offset) == 1) }
        for offset in 9...12 { precondition(unicode.index(containingUTF16Offset: offset) == 2) }
        let many = ArcaneEditorLines(String(repeating: "\n", count: 1000))
        precondition(many.starts.count == 1001 && many.index(containingUTF16Offset: 1000) == 1000)
        print("PASS: logical editor lines, empty/trailing lines, mixed newlines, UTF-16 and line lookup")
    }
}
