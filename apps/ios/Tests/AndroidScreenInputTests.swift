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
        let toolbar = CGSize(width: 228, height: 64), bubble = CGSize(width: 44, height: 44)
        let portrait = CGSize(width: 320, height: 600)
        let dragged = AndroidFloatingControlsLayout.center(in: portrait, controls: toolbar, position: .zero,
                                                          translation: CGSize(width: 900, height: -900))
        precondition(dragged == CGPoint(x: 198, y: 40))
        let position = AndroidFloatingControlsLayout.position(for: dragged, in: portrait, controls: toolbar)
        precondition(position == CGPoint(x: 1, y: 0))
        let folded = AndroidFloatingControlsLayout.center(in: portrait, controls: bubble, position: position)
        precondition(folded.x + bubble.width / 2 == portrait.width - 8)
        precondition(AndroidFloatingControlsLayout.center(in: portrait, controls: toolbar, position: position) == dragged)
        let landscape = CGSize(width: 600, height: 320)
        let rotatedControl = AndroidFloatingControlsLayout.center(in: landscape, controls: toolbar, position: position)
        precondition(rotatedControl == CGPoint(x: 478, y: 40))
        let small = AndroidFloatingControlsLayout.center(in: CGSize(width: 180, height: 40), controls: toolbar, position: position)
        precondition(small == CGPoint(x: 90, y: 20))
        var gesture = AndroidFloatingDragState()
        for point in [CGSize(width: 3, height: 2), CGSize(width: 8, height: 9), CGSize(width: 1, height: 0)] {
            gesture.move(to: point); precondition(!gesture.isDragging)
        }
        gesture.move(to: CGSize(width: 16, height: 0)); precondition(gesture.isDragging)
        gesture.move(to: .zero); precondition(gesture.isDragging)
        gesture = AndroidFloatingDragState(); precondition(!gesture.isDragging && gesture.translation == .zero)
        print("PASS: finger jitter remains a tap; dragging stays active after moving back and resets for the next tap.")
        print("PASS: floating controls clamp dragging, retain position through folding, and stay bounded after rotation.")
        print("PASS: touch packet format, scaled coordinates, edge clamp, rotation and invalid input.")
    }
}
