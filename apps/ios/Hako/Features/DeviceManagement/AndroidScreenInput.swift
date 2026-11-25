import Foundation

enum AndroidScreenNavigation: String, CaseIterable, Identifiable {
    case back, home, recents
    var id: String { rawValue }
    var title: String { switch self { case .back: "返回"; case .home: "主页"; case .recents: "最近任务" } }
    var symbol: String { switch self { case .back: "chevron.backward"; case .home: "house"; case .recents: "square.on.square" } }
    var accessibilityLabel: String {
        switch self { case .back: "返回 Android 上一页"; case .home: "返回 Android 主屏幕"; case .recents: "打开 Android 最近任务" }
    }
}

struct AndroidFloatingDragState {
    private(set) var translation = CGSize.zero
    private(set) var isDragging = false
    mutating func move(to delta: CGSize) {
        translation = delta
        isDragging = isDragging || hypot(delta.width, delta.height) >= 16
    }
}

enum AndroidFloatingControlsLayout {
    static func center(in bounds: CGSize, controls: CGSize, position: CGPoint, translation: CGSize = .zero) -> CGPoint {
        func axis(_ extent: CGFloat, _ control: CGFloat, _ fraction: CGFloat, _ delta: CGFloat) -> CGFloat {
            let lower = min(extent / 2, control / 2 + 8)
            let upper = max(lower, extent - lower)
            return min(max(lower + (upper - lower) * min(max(fraction, 0), 1) + delta, lower), upper)
        }
        return CGPoint(x: axis(bounds.width, controls.width, position.x, translation.width),
                       y: axis(bounds.height, controls.height, position.y, translation.height))
    }

    static func position(for center: CGPoint, in bounds: CGSize, controls: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, _ extent: CGFloat, _ control: CGFloat) -> CGFloat {
            let lower = min(extent / 2, control / 2 + 8)
            let span = max(0, extent - lower * 2)
            return span > 0 ? min(max((value - lower) / span, 0), 1) : 0
        }
        return CGPoint(x: axis(center.x, bounds.width, controls.width), y: axis(center.y, bounds.height, controls.height))
    }
}

enum AndroidScreenInput {
    static func touch(action: UInt8, point: CGPoint, surface: CGSize, pixels: CGSize) -> Data? {
        guard action <= 3, surface.width > 0, surface.height > 0,
              pixels.width > 0, pixels.height > 0, pixels.width <= 4096, pixels.height <= 4096,
              point.x.isFinite, point.y.isFinite else { return nil }
        var data = Data([2, action])
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt64(0))
        append(UInt32(min(max(point.x / surface.width, 0), 1) * (pixels.width - 1)))
        append(UInt32(min(max(point.y / surface.height, 0), 1) * (pixels.height - 1)))
        append(UInt16(pixels.width)); append(UInt16(pixels.height))
        append(UInt16(action == 1 || action == 3 ? 0 : 65535))
        append(UInt32(0)); append(UInt32(0))
        return data
    }
}
