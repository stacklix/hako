import Foundation

struct AssistantHTML: Codable {
    static let tags = ["section", "h2", "h3", "h4", "p", "strong", "em", "small", "code", "pre", "blockquote",
                       "ul", "ol", "li", "dl", "dt", "dd", "table", "caption", "thead", "tbody", "tfoot",
                       "tr", "th", "td", "br", "hr"]
    private static let allowed = Set(tags)
    private static let voidTags: Set<String> = ["br", "hr"]
    private static let hiddenContent: Set<String> = ["head", "script", "style", "iframe", "object", "svg", "math",
                                                      "template", "noscript", "textarea", "select"]
    private static let tokens = try! NSRegularExpression(pattern:
        #"(?s)<!--.*?(?:-->|$)|</?([A-Za-z][A-Za-z0-9:-]*)(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>|<![^<>]*>|<\?[^<>]*\?>"#)
    private static let listNumber = try! NSRegularExpression(pattern: #"(?i)\bstart\s*=\s*["']?([0-9]{1,9})(?=["'\s>])"#)

    private static func listStart(_ tag: String) -> Int {
        guard let match = listNumber.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return 1 }
        return Int(tag[range]) ?? 1
    }

    let fragment: String

    static let formattingInstructions = "段落用 p，加粗用 strong，编号列表用 ol/li，无序列表用 ul/li；不要混用 **、井号标题或纯文本列表来代替 HTML 标签。"

    // Render changing text natively until the final sanitized HTML layout is available.
    static func streamingText(_ response: String) -> String {
        var source = response
        if let opening = source.lastIndex(of: "<"), !source[opening...].contains(">") {
            source = String(source[..<opening])
        }
        guard let html = Self(source) else { return "" }
        var text = "", cursor = html.fragment.startIndex
        var lists: [Int?] = []
        func newline() { if !text.hasSuffix("\n") { text += "\n" } }
        for token in Self.tokens.matches(in: html.fragment, range: NSRange(html.fragment.startIndex..<html.fragment.endIndex, in: html.fragment)) {
            guard let range = Range(token.range, in: html.fragment), let nameRange = Range(token.range(at: 1), in: html.fragment) else { continue }
            text += html.fragment[cursor..<range.lowerBound]; cursor = range.upperBound
            let name = String(html.fragment[nameRange]), closing = html.fragment[range].hasPrefix("</")
            if name == "ol" || name == "ul" {
                if closing { if !lists.isEmpty { lists.removeLast() } }
                else { lists.append(name == "ol" ? listStart(String(html.fragment[range])) : nil) }
            }
            if name == "li", !closing {
                newline()
                text += String(repeating: "  ", count: max(0, lists.count - 1))
                if let number = lists.last ?? nil {
                    text += "\(number). "; lists[lists.count - 1] = number + 1
                } else { text += "• " }
            }
            if closing && ["p", "h2", "h3", "h4", "li", "dt", "dd", "tr", "section", "pre", "blockquote"].contains(name)
                || ["br", "hr"].contains(name) { newline() }
        }
        text += html.fragment[cursor...]
        let entities = try! NSRegularExpression(pattern: #"&(?:#([0-9]+)|#x([0-9a-fA-F]+)|(amp|lt|gt|quot|apos|nbsp));"#)
        for match in entities.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let replacement: String?
            if let number = Range(match.range(at: 1), in: text) {
                replacement = UInt32(text[number]).flatMap(UnicodeScalar.init).map(String.init)
            } else if let number = Range(match.range(at: 2), in: text) {
                replacement = UInt32(text[number], radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if let name = Range(match.range(at: 3), in: text) {
                replacement = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][String(text[name])]
            } else { replacement = nil }
            if let replacement { text.replaceSubrange(range, with: replacement) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(_ response: String) {
        guard response.utf8.count <= 128_000 else { return nil }
        let unwrapped = Self.unwrap(response)
        let hasHTML = !unwrapped.hasPrefix("```") && Self.tokens.matches(in: unwrapped, range: NSRange(unwrapped.startIndex..<unwrapped.endIndex, in: unwrapped)).contains { token in
            guard let name = Range(token.range(at: 1), in: unwrapped) else { return false }
            return Self.allowed.contains(unwrapped[name].lowercased()) || Self.hiddenContent.contains(unwrapped[name].lowercased())
        }
        let source = hasHTML ? unwrapped : AssistantMarkdown.render(unwrapped)
        var cursor = source.startIndex
        var output = ""
        var hidden: [String] = []
        var hasText = false
        var verbatimDepth = 0

        func appendText(_ text: Substring) {
            if !hasText { hasText = text.contains { !$0.isWhitespace } }
            // Character references in HTML text stay text. Only generated tags can enter the document as markup.
            if hasHTML && verbatimDepth == 0 { output += AssistantMarkdown.inline(String(text)) }
            else { output += text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        }

        for token in Self.tokens.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
            guard let range = Range(token.range, in: source) else { continue }
            if hidden.isEmpty { appendText(source[cursor..<range.lowerBound]) }
            cursor = range.upperBound
            guard let nameRange = Range(token.range(at: 1), in: source) else { continue }
            let name = source[nameRange].lowercased()
            let closing = source[range].hasPrefix("</")
            let selfClosing = source[range].hasSuffix("/>")
            if let active = hidden.last {
                if closing, name == active { hidden.removeLast() }
                else if active != "script", active != "style", Self.hiddenContent.contains(name), !closing, !selfClosing {
                    hidden.append(name)
                }
            } else if Self.hiddenContent.contains(name), !closing, !selfClosing {
                hidden.append(name)
            } else if Self.allowed.contains(name), !closing || !Self.voidTags.contains(name) {
                // Only a numeric list counter is retained; links, styles and event handlers cannot survive.
                let start = name == "ol" && !closing ? Self.listStart(String(source[range])) : 1
                output += closing ? "</\(name)>" : "<\(name)" + (start == 1 ? "" : " start=\"\(start)\"") + ">"
                if name == "pre" || name == "code" { verbatimDepth = max(0, verbatimDepth + (closing ? -1 : 1)) }
            }
        }
        if hidden.isEmpty { appendText(source[cursor...]) }
        guard hasText, output.utf8.count <= 128_000 else { return nil }
        fragment = output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let html = Self(try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid investment assistant HTML")
        }
        self = html
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(fragment)
    }

    private static func unwrap(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = trimmed.firstIndex(where: \.isNewline), trimmed.hasSuffix("```"),
           ["```html", "```"].contains(trimmed[..<newline].lowercased()) {
            let body = trimmed[trimmed.index(after: newline)...].dropLast(3)
            if body.last?.isNewline == true { return String(body.dropLast()) }
        }
        return trimmed
    }
}
