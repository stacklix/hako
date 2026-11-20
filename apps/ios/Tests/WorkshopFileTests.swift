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
        let file = try JSONDecoder().decode(WorkshopProjectFile.self, from: Data("""
        {"name":"old.swift","path":"src/old.swift","directory":false,"link":false,"size":0,"status":" D"}
        """.utf8))
        precondition(file.deleted && file.statusLabel == "删除")
        print("Workshop file models and text encoding checks passed")
    }
}
