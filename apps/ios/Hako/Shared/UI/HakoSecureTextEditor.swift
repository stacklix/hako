import SwiftUI
import UIKit

/// A secure editor that wraps long credentials without inserting line breaks into their value.
struct HakoSecureTextEditor: UIViewRepresentable {
    @Binding var text: String
    let isSecure: Bool
    let label: String
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.keyboardType = .asciiCapable
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.writingToolsBehavior = .none
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applying = true
        defer { context.coordinator.applying = false }
        context.coordinator.buffer.synchronize(text: text, isSecure: isSecure, selection: view.selectedRange)
        view.isEditable = enabled
        view.isSelectable = enabled
        view.accessibilityLabel = label
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        if view.font != font { view.font = font }
        context.coordinator.render(in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HakoSecureTextEditor
        var applying = false
        var buffer: HakoSecureTextBuffer

        init(_ parent: HakoSecureTextEditor) {
            self.parent = parent
            buffer = HakoSecureTextBuffer(text: parent.text, isSecure: parent.isSecure)
        }

        func render(in view: UITextView) {
            let wasApplying = applying
            applying = true
            defer { applying = wasApplying }
            if view.isSecureTextEntry != buffer.isSecure {
                // UITextView uses this trait for input privacy, but does not obscure its glyphs.
                view.isSecureTextEntry = buffer.isSecure
                view.undoManager?.removeAllActions()
                if view.isFirstResponder { view.reloadInputViews() }
            }
            let displayed = buffer.displayText
            if view.text != displayed {
                view.text = displayed
                view.invalidateIntrinsicContentSize()
            }
            if view.selectedRange != buffer.selection { view.selectedRange = buffer.selection }
            view.accessibilityValue = buffer.isSecure && !buffer.text.isEmpty ? "已隐藏" : displayed
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applying, buffer.replace(range, with: text) else { return false }
            render(in: view)
            parent.text = buffer.text
            // Never let UIKit insert plaintext into a masked view, even for a single frame.
            return false
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !applying else { return }
            buffer.select(view.selectedRange)
        }

        func textViewDidChange(_ view: UITextView) {
            guard !applying else { return }
            // All edits go through the replacement delegate; displayed bullets are never saved.
            render(in: view)
        }
    }
}
