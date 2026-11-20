import Foundation

/// Horizontal travel is positive to the right; progress is 0 (closed) ... 1 (open).
enum HakoPinDrag {
    static let activationWidth = 32.0

    static func acceptsStart(x: Double, y: Double, width: Double, height: Double) -> Bool {
        width > 0 && height > 0 && x >= max(0, width - activationWidth) && x <= width && y >= 0 && y <= height
    }

    static func opens(velocityX: Double, velocityY: Double) -> Bool {
        velocityX < 0 && abs(velocityX) > abs(velocityY) * 0.8
    }

    static func progress(from initial: Double, translationX: Double, width: Double) -> Double {
        guard width > 0 else { return min(1, max(0, initial)) }
        return min(1, max(0, initial - translationX / width))
    }

    static func shouldOpen(progress: Double, velocityX: Double, width: Double,
                           initial: Double, cancelled: Bool = false) -> Bool {
        if cancelled { return initial >= 0.5 }
        // Project a short distance ahead so a deliberate flick also finishes the transition.
        let projected = Self.progress(from: progress, translationX: velocityX * 0.18, width: width)
        return projected >= 0.5
    }
}
