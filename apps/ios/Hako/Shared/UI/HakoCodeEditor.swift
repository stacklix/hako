import SwiftUI
import UIKit

struct HakoCodeEditor: View {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let saving: Bool
    var active = true
    @StateObject private var keyboard = HakoEditorKeyboardState()

    var body: some View {
        HakoCodeEditorTextView(text: $text, filename: filename, editable: editable, saving: saving, active: active, keyboard: keyboard)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if active && keyboard.focused {
                    HakoEditorKeyboardKeys(state: keyboard, editingEnabled: editable && !saving)
                }
            }
    }
}

private struct HakoCodeEditorTextView: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let saving: Bool
    let active: Bool

    let keyboard: HakoEditorKeyboardState

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HakoCodeEditorView {
        let editor = HakoCodeEditorView()
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
        view.keyboardDismissMode = .onDrag
        view.alwaysBounceVertical = true
        view.allowsEditingTextAttributes = false
        keyboard.textView = view
        let dismissTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissKeyboardOnTap))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = context.coordinator
        editor.addGestureRecognizer(dismissTap)
        let quoteTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.placeCaretInEmptyQuotes(_:)))
        quoteTap.cancelsTouchesInView = false
        quoteTap.delegate = context.coordinator
        view.addGestureRecognizer(quoteTap)
        return editor
    }

    func updateUIView(_ editor: HakoCodeEditorView, context: Context) {
        let view = editor.textView
        let coordinator = context.coordinator
        let changedLanguage = coordinator.parent.filename != filename
        let changedFont = view.font != Self.font
        coordinator.parent = self
        coordinator.applying = true
        defer { coordinator.applying = false }
        if !active && view.isFirstResponder { view.resignFirstResponder() }
        view.isEditable = editable && !saving && active
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

    static func dismantleUIView(_ editor: HakoCodeEditorView, coordinator: Coordinator) {
        coordinator.work?.cancel()
        editor.textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: HakoCodeEditorTextView
        var work: Task<Void, Never>?
        var highlightedText: String?
        var highlightedLanguage: HakoCodeSyntax.Language?
        var applying = false
        weak var editor: HakoCodeEditorView?
        init(_ parent: HakoCodeEditorTextView) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer.view === editor?.textView {
                guard let view = editor?.textView else { return false }
                return touch.tapCount == 1 && view.isEditable && view.markedTextRange == nil
                    && view.selectedRange.length == 0 && !view.isDragging && !view.isDecelerating
            }
            // Keep the text area's native caret, selection handles and edit menu gestures.
            // Only the gutter dismisses the keyboard; the toolbar also has a dismiss button.
            guard let editor, editor.textView.isFirstResponder else { return false }
            return !editor.textView.frame.contains(touch.location(in: editor))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc func dismissKeyboardOnTap() {
            guard let view = editor?.textView else { return }
            // Run after UIKit's caret gesture so it cannot immediately reopen the keyboard.
            DispatchQueue.main.async { [weak view] in _ = view?.resignFirstResponder() }
        }

        @objc func placeCaretInEmptyQuotes(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let view = editor?.textView, view.isEditable,
                  view.markedTextRange == nil, view.selectedRange.length == 0,
                  !view.isDragging, !view.isDecelerating else { return }
            // UIKit's word-based tap placement can skip the insertion position in "".
            // Hit-test the actual glyphs, so wrapped lines and a scrolled editor agree.
            let point = tap.location(in: view)
            let location = CGPoint(x: point.x - view.textContainerInset.left,
                                   y: point.y - view.textContainerInset.top)
            let layout = view.layoutManager
            layout.ensureLayout(for: view.textContainer)
            let offset = layout.characterIndex(for: location, in: view.textContainer,
                                              fractionOfDistanceBetweenInsertionPoints: nil)
            let text = view.text ?? ""
            guard let insertion = HakoEditorCaret.emptyQuoteInsertion(in: text, atUTF16Offset: offset) else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: insertion - 1, length: 2),
                                          actualCharacterRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
            guard bounds.contains(location) else { return }
            // Apply after the native single-tap recognizer. Double taps, selection
            // handles, long presses and IME composition keep their native behavior.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEditable, view.text == text, view.markedTextRange == nil,
                      view.selectedRange.length == 0, !view.isDragging, !view.isDecelerating else { return }
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: insertion, length: 0)
            }
        }

        func textViewDidBeginEditing(_ view: UITextView) { parent.keyboard.focused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.keyboard.focused = false }

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
            let language = HakoCodeSyntax.language(filename: parent.filename)
            guard highlightedText != text || highlightedLanguage != language else { return }
            work = Task { @MainActor [weak self, weak view] in
                if delayed {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let tokens = await Task.detached(priority: .userInitiated) { HakoCodeSyntax.tokens(text, language: language) }.value
                guard !Task.isCancelled, let self, let view, view.text == text,
                      view.markedTextRange == nil, view.selectedRange.length == 0 else { return }
                self.apply(tokens, text: text, language: language, to: view)
            }
        }

        private func apply(_ tokens: [HakoCodeSyntax.Token], text: String, language: HakoCodeSyntax.Language, to view: UITextView) {
            applying = true
            defer { applying = false }
            highlightedText = text
            highlightedLanguage = language
            editor?.applySyntaxColors(tokens)
            view.typingAttributes = [.font: HakoCodeEditorTextView.font, .foregroundColor: UIColor.label]
        }
    }
}

private final class HakoEditorKeyboardState: ObservableObject {
    weak var textView: UITextView?
    @Published var focused = false

    func perform(_ action: String) -> HakoEditorKeyFeedback? {
        guard let view = textView else { return nil }
        if action == "复制全部" {
            guard let text = view.text, !text.isEmpty else {
                return .init(title: "无内容", succeeded: false, announcement: "文件为空，没有可复制的内容")
            }
            UIPasteboard.general.string = text
            return .init(title: "已复制", succeeded: true, announcement: "已复制全部内容")
        }
        if action == "收起键盘" {
            view.resignFirstResponder()
            return nil
        }
        guard view.isEditable else { return nil }
        switch action {
        case "Tab":
            view.unmarkText()
            view.insertText("\t")
            view.scrollRangeToVisible(view.selectedRange)
        case "撤销": view.undoManager?.undo()
        case "重做": view.undoManager?.redo()
        case "粘贴", "覆盖粘贴":
            // Read before selecting: an unavailable or non-text clipboard must not erase the draft.
            guard let replacement = UIPasteboard.general.string, !replacement.isEmpty else {
                return .init(title: "无文本", succeeded: false, announcement: "剪贴板中没有可粘贴的文本")
            }
            view.unmarkText()
            if action == "覆盖粘贴" {
                view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
            }
            view.insertText(replacement)
            if action == "覆盖粘贴" { view.selectedRange = NSRange(location: 0, length: 0) }
            view.scrollRangeToVisible(view.selectedRange)
            return .init(title: action == "覆盖粘贴" ? "已覆盖" : "已粘贴", succeeded: true,
                         announcement: action == "覆盖粘贴" ? "已用剪贴板文本覆盖全部内容，可撤销" : "已粘贴文本")
        default: break
        }
        return nil
    }
}

private struct HakoEditorKeyFeedback {
    let id = UUID()
    let title: String
    let succeeded: Bool
    let announcement: String
}

private struct HakoEditorKeyboardKeys: View {
    @ObservedObject var state: HakoEditorKeyboardState
    let editingEnabled: Bool
    private let keys = ["Tab", "撤销", "重做", "粘贴", "覆盖粘贴", "复制全部", "收起键盘"]
    var body: some View {
        HakoShortcutBar {
            ForEach(keys, id: \.self) { key in
                HakoEditorKeyboardKey(state: state, key: key, editingEnabled: editingEnabled)
            }
        }
    }
}

private struct HakoEditorKeyboardKey: View {
    let state: HakoEditorKeyboardState
    let key: String
    let editingEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback: HakoEditorKeyFeedback?

    private var successTitle: String? {
        switch key {
        case "粘贴": "已粘贴"
        case "覆盖粘贴": "已覆盖"
        case "复制全部": "已复制"
        default: nil
        }
    }
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.25) }

    var body: some View {
        Button {
            guard let result = state.perform(key) else { return }
            withAnimation(animation) { feedback = result }
            UINotificationFeedbackGenerator().notificationOccurred(result.succeeded ? .success : .warning)
            UIAccessibility.post(notification: .announcement, argument: result.announcement)
        } label: {
            ZStack {
                // Reserve the success label's width so nearby shortcuts do not move.
                Text(key).hidden()
                if let successTitle { Label(successTitle, systemImage: "checkmark").hidden() }
                if let feedback {
                    Label(feedback.title, systemImage: feedback.succeeded ? "checkmark" : "exclamationmark")
                        .id(feedback.id)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                } else { Text(key).transition(.opacity) }
            }
        }
        .tint(feedback.map { $0.succeeded ? Color.green : Color.orange } ?? Color.primary)
        .accessibilityLabel(key == "Tab" ? "插入制表符" : key)
        .accessibilityValue(feedback?.announcement ?? "")
        .accessibilityHint(key == "覆盖粘贴" ? "用剪贴板文本替换全部文件内容，可撤销" : "")
        .disabled(key != "复制全部" && key != "收起键盘" && !editingEnabled)
        .task(id: feedback?.id) {
            guard feedback != nil else { return }
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            withAnimation(animation) { feedback = nil }
        }
    }
}

final class HakoCodeEditorView: UIView {
    // Explicitly use TextKit 1 so syntax highlighting and gutter share the same layout.
    let textView: UITextView
    private let syntaxLayout: HakoCodeLayoutManager
    private let gutter = HakoLineNumberGutter()
    private var gutterWidth: NSLayoutConstraint!
    private var gutterDigits = 4

    init() {
        let layout = HakoCodeLayoutManager()
        syntaxLayout = layout
        let storage = NSTextStorage()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        textView = UITextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        gutter.textView = textView
        gutter.isAccessibilityElement = false
        gutter.isUserInteractionEnabled = false
        gutter.backgroundColor = .systemBackground
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
        gutter.lines = HakoEditorLines(textView.text ?? "")
        updateGutterFont()
    }

    func updateGutterFont() {
        let font = HakoCodeEditorTextView.font
        gutter.font = font
        // Reserve space so 9/10, 99/100 and 999/1000 line edits do not rewrap the file.
        // Beyond this reserve, only grow during this editor session to avoid oscillation.
        gutterDigits = max(gutterDigits, String(gutter.lines.starts.count).count)
        let width = ceil((String(repeating: "8", count: gutterDigits) as NSString).size(withAttributes: [.font: font]).width) + 16
        if gutterWidth.constant != width { gutterWidth.constant = width }
        redrawLineNumbers()
    }

    func applySyntaxColors(_ tokens: [HakoCodeSyntax.Token]) {
        let storage = textView.textStorage
        syntaxLayout.updateSyntaxColors {
            storage.beginEditing()
            // Fonts belong to normal text layout. Highlighting changes only display colors.
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: storage.length))
            for token in tokens {
                let color: UIColor
                switch token.kind {
                case .comment: color = .secondaryLabel
                case .key: color = .systemBlue
                case .string: color = .systemGreen
                case .literal: color = .systemPurple
                case .number: color = .systemOrange
                case .variable: color = .systemTeal
                }
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
            }
            storage.endEditing()
        }
    }

    func redrawLineNumbers() { gutter.setNeedsDisplay() }
}

private final class HakoCodeLayoutManager: NSLayoutManager {
    private var updatingSyntaxColors = false

    func updateSyntaxColors(_ update: () -> Void) {
        updatingSyntaxColors = true
        defer { updatingSyntaxColors = false }
        update()
    }

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        // Color-only highlighting must not invalidate glyph layout or trigger UITextView's
        // caret scrolling. Real edits and font changes still follow TextKit's normal path.
        if updatingSyntaxColors, editMask == .editedAttributes {
            invalidateDisplay(forCharacterRange: invalidatedCharRange)
            return
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }
}

private final class HakoLineNumberGutter: UIView {
    weak var textView: UITextView?
    var lines = HakoEditorLines("")
    var font = HakoCodeEditorTextView.font

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
