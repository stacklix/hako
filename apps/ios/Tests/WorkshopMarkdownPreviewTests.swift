import Foundation

@main struct WorkshopMarkdownPreviewTests {
    static func main() {
        precondition(WorkshopMarkdownDocument.supports("docs/README.MD"))
        precondition(WorkshopMarkdownDocument.supports("notes.markdown"))
        precondition(!WorkshopMarkdownDocument.supports("notes.md.txt"))
        let draft = """
        # 未保存的标题

        - **加粗**与 `code`

        > 引用

        | 名称 | 数量 |
        | --- | ---: |
        | 草稿 | 2 |

        ```html
        <script>alert("code")</script>&value
        ```

        <script>alert("raw")</script>
        ![图片](https://example.com/private.png)
        """
        let html = WorkshopMarkdownDocument.build(draft)
        for expected in ["<h2>未保存的标题</h2>", "<ul>", "<strong>加粗</strong>", "<blockquote>", "<table>",
                         "text-align:right", "&lt;script&gt;alert(\"code\")&lt;/script&gt;&amp;value", "color-scheme: light dark"] {
            precondition(html.contains(expected), "Missing rendered Markdown: \(expected)")
        }
        precondition(!html.contains("<script>") && !html.contains("<img") && !html.contains("<iframe"))
        precondition(!html.contains("https://example.com/private.png"))
        precondition(html.contains("default-src 'none'") && html.contains("图片：图片"))
        // Cover files above the assistant reply renderer's 128 KB limit.
        let large = WorkshopMarkdownDocument.build(String(repeating: "正文\n\n", count: 20_000) + "文件末尾")
        precondition(large.contains("文件末尾"))
        precondition(WorkshopMarkdownDocument.build("").contains("<main></main>"))
        print("PASS: Markdown file detection, draft rendering, headings/lists/tables/code, escaped HTML, offline images, empty and large files")
    }
}
