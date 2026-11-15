import Foundation

enum WorkshopDiff {
    enum Kind { case context, addition, removal, hunk, metadata }
    struct Line {
        let text: String
        let kind: Kind
    }

    static func lines(_ source: String) -> [Line] {
        // Split at LF bytes: Swift treats CRLF as one grapheme, and the CR must
        // remain in the original text for selection/copying to stay lossless.
        let lines = source.utf8.split(separator: 0x0a, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var inHunk = false
        return lines.enumerated().map { index, line in
            let kind: Kind
            if line.hasPrefix("@@") {
                inHunk = true; kind = .hunk
            } else if line.hasPrefix("diff --git ") || line.hasPrefix("index ") {
                inHunk = false; kind = .metadata
            } else if !inHunk && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) {
                kind = .metadata
            } else if line.hasPrefix("+") {
                kind = .addition
            } else if line.hasPrefix("-") {
                kind = .removal
            } else {
                if !line.hasPrefix(" ") && !line.hasPrefix("\\") { inHunk = false }
                kind = .context
            }
            return Line(text: line + (index < lines.count - 1 ? "\n" : ""), kind: kind)
        }
    }
}

enum WorkshopMessagePart: Equatable, Sendable {
    case text(String)
    case code(String, language: String?)
    case image(String, URL)
    case table(WorkshopMarkdownTable)
}

struct WorkshopMarkdownTable: Equatable, Sendable {
    enum Alignment: Sendable { case leading, center, trailing }
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]
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
                result += blockParts(prose)
                prose = ""
                fence = opening
            } else {
                prose += line + (index < lines.count - 1 ? "\n" : "")
            }
        }
        if let fence { result.append(.code(code, language: fence.language)) }
        result += blockParts(prose)
        return result
    }

    private static func blockParts(_ source: String) -> [WorkshopMessagePart] {
        let lines = source.components(separatedBy: "\n")
        var result: [WorkshopMessagePart] = []
        var prose = ""
        var index = 0
        while index < lines.count {
            if index + 1 < lines.count, let headers = tableCells(lines[index]),
               let separators = tableCells(lines[index + 1]), headers.count == separators.count,
               let alignments = tableAlignments(separators) {
                result += inlineParts(prose); prose = ""
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]) {
                    rows.append(Array((cells + Array(repeating: "", count: headers.count)).prefix(headers.count)))
                    index += 1
                }
                result.append(.table(WorkshopMarkdownTable(headers: headers, alignments: alignments, rows: rows)))
            } else {
                prose += lines[index] + (index < lines.count - 1 ? "\n" : "")
                index += 1
            }
        }
        result += inlineParts(prose)
        return result
    }

    private static func tableCells(_ source: String) -> [String]? {
        let source = source.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }
        var cells: [String] = []
        var cell = ""
        var cursor = source.startIndex
        var sawPipe = false
        var endsWithPipe = false
        while cursor < source.endIndex {
            let character = source[cursor]
            let next = source.index(after: cursor)
            if character == "\\", next < source.endIndex {
                // Escaped pipes belong to the cell, including inside code spans.
                if source[next] == "|" { cell.append("|") }
                else { cell.append(character); cell.append(source[next]) }
                cursor = source.index(after: next); endsWithPipe = false
                continue
            }
            if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
                sawPipe = true; endsWithPipe = true
            } else { cell.append(character); endsWithPipe = false }
            cursor = next
        }
        guard sawPipe else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if source.first == "|" { cells.removeFirst() }
        if endsWithPipe { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(_ cells: [String]) -> [WorkshopMarkdownTable.Alignment]? {
        var result: [WorkshopMarkdownTable.Alignment] = []
        for cell in cells {
            var value = cell[...]
            let left = value.first == ":", right = value.last == ":"
            if left { value = value.dropFirst() }
            if right { value = value.dropLast() }
            guard value.count >= 3, value.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(right ? (left ? .center : .trailing) : .leading)
        }
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
            if let picture = linkedImage(at: cursor, in: source) ?? image(at: cursor, in: source) {
                if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(prose)) }
                result.append(.image(picture.alt, picture.url))
                prose = ""; cursor = picture.end
                continue
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
            // Leave code spans inside the Markdown paragraph. Only fenced code
            // becomes a separate snippet with a copy button.
            prose += source[cursor..<closing.upperBound]
            cursor = closing.upperBound
        }
        if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(prose)) }
        return result
    }

    private static func linkedImage(at start: String.Index, in source: String) -> (alt: String, url: URL, end: String.Index)? {
        // Consume the complete wrapper before splitting out its image, otherwise
        // [![alt](image)](link) leaves "[" and "](link)" in separate text parts.
        guard source[start...].hasPrefix("[!["), !escaped(start, in: source),
              let picture = image(at: source.index(after: start), in: source),
              picture.end < source.endIndex, source[picture.end] == "]",
              let destination = webDestination(at: source.index(after: picture.end), in: source) else { return nil }
        return (picture.alt, picture.url, destination.end)
    }

    private static func image(at start: String.Index, in source: String) -> (alt: String, url: URL, end: String.Index)? {
        guard source[start...].hasPrefix("!["), !escaped(start, in: source) else { return nil }
        let labelStart = source.index(start, offsetBy: 2)
        guard let labelEnd = source[labelStart...].firstIndex(of: "]") else { return nil }
        guard let destination = webDestination(at: source.index(after: labelEnd), in: source) else { return nil }
        return (String(source[labelStart..<labelEnd]), destination.url, destination.end)
    }

    private static func webDestination(at opening: String.Index, in source: String) -> (url: URL, end: String.Index)? {
        guard opening < source.endIndex, source[opening] == "(" else { return nil }
        var cursor = source.index(after: opening)
        let urlStart = cursor
        var depth = 1
        while cursor < source.endIndex {
            if source[cursor] == "(" { depth += 1 }
            if source[cursor] == ")" { depth -= 1; if depth == 0 { break } }
            cursor = source.index(after: cursor)
        }
        guard depth == 0 else { return nil }
        let address = String(source[urlStart..<cursor])
        guard !address.contains(where: \.isWhitespace), let url = URL(string: address),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return (url, source.index(after: cursor))
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
