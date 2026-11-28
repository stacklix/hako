import Foundation

@main struct WorkshopFileTests {
    static func main() throws {
        let source = "你好 👋\r\nlet value = \"test\"\r\n"
        for name in ["utf8", "utf8-bom", "utf16-le", "utf16-be"] {
            let bytes = WorkshopFileText.encode(source, encoding: name)!
            precondition(WorkshopFileText.decode(bytes, encoding: name) == source, "Text encoding/newline round trip failed: \(name)")
            precondition(WorkshopFileText.encode("", encoding: name) != nil)
        }
        precondition(WorkshopFileText.decode(Data([0xff]), encoding: "utf8") == nil)
        precondition(WorkshopFileScope.allCases == [.all, .modified])
        for path in ["image.PNG", "work/screen.jpg", "preview.jpeg", "animation.gif", "picture.webp"] {
            precondition(WorkshopProjectImage.supports(path))
        }
        for path in ["report.json", "page.html", "drawing.svg", "image.png.exe"] { precondition(!WorkshopProjectImage.supports(path)) }
        let file = try JSONDecoder().decode(WorkshopProjectFile.self, from: Data("""
        {"name":"old.swift","path":"src/old.swift","directory":false,"link":false,"size":0,"status":" D"}
        """.utf8))
        precondition(file.deleted && file.statusLabel == "删除")
        let root = #"C:\Users\xliqi\Code\xkode"#
        let report = ".xkode/cleanup-audit/20261127-cache-causes.json"
        for address in ["/C:/Users/xliqi/Code/xkode/" + report,
                        "C:/Users/xliqi/Code/xkode/" + report,
                        "file:///C:/Users/xliqi/Code/xkode/" + report,
                        report, "./" + report,
                        "file:///c:/users/xliqi/code/XKODE/" + report] {
            let target = WorkshopProjectLink(url: URL(string: address)!, projectPath: root)
            precondition(target?.path == report && target?.file.name == "20261127-cache-causes.json",
                         "Project report links must read from the execution computer: \(address)")
        }
        precondition(WorkshopProjectLink(url: URL(string: "docs/read%20me.md#L12")!, projectPath: root)?.path == "docs/read me.md")
        precondition(WorkshopProjectLink(url: URL(string: "/C:/Users/xliqi/Code/xkode/src/main.swift:12:3")!, projectPath: root)?.path == "src/main.swift")
        precondition(WorkshopProjectLink(url: URL(string: "/home/me/project/docs/report.md")!, projectPath: "/home/me/project")?.path == "docs/report.md")
        for address in ["../private.json", "/C:/Users/xliqi/Code/xkode-other/report.json", "/C:/Users/xliqi/Magnus/key.properties",
                        "file://other-host/private.json", "https://example.com/report.json", "javascript:alert(1)",
                        "data:text/plain,hello", ".git/config", "docs/../../private.json", "%2e%2e/private.json"] {
            precondition(WorkshopProjectLink(url: URL(string: address)!, projectPath: root) == nil,
                         "Only files within the selected project may be routed to files.read: \(address)")
        }
        precondition(WorkshopProjectLink(url: URL(string: "docs/report.json")!, projectPath: "") == nil)
        print("Workshop file models and text encoding checks passed")
    }
}
