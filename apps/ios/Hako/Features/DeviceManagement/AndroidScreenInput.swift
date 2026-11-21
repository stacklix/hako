import Foundation

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
