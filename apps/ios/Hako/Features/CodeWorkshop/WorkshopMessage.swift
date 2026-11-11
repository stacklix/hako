import Foundation

enum WorkshopMessagePart: Equatable {
    case text(String)
    case code(String, language: String?)
}

enum WorkshopMessage {
    private struct Fence {
        let marker: Character
        let count: Int
        let language: String?
    }

    static func parts(_ source: String) -> [WorkshopMessagePart] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [WorkshopMessagePart] = []
        var prose = ""
        var code = ""
        var fence: Fence?
        for (index, line) in lines.enumerated() {
            if let current = fence {
                if closes(line, fence: current) {
                    if code.hasSuffix("\n") { code.removeLast() }
                    result.append(.code(code, language: current.language))
                    code = ""
                    fence = nil
                } else {
                    code += line + (index < lines.count - 1 ? "\n" : "")
                }
            } else if let opening = opening(line) {
                result += inlineParts(prose)
                prose = ""
                fence = opening
            } else {
                prose += line + (index < lines.count - 1 ? "\n" : "")
            }
        }
        if let fence { result.append(.code(code, language: fence.language)) }
        result += inlineParts(prose)
        return result
    }

    private static func opening(_ line: String) -> Fence? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let content = line.dropFirst(indent)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let info = content.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, count: count, language: info.split(whereSeparator: \.isWhitespace).first.map(String.init))
    }

    private static func closes(_ line: String, fence: Fence) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let content = line.dropFirst(indent)
        let count = content.prefix { $0 == fence.marker }.count
        return count >= fence.count && content.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func inlineParts(_ source: String) -> [WorkshopMessagePart] {
        var result: [WorkshopMessagePart] = []
        var prose = ""
        var cursor = source.startIndex
        func flush() {
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(prose)) }
            prose = ""
        }
        while cursor < source.endIndex {
            // The native prototype card renders this host control reference.
            // Keep the original transcript intact for artifact discovery, and
            // hide incomplete references while their text is still streaming.
            if source[cursor] == "\u{E200}" {
                let marker = "\u{E200}visualize\u{E202}"
                let remaining = source[cursor...]
                if remaining.hasPrefix(marker) {
                    let payload = source.index(cursor, offsetBy: marker.count)
                    cursor = source[payload...].firstIndex(of: "\u{E201}").map { source.index(after: $0) } ?? source.endIndex
                    continue
                }
                if marker.hasPrefix(remaining) { break }
            }
            guard source[cursor] == "`", !escaped(cursor, in: source) else {
                prose.append(source[cursor])
                cursor = source.index(after: cursor)
                continue
            }
            let end = delimiterEnd(cursor, in: source)
            let count = source.distance(from: cursor, to: end)
            var search = end
            var closing: Range<String.Index>?
            while let next = source[search...].firstIndex(of: "`") {
                let nextEnd = delimiterEnd(next, in: source)
                if source.distance(from: next, to: nextEnd) == count { closing = next..<nextEnd; break }
                search = nextEnd
            }
            guard let closing else {
                prose += source[cursor..<end]
                cursor = end
                continue
            }
            flush()
            var code = String(source[end..<closing.lowerBound]).replacingOccurrences(of: "\n", with: " ")
            // Markdown removes one surrounding space from nonblank code spans.
            if code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                code.removeFirst()
                code.removeLast()
            }
            result.append(.code(code, language: nil))
            cursor = closing.upperBound
        }
        flush()
        return result
    }

    private static func delimiterEnd(_ start: String.Index, in source: String) -> String.Index {
        var end = start
        while end < source.endIndex, source[end] == "`" { end = source.index(after: end) }
        return end
    }

    private static func escaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            guard source[cursor] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }
}
