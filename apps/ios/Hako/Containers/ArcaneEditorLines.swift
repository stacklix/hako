import Foundation

// UIKit and TextKit use UTF-16 offsets, including for emoji and composed text.
struct ArcaneEditorLines {
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
