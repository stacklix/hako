import Foundation

// Stored per server, account, device and command group. Missing commands retain their
// saved place; newly advertised commands are appended in the Agent's manifest order.
enum DeviceCardOrder {
    static func arranged(available: [String], saved: [String]) -> [String] {
        let availableSet = Set(available)
        var seen = Set<String>()
        return (saved + available).filter { availableSet.contains($0) && seen.insert($0).inserted }
    }

    static func moving(_ name: String, to target: String, in names: [String]) -> [String] {
        guard let source = names.firstIndex(of: name), let destination = names.firstIndex(of: target),
              source != destination else { return names }
        var result = names
        result.insert(result.remove(at: source), at: destination)
        return result
    }

    static func saving(visible: [String], previous: [String]) -> [String] {
        var seen = Set<String>()
        let unique = visible.filter { seen.insert($0).inserted }
        let active = Set(unique)
        var next = unique.makeIterator()
        seen.removeAll()
        var result = previous.filter { seen.insert($0).inserted }.compactMap { active.contains($0) ? next.next() : $0 }
        while let name = next.next() { result.append(name) }
        return result
    }

    static func storageKey(server: String, account: String, agent: String, group: String) -> String {
        let identity = (try? JSONEncoder().encode([server, account, agent, group])) ?? Data()
        return "hako.device-card-order." + identity.base64EncodedString()
    }
}

struct DeviceCardScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
    var maximumOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    func clamped(_ value: CGFloat) -> CGFloat { min(maximumOffset, max(0, value)) }

    func fitting(_ frame: CGRect) -> CGFloat? {
        guard viewportHeight > 0 else { return nil }
        if frame.minY >= offset + 16 && frame.maxY <= offset + viewportHeight - 16 { return nil }
        let inset: CGFloat = frame.height > viewportHeight - 48 ? 24 : max(24, (viewportHeight - frame.height) / 3)
        return clamped(frame.minY - inset)
    }
}

struct DeviceCardBookmark {
    let name: String?
    let relativeY: CGFloat
    let offset: CGFloat

    static func capture(frames: [String: CGRect], offset: CGFloat) -> Self {
        let anchor = frames.filter { $0.value.maxY > offset + 1 }
            .min { lhs, rhs in
                lhs.value.minY == rhs.value.minY ? lhs.value.minX < rhs.value.minX : lhs.value.minY < rhs.value.minY
            }
        return Self(name: anchor?.key, relativeY: (anchor?.value.minY ?? offset) - offset, offset: offset)
    }

    func restoredOffset(frames: [String: CGRect], geometry: DeviceCardScrollGeometry) -> CGFloat {
        geometry.clamped(name.flatMap { frames[$0] }.map { $0.minY - relativeY } ?? offset)
    }
}

enum DeviceCardPlacement {
    static func frames(width: CGFloat, columns: Int, spacing: CGFloat, heights: [CGFloat], expanded: [Bool]) -> [CGRect] {
        let count = max(1, columns)
        let columnWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var frames: [CGRect] = []
        var row: [Int] = []
        var y: CGFloat = 0
        func finishRow() {
            guard !row.isEmpty else { return }
            let height = row.map { heights[$0] }.max() ?? 0
            for (column, index) in row.enumerated() {
                frames[index] = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height)
            }
            y += height + spacing
            row.removeAll()
        }
        for index in heights.indices {
            frames.append(.zero)
            if expanded[index] && count > 1 {
                finishRow()
                frames[index] = CGRect(x: 0, y: y, width: width, height: heights[index])
                y += heights[index] + spacing
            } else {
                row.append(index)
                if row.count == count { finishRow() }
            }
        }
        finishRow()
        return frames
    }
}
