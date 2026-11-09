import SwiftUI
import UIKit

// Reject vertical pans before recognition so the surrounding ScrollView can scroll.
struct UsageChartInteraction: UIViewRepresentable {
    let canPan: Bool
    let select: (CGPoint, Bool) -> Void
    let zoom: (CGFloat, CGFloat, UIGestureRecognizer.State) -> Void
    let pan: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        let coordinator = context.coordinator
        coordinator.attach(to: view)
        view.connectScroll = { [weak coordinator] scroll in coordinator?.connect(to: scroll) }
        return view
    }
    func updateUIView(_ view: InteractionView, context: Context) { context.coordinator.parent = self }

    final class InteractionView: UIView {
        var connectScroll: ((UIScrollView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { connectScroll?(scroll); break }
                ancestor = view.superview
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: UsageChartInteraction
        private weak var view: UIView?
        private weak var scrollView: UIScrollView?
        private var horizontalPan: UIPanGestureRecognizer!
        private var longPress: UILongPressGestureRecognizer!
        private var pinchAnchor: CGFloat = 0.5
        init(_ parent: UsageChartInteraction) { self.parent = parent }
        func attach(to view: UIView) {
            self.view = view
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            longPress = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            longPress.minimumPressDuration = 0.25
            longPress.allowableMovement = 10
            horizontalPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            horizontalPan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            for gesture in [tap, longPress!, horizontalPan!, pinch] as [UIGestureRecognizer] {
                gesture.delegate = self
                gesture.cancelsTouchesInView = false
                view.addGestureRecognizer(gesture)
            }
            // A stationary press selects; a quick horizontal swipe pans after movement cancels the press.
            horizontalPan.require(toFail: longPress)
            tap.require(toFail: horizontalPan)
            tap.require(toFail: longPress)
        }
        func connect(to scroll: UIScrollView) {
            guard scrollView !== scroll else { return }
            scrollView = scroll
            // Both recognizers fail on vertical movement, handing the same touch to page scrolling.
            scroll.panGestureRecognizer.require(toFail: horizontalPan)
            scroll.panGestureRecognizer.require(toFail: longPress)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === horizontalPan, let view else { return true }
            let velocity = horizontalPan.velocity(in: view)
            return UsageChartRange.canPan(horizontal: velocity.x, vertical: velocity.y, zoomed: parent.canPan)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // A scroll view's own recognizer must not prevent two-finger zooming.
            gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer === scrollView?.panGestureRecognizer
        }
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view else { return }
            parent.select(gesture.location(in: view), true)
        }
        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard [.began, .changed, .ended].contains(gesture.state), let view else { return }
            parent.select(gesture.location(in: view), false)
        }
        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view, view.bounds.width > 0 else { return }
            parent.pan(-gesture.translation(in: view).x / view.bounds.width, gesture.state)
        }
        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let view, view.bounds.width > 0 else { return }
            if gesture.state == .began {
                pinchAnchor = min(max(gesture.location(in: view).x / view.bounds.width, 0), 1)
            }
            parent.zoom(gesture.scale, pinchAnchor, gesture.state)
        }
    }
}
