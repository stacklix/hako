import SwiftUI
import UIKit

// Own the plot's gestures so the surrounding ScrollView cannot consume horizontal scrubbing.
struct HakoChartInteraction: UIViewRepresentable {
    let select:(CGPoint,Bool)->Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> InteractionView {
        let view=InteractionView()
        view.backgroundColor = .clear
        view.isAccessibilityElement=false
        let coordinator=context.coordinator
        coordinator.attach(to:view)
        view.connectScroll={ [weak coordinator] scroll in coordinator?.connect(to:scroll) }
        return view
    }
    func updateUIView(_ view:InteractionView,context:Context) { context.coordinator.parent=self }

    final class InteractionView:UIView {
        var connectScroll:((UIScrollView)->Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor=superview
            while let view=ancestor {
                if let scroll=view as? UIScrollView { connectScroll?(scroll);break }
                ancestor=view.superview
            }
        }
    }

    final class Coordinator:NSObject,UIGestureRecognizerDelegate {
        var parent:HakoChartInteraction
        private weak var view:UIView?
        private weak var scrollView:UIScrollView?
        private var pan:UIPanGestureRecognizer!
        private var press:UILongPressGestureRecognizer!
        init(_ parent:HakoChartInteraction) { self.parent=parent }
        func attach(to view:UIView) {
            self.view=view
            let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
            pan=UIPanGestureRecognizer(target:self,action:#selector(moved(_:)))
            pan.maximumNumberOfTouches=1
            press=UILongPressGestureRecognizer(target:self,action:#selector(held(_:)))
            press.minimumPressDuration=0.2
            press.allowableMovement=10
            for gesture in [tap,pan!,press!] as [UIGestureRecognizer] {
                gesture.delegate=self
                view.addGestureRecognizer(gesture)
            }
            pan.require(toFail:press)
            tap.require(toFail:pan)
            tap.require(toFail:press)
        }
        func connect(to scroll:UIScrollView) {
            guard scrollView !== scroll else { return }
            scrollView=scroll
            // Vertical movement rejects both plot recognizers and hands the touch to page scrolling.
            scroll.panGestureRecognizer.require(toFail:pan)
            scroll.panGestureRecognizer.require(toFail:press)
        }
        func gestureRecognizerShouldBegin(_ recognizer:UIGestureRecognizer) -> Bool {
            guard recognizer === pan,let view else { return true }
            let velocity=pan.velocity(in:view)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc private func tapped(_ gesture:UITapGestureRecognizer) {
            guard gesture.state == .ended,let view else { return }
            parent.select(gesture.location(in:view),true)
        }
        @objc private func moved(_ gesture:UIPanGestureRecognizer) {
            guard [.began,.changed,.ended].contains(gesture.state),let view else { return }
            parent.select(gesture.location(in:view),false)
        }
        @objc private func held(_ gesture:UILongPressGestureRecognizer) {
            guard [.began,.changed,.ended].contains(gesture.state),let view else { return }
            parent.select(gesture.location(in:view),false)
        }
    }
}
