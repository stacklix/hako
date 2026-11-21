import Foundation

@main struct AndroidScreenInputTests {
    static func main() {
        let surface = CGSize(width: 270, height: 600), pixels = CGSize(width: 1080, height: 2400)
        func value(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
            data.dropFirst(start).prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }
        let center = AndroidScreenInput.touch(action: 0, point: CGPoint(x: 135, y: 300), surface: surface, pixels: pixels)!
        precondition(center.count == 32 && center[0] == 2 && center[1] == 0)
        precondition(value(center, 10, 4) == 539 && value(center, 14, 4) == 1199)
        precondition(value(center, 18, 2) == 1080 && value(center, 20, 2) == 2400 && value(center, 22, 2) == 65535)
        let edge = AndroidScreenInput.touch(action: 1, point: CGPoint(x: 900, y: -10), surface: surface, pixels: pixels)!
        precondition(value(edge, 10, 4) == 1079 && value(edge, 14, 4) == 0 && value(edge, 22, 2) == 0)
        let rotated = AndroidScreenInput.touch(action: 2, point: CGPoint(x: 135, y: 300), surface: surface, pixels: CGSize(width: 2400, height: 1080))!
        precondition(value(rotated, 10, 4) == 1199 && value(rotated, 14, 4) == 539)
        precondition(AndroidScreenInput.touch(action: 4, point: .zero, surface: surface, pixels: pixels) == nil)
        precondition(AndroidScreenInput.touch(action: 0, point: .zero, surface: .zero, pixels: pixels) == nil)
        precondition(AndroidScreenInput.touch(action: 0, point: CGPoint(x: CGFloat.nan, y: 0), surface: surface, pixels: pixels) == nil)
        print("PASS: touch packet format, scaled coordinates, edge clamp, rotation and invalid input.")
    }
}
