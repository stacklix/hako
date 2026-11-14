import Foundation

/// Converts reply paragraphs, lists and inline formatting into the same restricted
/// HTML used by both assistants. It never creates links, images or attributes.
enum AssistantMarkdown {
    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#)
    private static let item = try! NSRegularExpression(pattern: #"^( {0,3})([-+*]|[0-9]{1,9}[.)])\s+(.+)$"#)
    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}(?:\*\s*){3,}$|^ {0,3}(?:-\s*){3,}$|^ {0,3}(?:_\s*){3,}$"#)

    static func render(_ source: String) -> String {
        blocks(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n"), depth: 0)
    }

    private static func groups(_ expression: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    private static func blocks(_ lines: [String], depth: Int) -> String {
        guard depth < 16 else { return "<p>" + lines.map { literal($0) }.joined(separator: "<br>") + "</p>" }
        var result: [String] = [], paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { result.append("<p>" + paragraph.map { inline($0) }.joined(separator: "<br>") + "</p>"); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let opening = groups(fence, line) {
                flush(); index += 1
                var code: [String] = []
                while index < lines.count {
                    if let closing = groups(fence, lines[index]), closing[1].first == opening[1].first,
                       closing[1].count >= opening[1].count, closing[2].trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1; break
                    }
                    code.append(lines[index]); index += 1
                }
                result.append("<pre><code>" + literal(code.joined(separator: "\n"), code: true) + "</code></pre>")
            } else if let title = groups(heading, line) {
                flush(); let level = min(4, max(2, title[1].count))
                result.append("<h\(level)>" + inline(title[2]) + "</h\(level)>"); index += 1
            } else if groups(rule, line) != nil {
                flush(); result.append("<hr>"); index += 1
            } else if trimmed.hasPrefix(">") {
                flush(); var quote: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    quote.append(String(value.dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                result.append("<blockquote>" + blocks(quote, depth: depth + 1) + "</blockquote>")
            } else if let first = groups(item, line) {
                flush()
                let ordered = first[2].first?.isNumber == true
                let tag = ordered ? "ol" : "ul"
                var items: [String] = []
                while index < lines.count, let current = groups(item, lines[index]),
                      current[1].count == first[1].count, (current[2].first?.isNumber == true) == ordered {
                    let indent = lines[index].count - current[3].count
                    var content = [current[3]]
                    index += 1
                    while index < lines.count {
                        let next = lines[index]
                        if let marker = groups(item, next), marker[1].count == first[1].count { break }
                        if next.trimmingCharacters(in: .whitespaces).isEmpty {
                            // A blank line belongs to the item only if more indented content follows.
                            guard index + 1 < lines.count, lines[index + 1].prefix(while: { $0 == " " }).count >= indent else { break }
                            content.append(""); index += 1; continue
                        }
                        let spaces = next.prefix(while: { $0 == " " }).count
                        guard spaces >= indent else { break }
                        content.append(String(next.dropFirst(indent))); index += 1
                    }
                    items.append("<li>" + blocks(content, depth: depth + 1) + "</li>")
                    // Permit spacing between consecutive items without swallowing a following paragraph.
                    if index + 1 < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                       let next = groups(item, lines[index + 1]), next[1].count == first[1].count,
                       (next[2].first?.isNumber == true) == ordered { index += 1 }
                }
                let start = ordered ? Int(first[2].dropLast()) ?? 1 : 1
                result.append("<\(tag)" + (start == 1 ? "" : " start=\"\(start)\"") + ">" + items.joined() + "</\(tag)>")
            } else {
                paragraph.append(line); index += 1
            }
        }
        flush()
        return result.joined(separator: "\n")
    }

    static func inline(_ text: String, depth: Int = 0) -> String {
        guard depth < 16 else { return literal(text) }
        var output = "", index = text.startIndex
        while index < text.endIndex {
            let char = text[index], next = text.index(after: index)
            if char == "\\", next < text.endIndex, #"\`*_{}[]()#+-.!>"#.contains(text[next]) {
                output += literal(String(text[next])); index = text.index(after: next); continue
            }
            if char == "`" {
                let ticks = String(text[index...].prefix(while: { $0 == "`" }))
                let start = text.index(index, offsetBy: ticks.count)
                if let end = text.range(of: ticks, range: start..<text.endIndex) {
                    let code = String(text[start..<end.lowerBound]).replacingOccurrences(of: "\n", with: " ")
                    output += "<code>" + literal(code, code: true) + "</code>"; index = end.upperBound; continue
                }
            }
            var formatted = false
            for (marker, open, close) in [("***", "<strong><em>", "</em></strong>"), ("**", "<strong>", "</strong>"),
                                           ("__", "<strong>", "</strong>"), ("*", "<em>", "</em>"), ("_", "<em>", "</em>")] {
                guard text[index...].hasPrefix(marker) else { continue }
                if marker.first == "_", index > text.startIndex, text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber { continue }
                let start = text.index(index, offsetBy: marker.count)
                guard start < text.endIndex, !text[start].isWhitespace,
                      let end = text.range(of: marker, range: start..<text.endIndex), end.lowerBound > start,
                      !text[text.index(before: end.lowerBound)].isWhitespace else { continue }
                output += open + inline(String(text[start..<end.lowerBound]), depth: depth + 1) + close
                index = end.upperBound; formatted = true; break
            }
            if formatted { continue }
            if char == "[" || char == "!" && next < text.endIndex && text[next] == "[" {
                let start = char == "[" ? next : text.index(after: next)
                if let end = text.range(of: "](", range: start..<text.endIndex),
                   let close = text[end.upperBound...].firstIndex(of: ")") {
                    output += inline(String(text[start..<end.lowerBound]), depth: depth + 1)
                    index = text.index(after: close); continue
                }
            }
            output += literal(String(char)); index = next
        }
        return output
    }

    private static func literal(_ text: String, code: Bool = false) -> String {
        let value = code ? text.replacingOccurrences(of: "&", with: "&amp;") : text
        return value.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "*", with: "&#42;").replacingOccurrences(of: "_", with: "&#95;")
    }
}
