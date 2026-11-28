import SwiftUI
import UIKit

struct SettingsSheet<Content: View>: View {
    let title: String
    var hasChanges = false
    var isBusy = false
    var saveEnabled = true
    var onSave: (() -> Void)? = nil
    var saveInProgress = false
    var edgeDismissEnabled = false
    private let detents: Set<PresentationDetent>
    private let saveAccessibilityLabel: String
    private let cancelTitle: String?
    private let saveTitle: String?
    private let closePlacement: ToolbarItemPlacement
    private let content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    init(title: String, hasChanges: Bool = false, isBusy: Bool = false,
         saveEnabled: Bool = true, onSave: (() -> Void)? = nil,
         saveInProgress: Bool = false,
         edgeDismissEnabled: Bool = false,
         detents: Set<PresentationDetent> = [.large], saveAccessibilityLabel: String = "保存配置",
         cancelTitle: String? = nil, saveTitle: String? = nil,
         closePlacement: ToolbarItemPlacement = .topBarLeading,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.hasChanges = hasChanges
        self.isBusy = isBusy
        self.saveEnabled = saveEnabled
        self.onSave = onSave
        self.saveInProgress = saveInProgress
        self.edgeDismissEnabled = edgeDismissEnabled
        self.detents = detents
        self.saveAccessibilityLabel = saveAccessibilityLabel
        self.cancelTitle = cancelTitle
        self.saveTitle = saveTitle
        self.closePlacement = closePlacement
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: closePlacement) {
                        Button(action: requestDismiss) {
                            if let cancelTitle { Text(cancelTitle) }
                            else { Image(systemName: "xmark") }
                        }
                            .accessibilityLabel(Text(cancelTitle ?? "关闭"))
                            .disabled(isBusy)
                    }
                    if let onSave {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                HakoDiagnosticStore.shared.breadcrumb("点击弹层保存/确认", detail: "内容类型：" + String(describing: Content.self).prefix(160))
                                onSave()
                            } label: {
                                if saveInProgress { ProgressView().controlSize(.small) }
                                else if let saveTitle { Text(saveTitle) }
                                else { Image(systemName: "checkmark") }
                            }
                                .accessibilityLabel(Text(saveAccessibilityLabel))
                                .disabled(!saveEnabled || isBusy)
                        }
                    }
                }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .onAppear { HakoDiagnosticStore.shared.breadcrumb("弹层内容出现", detail: "内容类型：" + String(describing: Content.self).prefix(160)) }
        .onDisappear { HakoDiagnosticStore.shared.breadcrumb("弹层内容离开", detail: "内容类型：" + String(describing: Content.self).prefix(160)) }
        .interactiveDismissDisabled(hasChanges || isBusy)
        .background {
            SheetDismissGuard(isBlocked: hasChanges || isBusy, edgeDismissEnabled: edgeDismissEnabled, onAttempt: requestDismiss)
                .frame(width: 0, height: 0)
        }
        .alert("有尚未保存的修改", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃并关闭", role: .destructive) { dismiss() }
        } message: {
            Text("关闭后，本次修改将不会保存。")
        }
    }

    private func requestDismiss() {
        HakoDiagnosticStore.shared.breadcrumb("请求关闭弹层", detail: "busy=\(isBusy), hasChanges=\(hasChanges)")
        guard !isBusy else { return }
        if hasChanges { confirmingDiscard = true }
        else { dismiss() }
    }
}

// SwiftUI can block a swipe, but does not expose its dismissal-attempt callback.
// Forward the original delegate so SwiftUI still receives presentation lifecycle events.
private struct SheetDismissGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    let edgeDismissEnabled: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> GuardController { GuardController() }
    func updateUIViewController(_ controller: GuardController, context: Context) {
        controller.isBlocked = isBlocked
        controller.edgeDismissEnabled = edgeDismissEnabled
        controller.onAttempt = onAttempt
        DispatchQueue.main.async { controller.attach() }
    }
    static func dismantleUIViewController(_ controller: GuardController, coordinator: ()) {
        controller.detach()
    }

    final class GuardController: UIViewController, UIAdaptivePresentationControllerDelegate, UIGestureRecognizerDelegate {
        var isBlocked = false
        var edgeDismissEnabled = false
        var onAttempt: () -> Void = { }
        private weak var guardedPresentation: UIPresentationController?
        private weak var originalDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var edgeDismiss: UIScreenEdgePanGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { self.attach() }
        }
        func attach() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard root.presentingViewController != nil, let presentation = root.presentationController else { return }
            if guardedPresentation !== presentation { detach() }
            guardedPresentation = presentation
            root.isModalInPresentation = isBlocked
            if presentation.delegate !== self {
                originalDelegate = presentation.delegate
                presentation.delegate = self
            }
            if edgeDismissEnabled && edgeDismiss == nil {
                let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
                gesture.edges = .left
                gesture.maximumNumberOfTouches = 1
                gesture.delegate = self
                root.view.addGestureRecognizer(gesture)
                edgeDismiss = gesture
            } else if !edgeDismissEnabled {
                removeEdgeDismiss()
            }
        }
        func detach() {
            removeEdgeDismiss()
            if let presentation = guardedPresentation, presentation.delegate === self {
                presentation.delegate = originalDelegate
                presentation.presentedViewController.isModalInPresentation = false
            }
            guardedPresentation = nil
            originalDelegate = nil
        }
        private func removeEdgeDismiss() {
            if let edgeDismiss { edgeDismiss.view?.removeGestureRecognizer(edgeDismiss) }
            edgeDismiss = nil
        }
        private func hasPushedPage(_ controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 { return true }
            return controller.children.contains { hasPushedPage($0) }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === edgeDismiss, let gesture = edgeDismiss,
                  let presentation = guardedPresentation,
                  presentation.presentedViewController.presentedViewController == nil,
                  !hasPushedPage(presentation.presentedViewController) else { return false }
            let velocity = gesture.velocity(in: gesture.view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.2
        }
        @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view, let presentation = guardedPresentation else { return }
            let translation = gesture.translation(in: view)
            guard translation.x > 0, translation.x > abs(translation.y) * 1.2,
                  translation.x >= view.bounds.width * 0.22 || translation.x >= 24 && gesture.velocity(in: view).x >= 600 else { return }
            if presentationControllerShouldDismiss(presentation) { onAttempt() }
            else { presentationControllerDidAttemptToDismiss(presentation) }
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isBlocked && (originalDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            HakoDiagnosticStore.shared.breadcrumb("尝试下滑关闭弹层", detail: "blocked=\(isBlocked)")
            if isBlocked { onAttempt() }
            else { originalDelegate?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            HakoDiagnosticStore.shared.breadcrumb("弹层即将关闭")
            originalDelegate?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            HakoDiagnosticStore.shared.breadcrumb("弹层已关闭")
            originalDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
