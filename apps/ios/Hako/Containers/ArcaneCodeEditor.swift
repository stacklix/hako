import SwiftUI
import UIKit

struct ArcaneCodeEditor: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let saving: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.allowsEditingTextAttributes = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let changedLanguage = coordinator.parent.filename != filename
        coordinator.parent = self
        coordinator.applying = true
        defer { coordinator.applying = false }
        view.isEditable = editable && !saving
        view.isSelectable = !saving
        view.accessibilityLabel = "文件内容：\(filename)"
        if view.text != text {
            view.text = text
            coordinator.highlight(view)
        } else if changedLanguage || coordinator.highlightedText == nil {
            coordinator.highlight(view)
        }
        if view.markedTextRange == nil {
            view.typingAttributes = [.font: Self.font, .foregroundColor: UIColor.label]
        }
    }

    static var font: UIFont {
        UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.work?.cancel()
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ArcaneCodeEditor
        var work: Task<Void, Never>?
        var highlightedText: String?
        var applying = false
        init(_ parent: ArcaneCodeEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !applying else { return }
            parent.text = view.text
            highlight(view, delayed: true)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            // A completed IME composition also needs its final syntax colors.
            if !applying, view.markedTextRange == nil, highlightedText != view.text { highlight(view, delayed: true) }
        }

        func highlight(_ view: UITextView, delayed: Bool = false) {
            work?.cancel()
            guard view.markedTextRange == nil else { return }
            let text = view.text ?? ""
            let language = ArcaneSyntax.language(filename: parent.filename)
            work = Task { @MainActor [weak self, weak view] in
                if delayed {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let tokens = await Task.detached(priority: .userInitiated) { ArcaneSyntax.tokens(text, language: language) }.value
                guard !Task.isCancelled, let self, let view, view.text == text, view.markedTextRange == nil else { return }
                self.apply(tokens, text: text, to: view)
            }
        }

        private func apply(_ tokens: [ArcaneSyntax.Token], text: String, to view: UITextView) {
            applying = true
            defer { applying = false }
            highlightedText = text
            let selection = view.selectedRange
            let offset = view.contentOffset
            let storage = view.textStorage
            let range = NSRange(location: 0, length: storage.length)
            // Attribute-only edits preserve the text, selection and UIKit undo history.
            storage.beginEditing()
            storage.addAttributes([.font: ArcaneCodeEditor.font, .foregroundColor: UIColor.label], range: range)
            for token in tokens {
                storage.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
            }
            storage.endEditing()
            view.selectedRange = selection
            view.setContentOffset(offset, animated: false)
            view.typingAttributes = [.font: ArcaneCodeEditor.font, .foregroundColor: UIColor.label]
        }

        private func color(_ kind: ArcaneSyntax.Kind) -> UIColor {
            switch kind {
            case .comment: return .secondaryLabel
            case .key: return .systemBlue
            case .string: return .systemGreen
            case .literal: return .systemPurple
            case .number: return .systemOrange
            case .variable: return .systemTeal
            }
        }
    }
}
