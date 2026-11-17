import Foundation

/// Turns explicit clarification lists into app-owned reply links after HTML sanitization.
struct AssistantReplyChoices {
    struct Choice: Identifiable, Equatable {
        let id: Int
        let text: String
        var reply: String { "我选择：" + text }
    }
    let choices: [Choice]
    let fragment: String

    init(_ html: AssistantHTML) {
        let source = html.fragment
        let plain = AssistantHTML.streamingText(source)
        let cues = ["请选择", "请回复", "选择哪", "选哪", "选择一种", "选择一项", "选一项", "选一种", "哪种方式", "可选方案"]
        guard cues.contains(where: plain.contains) else { choices = []; fragment = source; return }
        let tags = try! NSRegularExpression(pattern: #"</?([a-z][a-z0-9]*)\b[^>]*>"#)
        var depth = 0, verbatim = 0
        var start: String.Index?
        var group: [Range<String.Index>] = []
        var groups: [[Range<String.Index>]] = []
        for token in tags.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
            guard let range = Range(token.range, in: source), let nameRange = Range(token.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange]), closing = source[range].hasPrefix("</")
            if name == "pre" || name == "code" { verbatim = max(0, verbatim + (closing ? -1 : 1)); continue }
            guard verbatim == 0 else { continue }
            if name == "ol" || name == "ul" {
                if closing {
                    if depth == 1, (2...8).contains(group.count) { groups.append(group) }
                    depth = max(0, depth - 1)
                } else {
                    if depth == 0 { group = []; start = nil }
                    depth += 1
                }
            } else if name == "li", depth == 1 {
                if closing {
                    if let start { group.append(start..<range.lowerBound) }
                    start = nil
                } else { start = range.upperBound }
            }
        }
        let ranges = groups.flatMap { $0 }
        guard !ranges.isEmpty, ranges.count <= 16 else { choices = []; fragment = source; return }
        let values = ranges.enumerated().map { Choice(id: $0.offset, text: AssistantHTML.streamingText(String(source[$0.element]))) }
        guard values.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 2_000 }) else { choices = []; fragment = source; return }
        var interactive = source
        for (index, range) in ranges.enumerated().reversed() {
            interactive.replaceSubrange(range, with: "<a href=\"hako-choice://select/\(index)\">" + source[range] + "</a>")
        }
        choices = values
        fragment = interactive
    }

    static func selection(_ url: URL) -> Int? {
        guard url.scheme == "hako-choice", url.host == "select", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path
        guard path.hasPrefix("/"), path.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
              let index = Int(path.dropFirst()), index >= 0, index < 16 else { return nil }
        return index
    }
}
