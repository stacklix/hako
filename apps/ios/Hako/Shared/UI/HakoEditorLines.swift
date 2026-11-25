import Foundation

enum HakoEditorCaret {
    // Accept either quote glyph hit by TextKit. Never reinterpret escaped quotes
    // or a triple-quoted delimiter as an empty value.
    static func emptyQuoteInsertion(in text: String, atUTF16Offset offset: Int) -> Int? {
        let source = text as NSString
        guard offset >= 0, offset < source.length else { return nil }
        let quote = source.character(at: offset)
        guard quote == 34 || quote == 39 else { return nil }
        let start = offset > 0 && source.character(at: offset - 1) == quote ? offset - 1 : offset
        guard start + 1 < source.length, source.character(at: start + 1) == quote,
              start == 0 || source.character(at: start - 1) != quote,
              start + 2 == source.length || source.character(at: start + 2) != quote else { return nil }
        var backslashes = 0
        var preceding = start
        while preceding > 0, source.character(at: preceding - 1) == 92 {
            backslashes += 1
            preceding -= 1
        }
        return backslashes.isMultiple(of: 2) ? start + 1 : nil
    }
}

// UIKit and TextKit use UTF-16 offsets, including for emoji and composed text.
struct HakoEditorLines {
    let starts: [Int]

    init(_ text: String) {
        let source = text as NSString
        var starts = [0]
        var offset = 0
        while offset < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: offset, length: 0))
            if end > contentsEnd { starts.append(end) }
            offset = end
        }
        self.starts = starts
    }

    func index(containingUTF16Offset offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle } else { upper = middle }
        }
        return lower
    }
}
