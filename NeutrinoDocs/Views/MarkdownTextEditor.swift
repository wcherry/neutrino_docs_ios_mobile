import SwiftUI
import UIKit

// MARK: - MarkdownTextEditor

/// The editor's plain-text editing surface, backed by a `UITextView`.
///
/// SwiftUI's `TextEditor` is deliberately not used. It offers no way to apply per-range attributes
/// (so no syntax highlighting), no access to the caret, and no find interaction — three of Phase
/// 1's editor requirements. It also drops the caret at the end of the document whenever a modified
/// string is written back through its binding.
///
/// Phase 2 adds the gutter (line numbers, code folding) and the smart-typing behaviours, which are
/// applied through `shouldChangeTextIn` so a single rule can rewrite an edit before it lands.
struct MarkdownTextEditor: UIViewRepresentable {

    @Binding var text: String
    var isEditable: Bool
    /// The editor's font, from `AppSettings`.
    var font: UIFont
    /// Whether to syntax-highlight the source as it is typed.
    var highlightSyntax: Bool
    /// Phase 2 — Editor Improvements, "Line numbers".
    var showsLineNumbers: Bool = true
    /// Phase 2 — Editor Improvements: smart indentation, auto bullets/numbering, bracket closing.
    var smartTyping: SmartTypingBehavior.Options = .default
    /// Lets the owning view drive the text view for what surrounds it: undo, redo, find & replace,
    /// and the formatting toolbar.
    let controller: MarkdownTextEditorController

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> LineNumberTextView {
        let textView = LineNumberTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        // Phase 1 — Editing: "Find", "Replace". UIKit's own find interaction gives both, with the
        // system UI and behaviour people already know.
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .yes
        // Markdown is source text: smart quotes and dashes would silently corrupt code spans and
        // link syntax as they are typed.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        // Without these the text view asks to be exactly as tall as its text, and a short document
        // leaves the status bar floating in the middle of the screen.
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        textView.showsLineNumbers = showsLineNumbers
        textView.onToggleFold = { [weak textView] line in
            guard let textView else { return }
            if textView.foldedStartLines.contains(line) {
                textView.foldedStartLines.remove(line)
            } else {
                textView.foldedStartLines.insert(line)
            }
        }

        context.coordinator.apply(text: text, to: textView, font: font, highlight: highlightSyntax)
        controller.attach(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: LineNumberTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.font = font
        context.coordinator.highlightSyntax = highlightSyntax
        context.coordinator.smartTyping = smartTyping

        if textView.showsLineNumbers != showsLineNumbers {
            textView.showsLineNumbers = showsLineNumbers
        }

        // Only for changes from *outside* the editor — a load, a restored version, or a sync.
        // Re-assigning the same string would still reset the caret to the end mid-sentence.
        if textView.text != text {
            context.coordinator.apply(text: text, to: textView, font: font, highlight: highlightSyntax)
        } else if context.coordinator.needsRestyle(font: font, highlight: highlightSyntax) {
            // The font or the highlighting setting changed under unchanged text.
            context.coordinator.restyle(textView)
        }

        textView.isEditable = isEditable
        controller.attach(textView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, font: font, highlightSyntax: highlightSyntax,
                    smartTyping: smartTyping)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {

        var text: Binding<String>
        var font: UIFont
        var highlightSyntax: Bool
        var smartTyping: SmartTypingBehavior.Options

        /// What the last style pass was rendered with, so an unchanged configuration does not
        /// trigger a needless re-highlight on every SwiftUI update.
        private var styledFont: UIFont?
        private var styledHighlight: Bool?

        init(text: Binding<String>, font: UIFont, highlightSyntax: Bool,
             smartTyping: SmartTypingBehavior.Options = .default) {
            self.text = text
            self.font = font
            self.highlightSyntax = highlightSyntax
            self.smartTyping = smartTyping
        }

        // MARK: Delegate

        /// The single hook every Phase 2 smart-typing rule runs through.
        ///
        /// Each rule returns a whole replacement `EditorTextState` or `nil`. Returning `false` here
        /// means the rule already applied its edit; returning `true` lets UIKit insert the text as
        /// normal, which keeps its own undo grouping and autocorrect intact for ordinary typing.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            let state = EditorTextState(text: textView.text, selection: range)

            let updated: EditorTextState?
            if replacement == "\n" {
                updated = SmartTypingBehavior.newline(in: state, options: smartTyping)
            } else if replacement.isEmpty {
                updated = SmartTypingBehavior.deleteBackward(in: state, options: smartTyping)
            } else if replacement.count == 1, let character = replacement.first {
                updated = SmartTypingBehavior.insert(character, in: state, options: smartTyping)
            } else {
                updated = nil
            }

            guard let updated else { return true }
            applyThroughUndo(updated, to: textView)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? LineNumberTextView)?.textDidChangeExternally()
            guard highlightSyntax else { return }
            restyle(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // The formatting toolbar's enabled state depends on whether there is a selection.
            NotificationCenter.default.post(name: .markdownEditorSelectionChanged, object: textView)
        }

        // MARK: Applying state

        /// Writes a computed state back into the text view through its own undo manager, so a
        /// smart-typing edit is a single undoable step like any other.
        func applyThroughUndo(_ state: EditorTextState, to textView: UITextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: 0),
                  let end = textView.position(from: start, offset: (textView.text as NSString).length),
                  let fullRange = textView.textRange(from: start, to: end) else {
                textView.text = state.text
                textView.selectedRange = state.selection
                syncAfterProgrammaticChange(textView)
                return
            }

            // `replace(_:withText:)` registers with the text view's undo manager, unlike assigning
            // `text` directly.
            textView.replace(fullRange, withText: state.text)
            textView.selectedRange = state.selection
            syncAfterProgrammaticChange(textView)
        }

        private func syncAfterProgrammaticChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? LineNumberTextView)?.textDidChangeExternally()
            if highlightSyntax { restyle(textView) }
        }

        // MARK: Styling

        func needsRestyle(font: UIFont, highlight: Bool) -> Bool {
            styledFont != font || styledHighlight != highlight
        }

        /// Replaces the whole text and styles it. Used for external changes only.
        func apply(text newText: String, to textView: UITextView, font: UIFont, highlight: Bool) {
            self.font = font
            self.highlightSyntax = highlight
            textView.attributedText = Self.styled(newText, font: font, highlight: highlight)
            styledFont = font
            styledHighlight = highlight
            if let lineNumbered = textView as? LineNumberTextView {
                lineNumbered.foldableRegions = CodeFolding.regions(in: newText)
                lineNumbered.textDidChangeExternally()
            }
        }

        /// Re-applies attributes to the text already in the view, preserving the selection.
        ///
        /// Assigning `attributedText` moves the caret to the end, which is unusable while typing —
        /// so the selection is captured and restored around the assignment. `scrollRangeToVisible`
        /// is deliberately not called: the text view is already showing the caret, and forcing a
        /// scroll on every keystroke fights the user during momentum scrolling.
        func restyle(_ textView: UITextView) {
            let selection = textView.selectedRange
            let styled = Self.styled(textView.text, font: font, highlight: highlightSyntax)
            textView.attributedText = styled
            textView.selectedRange = NSRange(
                location: min(selection.location, styled.length),
                length: min(selection.length, max(0, styled.length - min(selection.location, styled.length)))
            )
            styledFont = font
            styledHighlight = highlightSyntax

            if let lineNumbered = textView as? LineNumberTextView {
                // Folding regions move as the document is edited.
                lineNumbered.foldableRegions = CodeFolding.regions(in: textView.text)
            }
        }

        private static func styled(_ text: String, font: UIFont, highlight: Bool) -> NSAttributedString {
            guard highlight else {
                return NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label,
                ])
            }
            return MarkdownSyntaxHighlighter.attributedString(for: text, baseFont: font)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the editor's selection changes, so the formatting toolbar can update.
    static let markdownEditorSelectionChanged = Notification.Name("markdownEditorSelectionChanged")
}

// MARK: - MarkdownTextEditorController

/// A handle on the editor's text view for what happens around it: the navigation bar's undo, redo,
/// and find & replace, plus Phase 2's formatting toolbar and outline navigation.
final class MarkdownTextEditorController: ObservableObject {

    /// Weak, and nil whenever the editor is not on screen — in Preview mode, for instance, where
    /// the editing actions correctly appear disabled.
    private weak var textView: LineNumberTextView?
    private weak var coordinator: MarkdownTextEditor.Coordinator?

    /// Points the controller at the editor it drives. Called as the text view is made and on every
    /// SwiftUI update, since a representable's view may be rebuilt under it.
    func attach(_ textView: LineNumberTextView, coordinator: MarkdownTextEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    /// True when an editor is attached — what the toolbar's enabled state hangs on.
    var isAttached: Bool { textView != nil }

    // MARK: - Undo / Redo

    /// The text view's own undo manager: the one typing registers with while it is first responder,
    /// which is *not* the same object as SwiftUI's `\.undoManager`.
    var undoManager: UndoManager? { textView?.undoManager }

    var canUndo: Bool { textView?.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView?.undoManager?.canRedo ?? false }

    func undo() {
        guard let textView, let undoManager = textView.undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        syncTextAfterUndoRedo(textView)
    }

    func redo() {
        guard let textView, let undoManager = textView.undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        syncTextAfterUndoRedo(textView)
    }

    /// Undo and redo mutate the text view directly without firing `textViewDidChange`, so the
    /// SwiftUI binding — and therefore autosave — would otherwise never learn the text changed.
    private func syncTextAfterUndoRedo(_ textView: LineNumberTextView) {
        coordinator?.text.wrappedValue = textView.text
        textView.textDidChangeExternally()
        coordinator?.restyle(textView)
    }

    // MARK: - Find & Replace

    func presentFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func presentFindAndReplace() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: true)
    }

    // MARK: - Formatting (Phase 2)

    /// The current text and selection, for a command to transform.
    var state: EditorTextState? {
        guard let textView else { return nil }
        return EditorTextState(text: textView.text, selection: textView.selectedRange)
    }

    var hasSelection: Bool {
        guard let textView else { return false }
        return textView.selectedRange.length > 0
    }

    /// Applies a formatting command — Phase 2 — Formatting Toolbar.
    func apply(_ command: MarkdownEditingCommand) {
        guard let textView, let coordinator, let state else { return }
        let updated = command.apply(to: state)
        coordinator.applyThroughUndo(updated, to: textView)
        // Keep the keyboard up: the point of the toolbar is to carry on typing afterwards.
        textView.becomeFirstResponder()
    }

    /// Tab / Shift-Tab — Phase 2 — Editor Improvements, "Smart indentation".
    func indent(outdent: Bool = false) {
        guard let textView, let coordinator, let state else { return }
        let updated = SmartTypingBehavior.indent(state, outdent: outdent)
        coordinator.applyThroughUndo(updated, to: textView)
    }

    // MARK: - Navigation (Phase 2)

    /// Moves the caret to a heading and scrolls it into view — Phase 2 — Document Outline,
    /// "Heading navigation".
    func moveCaret(toCharacterOffset offset: Int) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        let target = NSRange(location: min(max(0, offset), length), length: 0)
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
    }

    // MARK: - Folding (Phase 2)

    var foldableRegions: [FoldableRegion] { textView?.foldableRegions ?? [] }

    var foldedStartLines: Set<Int> {
        get { textView?.foldedStartLines ?? [] }
        set { textView?.foldedStartLines = newValue }
    }

    func foldAll() {
        guard let textView else { return }
        textView.foldedStartLines = Set(textView.foldableRegions.map(\.startLine))
    }

    func unfoldAll() {
        textView?.foldedStartLines = []
    }

    // MARK: - Focus

    func resignFirstResponder() {
        textView?.resignFirstResponder()
    }
}
