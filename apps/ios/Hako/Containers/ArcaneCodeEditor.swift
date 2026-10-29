import SwiftUI
import UIKit

struct ArcaneCodeEditor: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let saving: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ArcaneCodeEditorView {
        let editor = ArcaneCodeEditorView()
        let view = editor.textView
        context.coordinator.editor = editor
        view.delegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 4, bottom: 24, right: 12)
        view.contentInsetAdjustmentBehavior = .never
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.allowsEditingTextAttributes = false
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "收起键盘", style: .done,
                target: view, action: #selector(UIResponder.resignFirstResponder))
        ]
        toolbar.sizeToFit()
        view.inputAccessoryView = toolbar
        return editor
    }

    func updateUIView(_ editor: ArcaneCodeEditorView, context: Context) {
        let view = editor.textView
        let coordinator = context.coordinator
        let changedLanguage = coordinator.parent.filename != filename
        let changedFont = view.font != Self.font
        coordinator.parent = self
        coordinator.applying = true
        defer { coordinator.applying = false }
        view.isEditable = editable && !saving
        view.isSelectable = !saving
        view.accessibilityLabel = "文件内容：\(filename)"
        if changedFont, view.markedTextRange == nil { view.font = Self.font }
        if view.text != text {
            if coordinator.highlightedText != nil {
                // A whole-file paste remains one undoable replacement.
                view.unmarkText()
                if let range = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) {
                    view.replace(range, withText: text)
                }
            } else {
                view.text = text
            }
            view.selectedRange = NSRange(location: 0, length: 0)
            view.setContentOffset(.zero, animated: false)
            editor.updateLineNumbers()
            coordinator.highlight(view)
        } else if changedLanguage || changedFont || coordinator.highlightedText == nil {
            coordinator.highlight(view)
        }
        if view.markedTextRange == nil {
            view.typingAttributes = [.font: Self.font, .foregroundColor: UIColor.label]
        }
        editor.updateGutterFont()
    }

    static var font: UIFont {
        UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    static func dismantleUIView(_ editor: ArcaneCodeEditorView, coordinator: Coordinator) {
        coordinator.work?.cancel()
        editor.textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ArcaneCodeEditor
        var work: Task<Void, Never>?
        var highlightedText: String?
        var applying = false
        weak var editor: ArcaneCodeEditorView?
        init(_ parent: ArcaneCodeEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !applying else { return }
            parent.text = view.text
            editor?.updateLineNumbers()
            highlight(view, delayed: true)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            editor?.redrawLineNumbers()
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
            editor?.redrawLineNumbers()
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

final class ArcaneCodeEditorView: UIView {
    // Explicitly use TextKit 1 so syntax highlighting and gutter share the same layout.
    let textView = UITextView(usingTextLayoutManager: false)
    private let gutter = ArcaneLineNumberGutter()
    private var gutterWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        gutter.textView = textView
        gutter.isAccessibilityElement = false
        gutter.isUserInteractionEnabled = false
        gutter.backgroundColor = .secondarySystemBackground
        for view in [gutter, textView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            textView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        redrawLineNumbers()
    }

    func updateLineNumbers() {
        gutter.lines = ArcaneEditorLines(textView.text ?? "")
        updateGutterFont()
    }

    func updateGutterFont() {
        let font = ArcaneCodeEditor.font
        gutter.font = font
        let digits = String(gutter.lines.starts.count).count
        let width = ceil((String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width) + 16
        if gutterWidth.constant != width { gutterWidth.constant = width }
        redrawLineNumbers()
    }

    func redrawLineNumbers() { gutter.setNeedsDisplay() }
}

private final class ArcaneLineNumberGutter: UIView {
    weak var textView: UITextView?
    var lines = ArcaneEditorLines("")
    var font = ArcaneCodeEditor.font

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layout = textView.layoutManager
        let container = textView.textContainer
        let top = textView.textContainerInset.top - textView.contentOffset.y
        let visible = CGRect(x: 0, y: -top, width: container.size.width, height: bounds.height)
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let offset = layout.characterIndexForGlyph(at: range.location)
            let index = self.lines.index(containingUTF16Offset: offset)
            // Wrapped continuations belong to the same logical file line.
            if self.lines.starts[index] == offset {
                self.drawNumber(index + 1, y: fragment.minY + top, height: fragment.height)
            }
        }
        // TextKit's extra fragment is the empty document or a trailing empty line.
        if lines.starts.last == textView.textStorage.length, layout.extraLineFragmentTextContainer != nil {
            let fragment = layout.extraLineFragmentRect
            drawNumber(lines.starts.count, y: fragment.minY + top, height: fragment.height)
        }
    }

    private func drawNumber(_ number: Int, y: CGFloat, height: CGFloat) {
        guard y + height >= 0, y <= bounds.height else { return }
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: bounds.width - size.width - 8, y: y + (height - font.lineHeight) / 2),
                   withAttributes: attributes)
    }
}
