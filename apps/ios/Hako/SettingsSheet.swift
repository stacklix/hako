import SwiftUI
import UIKit

struct SettingsSheet<Content: View>: View {
    let title: String
    var hasChanges = false
    var isBusy = false
    var saveEnabled = true
    var onSave: (() -> Void)? = nil
    private let content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    init(title: String, hasChanges: Bool = false, isBusy: Bool = false,
         saveEnabled: Bool = true, onSave: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.hasChanges = hasChanges
        self.isBusy = isBusy
        self.saveEnabled = saveEnabled
        self.onSave = onSave
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: requestDismiss) { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭")
                            .disabled(isBusy)
                    }
                    if let onSave {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onSave) { Image(systemName: "checkmark") }
                                .accessibilityLabel("保存配置")
                                .disabled(!saveEnabled || isBusy)
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasChanges || isBusy)
        .background {
            SheetDismissGuard(isBlocked: hasChanges || isBusy, onAttempt: requestDismiss)
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
        guard !isBusy else { return }
        if hasChanges { confirmingDiscard = true }
        else { dismiss() }
    }
}

// SwiftUI can block a swipe, but does not expose its dismissal-attempt callback.
// Forward the original delegate so SwiftUI still receives presentation lifecycle events.
private struct SheetDismissGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> GuardController { GuardController() }
    func updateUIViewController(_ controller: GuardController, context: Context) {
        controller.isBlocked = isBlocked
        controller.onAttempt = onAttempt
        DispatchQueue.main.async { controller.attach() }
    }
    static func dismantleUIViewController(_ controller: GuardController, coordinator: ()) {
        controller.detach()
    }

    final class GuardController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var isBlocked = false
        var onAttempt: () -> Void = { }
        private weak var guardedPresentation: UIPresentationController?
        private weak var originalDelegate: (any UIAdaptivePresentationControllerDelegate)?

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
        }
        func detach() {
            if let presentation = guardedPresentation, presentation.delegate === self {
                presentation.delegate = originalDelegate
                presentation.presentedViewController.isModalInPresentation = false
            }
            guardedPresentation = nil
            originalDelegate = nil
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isBlocked && (originalDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isBlocked { onAttempt() }
            else { originalDelegate?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            originalDelegate?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            originalDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
