import Foundation

@main struct HakoPinDragTests {
    static func main() {
        func near(_ value: Double, _ expected: Double) { precondition(abs(value - expected) < 0.000001) }
        for y in [0.0, 24, 80, 400, 760, 840, 844] {
            precondition(HakoPinDrag.acceptsStart(x: 360, y: y, width: 390, height: 844))
        }
        precondition(HakoPinDrag.acceptsStart(x: 358, y: 400, width: 390, height: 844))
        precondition(!HakoPinDrag.acceptsStart(x: 357, y: 400, width: 390, height: 844))
        precondition(!HakoPinDrag.acceptsStart(x: 200, y: 400, width: 390, height: 844))
        precondition(!HakoPinDrag.acceptsStart(x: 380, y: -1, width: 390, height: 844))
        precondition(!HakoPinDrag.acceptsStart(x: 380, y: 845, width: 390, height: 844))
        precondition(HakoPinDrag.opens(velocityX: -100, velocityY: 110))
        precondition(!HakoPinDrag.opens(velocityX: -50, velocityY: 200))
        precondition(!HakoPinDrag.opens(velocityX: 100, velocityY: 0))
        precondition(!HakoPinDrag.opens(velocityX: 0, velocityY: 0))
        near(HakoPinDrag.progress(from: 0, translationX: -80, width: 320), 0.25)
        near(HakoPinDrag.progress(from: 0, translationX: -240, width: 320), 0.75)
        near(HakoPinDrag.progress(from: 0, translationX: -60, width: 320), 0.1875)
        near(HakoPinDrag.progress(from: 1, translationX: 80, width: 320), 0.75)
        near(HakoPinDrag.progress(from: 1, translationX: 280, width: 320), 0.125)
        near(HakoPinDrag.progress(from: 1, translationX: 20, width: 320), 0.9375)
        near(HakoPinDrag.progress(from: 0, translationX: -1000, width: 320), 1)
        near(HakoPinDrag.progress(from: 1, translationX: 1000, width: 320), 0)
        near(HakoPinDrag.progress(from: 1, translationX: 10, width: 0), 1)
        precondition(!HakoPinDrag.shouldOpen(progress: 0.3, velocityX: 0, width: 320, initial: 0))
        precondition(HakoPinDrag.shouldOpen(progress: 0.7, velocityX: 0, width: 320, initial: 0))
        precondition(HakoPinDrag.shouldOpen(progress: 0.2, velocityX: -800, width: 320, initial: 0))
        precondition(!HakoPinDrag.shouldOpen(progress: 0.8, velocityX: 800, width: 320, initial: 1))
        precondition(!HakoPinDrag.shouldOpen(progress: 0.8, velocityX: 0, width: 320, initial: 0, cancelled: true))
        precondition(HakoPinDrag.shouldOpen(progress: 0.2, velocityX: 0, width: 320, initial: 1, cancelled: true))
        print("PASS: Pin follows drag in both directions, clamps travel, projects flicks and restores cancelled gestures")
    }
}
