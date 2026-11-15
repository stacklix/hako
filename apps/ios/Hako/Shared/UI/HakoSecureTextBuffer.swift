import Foundation

/// Keeps the credential separate from the text rendered by the multiline editor.
struct HakoSecureTextBuffer {
    private(set) var text: String
    private(set) var isSecure: Bool
    private(set) var selection = NSRange(location: 0, length: 0)

    var displayText: String {
        isSecure ? String(text.map { $0.isNewline ? "\n" : "•" }) : text
    }

    init(text: String, isSecure: Bool) {
        self.text = text
        self.isSecure = isSecure
    }

    mutating func synchronize(text: String, isSecure: Bool, selection: NSRange) {
        let originalSelection = sourceRange(for: selection) ?? NSRange(location: self.text.utf16.count, length: 0)
        self.text = text
        self.isSecure = isSecure
        self.selection = displayRange(for: originalSelection)
    }

    mutating func select(_ range: NSRange) {
        guard sourceRange(for: range) != nil else { return }
        selection = range
    }

    @discardableResult
    mutating func replace(_ range: NSRange, with replacement: String) -> Bool {
        guard let originalRange = sourceRange(for: range),
              let stringRange = Range(originalRange, in: text) else { return false }
        text.replaceSubrange(stringRange, with: replacement)
        selection = displayRange(for: NSRange(location: originalRange.location + replacement.utf16.count, length: 0))
        return true
    }

    private var boundaries: [Int] {
        var offsets = [0]
        for character in text { offsets.append(offsets.last! + character.utf16.count) }
        return offsets
    }

    private func sourceRange(for range: NSRange) -> NSRange? {
        let length = isSecure ? text.count : text.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return nil }
        guard isSecure else { return Range(range, in: text) == nil ? nil : range }
        let offsets = boundaries
        return NSRange(location: offsets[range.location],
                       length: offsets[range.location + range.length] - offsets[range.location])
    }

    private func displayRange(for range: NSRange) -> NSRange {
        let start = min(range.location, text.utf16.count)
        let end = start + min(range.length, text.utf16.count - start)
        guard isSecure else { return NSRange(location: start, length: end - start) }
        let offsets = boundaries
        let last = offsets.firstIndex { $0 >= end } ?? offsets.count - 1
        let first = start == end ? last : offsets.lastIndex { $0 <= start } ?? 0
        return NSRange(location: first, length: last - first)
    }
}
