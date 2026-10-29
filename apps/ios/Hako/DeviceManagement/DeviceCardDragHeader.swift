import SwiftUI
import UIKit

// UIKit supplies the system long-press lift, drag preview and an end callback even
// when a drag is cancelled outside the board. A short tap still expands the card.
struct DeviceCardDragHeader<Content: View>: UIViewRepresentable {
    let name: String
    let accessibilityTitle: String
    let accessibilitySummary: String
    let canDrag: Bool
    let activate: () -> Void
    let begin: () -> Void
    let moved: (CGPoint) -> Void
    let ended: (Bool) -> Void
    let moveBy: (Int) -> Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        let interaction = UIDragInteraction(delegate: context.coordinator)
        interaction.isEnabled = true
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        context.coordinator.parent = self
        let configuration = UIHostingConfiguration { content().allowsHitTesting(false) }
            .margins(.all, 0).minSize(width: 0, height: 0)
        if let hosted = view.hosted { hosted.configuration = configuration }
        else { view.install(configuration.makeContentView()) }
        view.accessibilityLabel = accessibilityTitle
        view.activate = { [weak coordinator = context.coordinator] in coordinator?.tapped() }
        view.accessibilityValue = accessibilitySummary
        view.accessibilityHint = canDrag ? "轻点展开或收起，长按拖动调整顺序。" : "轻点展开或收起。"
        view.accessibilityCustomActions = canDrag ? [
            UIAccessibilityCustomAction(name: "向前移动", target: context.coordinator, selector: #selector(Coordinator.moveEarlier)),
            UIAccessibilityCustomAction(name: "向后移动", target: context.coordinator, selector: #selector(Coordinator.moveLater))
        ] : []
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return uiView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }

    final class Container: UIView {
        var hosted: (UIView & UIContentView)?
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool { activate?(); return true }
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .secondarySystemGroupedBackground
            layer.cornerRadius = 17
            isAccessibilityElement = true
            accessibilityTraits = .button
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func install(_ view: UIView & UIContentView) {
            hosted = view
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var parent: DeviceCardDragHeader
        private var dragging = false
        private var finalized = false
        private var lastDragEndedAt = Date.distantPast
        init(_ parent: DeviceCardDragHeader) { self.parent = parent }

        @objc func tapped() {
            guard !dragging, Date.now.timeIntervalSince(lastDragEndedAt) > 0.25 else { return }
            parent.activate()
        }
        @objc func moveEarlier() -> Bool { parent.moveBy(-1) }
        @objc func moveLater() -> Bool { parent.moveBy(1) }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard parent.canDrag else { return [] }
            return [UIDragItem(itemProvider: NSItemProvider(object: parent.name as NSString))]
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            dragging = true
            finalized = false
            parent.begin()
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
            guard let view = interaction.view else { return }
            parent.moved(session.location(in: view))
        }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, willEndWith operation: UIDropOperation) {
            guard dragging, !finalized else { return }
            finalized = true
            parent.ended(operation == .move)
        }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            guard dragging else { return }
            dragging = false
            lastDragEndedAt = .now
            if !finalized { parent.ended(operation == .move) }
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
    }
}
