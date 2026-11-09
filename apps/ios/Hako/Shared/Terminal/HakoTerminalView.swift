import UIKit
import SwiftTerm

// Shared keyboard gestures for native terminal views.
final class HakoTerminalView: SwiftTerm.TerminalView {
    var onWindowAttached: (() -> Void)?
    private(set) var keyboardDismissedByUser = false
    private var configuredKeyboardGestures = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !configuredKeyboardGestures {
            configuredKeyboardGestures = true
            // Reuse SwiftTerm's single tap recognizer so its double tap and
            // long press selection gestures retain their existing precedence.
            if let tap = gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer })
                .first(where: { $0.numberOfTapsRequired == 1 && $0.numberOfTouchesRequired == 1 }) {
                tap.removeTarget(self, action: NSSelectorFromString("singleTap:"))
                tap.addTarget(self, action: #selector(toggleKeyboard(_:)))
            }
            // A history drag must not also resize the terminal by hiding the keyboard.
            keyboardDismissMode = .none
        }
        if window != nil { onWindowAttached?() }
    }

    override func becomeFirstResponder() -> Bool {
        // Connection checks and delayed focus retries must respect a deliberate
        // dismissal until the user taps the terminal or a shortcut key again.
        guard !keyboardDismissedByUser else { return false }
        return super.becomeFirstResponder()
    }

    func showKeyboard() {
        keyboardDismissedByUser = false
        _ = becomeFirstResponder()
    }

    private func hideKeyboard() {
        keyboardDismissedByUser = true
        _ = resignFirstResponder()
    }

    @objc private func toggleKeyboard(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if isFirstResponder { hideKeyboard() } else { showKeyboard() }
    }

    override func layoutSubviews() {
        // Keyboard transitions can temporarily propose an empty terminal grid.
        guard bounds.width >= 32, bounds.height >= 32 else { return }
        super.layoutSubviews()
    }
}
