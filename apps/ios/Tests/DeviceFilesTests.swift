import Foundation

@main enum DeviceFilesTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
        check(DeviceFilePath.fullPath(root: "C:\\Users\\test", path: "Magnus/key.properties") == "C:\\Users\\test\\Magnus\\key.properties", "Copy must include the complete Windows path")
        check(DeviceFilePath.fullPath(root: "C:\\", path: "工作 文件/笔记.md") == "C:\\工作 文件\\笔记.md", "Copy must preserve Unicode and avoid duplicate separators")
        check(DeviceFilePath.fullPath(root: "\\\\server\\share", path: "folder") == "\\\\server\\share\\folder", "Copy must preserve UNC roots")
        for path in ["", "Documents", "Documents/工作笔记.md", ".config/settings.json"] { check(DeviceFilePath.valid(path), "Rejected valid path: \(path)") }
        for path in ["../outside", "/Windows", "C:/Windows", "a//b", "a/./b", "notes.md:stream", "folder\\file", "CON", "nul.txt", "COM¹.log", "CONIN$", "trailing."] {
            check(!DeviceFilePath.valid(path), "Accepted invalid path: \(path)")
        }
        for encoding in ["utf8", "utf8-bom", "utf16-le", "utf16-be"] {
            let text = "# 你好\r\n\n- 第一项\n👋"
            let bytes = DeviceFileDocument.encode(text, encoding: encoding)!
            check(DeviceFileDocument.decode(bytes, encoding: encoding) == text, "Encoding roundtrip changed text or line endings")
            check(DeviceFileDocument.decode(DeviceFileDocument.encode("", encoding: encoding)!, encoding: encoding) == "", "Empty file encoding failed")
        }
        check(DeviceFileDocument.decode(Data([0xff]), encoding: "utf8") == nil, "Malformed UTF-8 accepted")
        check(DeviceFileDocument.decode(Data("plain".utf8), encoding: "utf8-bom") == nil, "Missing BOM accepted")
        let revision = String(repeating: "a", count: 64)
        let entry = DeviceFileEntry(name: "笔记.MD", path: "Documents/笔记.MD", directory: false, link: false, hidden: false, readOnly: false, size: 12, modifiedAt: 1, revision: revision)
        check(entry.isValid && entry.isMarkdown, "Markdown or entry validation failed")
        let page = DeviceFilePage(root: "C:\\Users\\test", path: "Documents", entries: [entry], nextOffset: 1, truncated: false)
        check(page.valid(expectedPath: "Documents", offset: 0), "Valid page rejected")
        check(!page.valid(expectedPath: "elsewhere", offset: 0), "Wrong directory response accepted")
        check(!DeviceFilePage(root: "home", path: "Documents", entries: [entry, entry], nextOffset: nil, truncated: false).valid(expectedPath: "Documents", offset: 0), "Duplicate entries accepted")
        check(!DeviceFilePage(root: "home", path: "Documents", entries: [entry], nextOffset: 0, truncated: false).valid(expectedPath: "Documents", offset: 0), "Nonadvancing pagination accepted")
        let id = UUID().uuidString
        check(DeviceFileOperation(requestId: id, state: "unknown", path: "", revision: nil, error: nil).isValid, "Unknown operation state rejected")
        check(!DeviceFileOperation(requestId: id, state: "success", path: "", revision: nil, error: nil).isValid, "Invented operation state accepted")
        check(!DeviceFileOperation(requestId: id, state: "completed", path: "../escape", revision: nil, error: nil).isValid, "Operation path escaped root")
        print("PASS: user file path boundaries, response validation, pagination, Markdown names, UTF-8/UTF-16 BOM and line endings.")
    }
}
