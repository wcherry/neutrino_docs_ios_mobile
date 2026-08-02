import SwiftUI
import UIKit

// MARK: - MarkdownTextEditor

/// The editor's plain-text editing surface, backed by a `UITextView`.
///
/// SwiftUI's `TextEditor` is deliberately not used. It offers no way to apply per-range attributes
/// (so no syntax highlighting), no access to the caret, and no find interaction — three of Phase
/// 1's editor requirements. It also drops the caret at the end of the document whenever a modified
/// string is written back through its binding.
struct MarkdownTextEditor: UIViewRepresentable {

    @Binding var text: String
    var isEditable: Bool
    /// The editor's font, from `AppSettings`.
    var font: UIFont
    /// Whether to syntax-highlight the source as it is typed.
    var highlightSyntax: Bool
    /// Lets the owning view drive the text view for what surrounds it: undo, redo, and find &
    /// replace in the navigation bar.
    let controller: MarkdownTextEditorController

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
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

        context.coordinator.apply(text: text, to: textView, font: font, highlight: highlightSyntax)
        controller.attach(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.font = font
        context.coordinator.highlightSyntax = highlightSyntax

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
        Coordinator(text: $text, font: font, highlightSyntax: highlightSyntax)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {

        var text: Binding<String>
        var font: UIFont
        var highlightSyntax: Bool

        /// What the last style pass was rendered with, so an unchanged configuration does not
        /// trigger a needless re-highlight on every SwiftUI update.
        private var styledFont: UIFont?
        private var styledHighlight: Bool?

        init(text: Binding<String>, font: UIFont, highlightSyntax: Bool) {
            self.text = text
            self.font = font
            self.highlightSyntax = highlightSyntax
        }

        // MARK: Delegate

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            guard highlightSyntax else { return }
            restyle(textView)
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

// MARK: - MarkdownTextEditorController

/// A handle on the editor's text view for what happens around it: the navigation bar's undo, redo,
/// and find & replace. Held by the owning view so all of those have something to talk to.
final class MarkdownTextEditorController: ObservableObject {

    /// Weak, and nil whenever the editor is not on screen — in Preview mode, for instance, where
    /// the editing actions correctly appear disabled.
    private weak var textView: UITextView?
    private weak var coordinator: MarkdownTextEditor.Coordinator?

    /// Points the controller at the editor it drives. Called as the text view is made and on every
    /// SwiftUI update, since a representable's view may be rebuilt under it.
    func attach(_ textView: UITextView, coordinator: MarkdownTextEditor.Coordinator) {
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
    private func syncTextAfterUndoRedo(_ textView: UITextView) {
        coordinator?.text.wrappedValue = textView.text
        coordinator?.restyle(textView)
    }

    // MARK: - Find & Replace

    func presentFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func presentFindAndReplace() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: true)
    }

    // MARK: - Focus

    func resignFirstResponder() {
        textView?.resignFirstResponder()
    }
}
