import Foundation

struct InvestmentAgentHTML: Codable {
    static let tags = ["section", "h2", "h3", "h4", "p", "strong", "em", "small", "code", "pre", "blockquote",
                       "ul", "ol", "li", "dl", "dt", "dd", "table", "caption", "thead", "tbody", "tfoot",
                       "tr", "th", "td", "br", "hr"]
    private static let allowed = Set(tags)
    private static let voidTags: Set<String> = ["br", "hr"]
    private static let hiddenContent: Set<String> = ["head", "script", "style", "iframe", "object", "svg", "math",
                                                      "template", "noscript", "textarea", "select"]
    private static let tokens = try! NSRegularExpression(pattern:
        #"(?s)<!--.*?(?:-->|$)|</?([A-Za-z][A-Za-z0-9:-]*)(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>|<![^<>]*>|<\?[^<>]*\?>"#)

    let fragment: String

    init?(_ response: String) {
        guard response.utf8.count <= 128_000 else { return nil }
        let source = Self.unwrap(response)
        var cursor = source.startIndex
        var output = ""
        var hidden: [String] = []
        var hasText = false

        func appendText(_ text: Substring) {
            if !hasText { hasText = text.contains { !$0.isWhitespace } }
            // Character references in HTML text stay text. Only generated tags can enter the document as markup.
            output += text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
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
                // Rebuild the tag without attributes so links, styles and event handlers cannot survive.
                output += closing ? "</\(name)>" : "<\(name)>"
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
