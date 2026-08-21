import SwiftUI
import UIKit

// MARK: - DocumentTextEditor

/// The document surface, backed by a `UITextView`.
///
/// There is one view of a document and it is the document: a heading is large, a bullet is a
/// bullet, and there is no source behind either of them. What the text view holds is a
/// ``DocumentProjection`` — the tree flattened into styled text, with every character carrying the
/// block it belongs to — and ``DocumentBuilder`` reads it back. The two are inverses, so what is
/// saved is what was edited rather than a translation of it.
///
/// Typing shortcuts are the one place a character means something structural: `# ` still makes a
/// heading, and the characters are consumed as the block changes. See ``DocumentInputRules``.
///
/// SwiftUI's `TextEditor` is deliberately not used. It offers no way to apply per-range attributes,
/// no access to the caret, and no find interaction — three of Phase 1's editor requirements. It
/// also drops the caret at the end of the document whenever a modified string is written back
/// through its binding.
struct DocumentTextEditor: UIViewRepresentable {

    /// The document being edited. The binding is the document itself, not a rendering of it.
    @Binding var document: ProseMirrorNode
    var isEditable: Bool
    /// The editor's base font, from `AppSettings`. Headings and code scale off it.
    var font: UIFont
    /// Phase 2 — Editor Improvements: smart indentation, auto bullets/numbering, bracket closing.
    var inputRules: DocumentInputRules.Options = .default
    /// Whether to dock the style bar above the keyboard while the document is being edited.
    var showsStyleBar: Bool = true
    /// The document-level actions the bar offers, which on a phone is where they all live.
    var barActions = EditorBarActions()
    /// Downloads and decrypts the Drive file a `neutrino-drive:` reference names, which is how a
    /// picture gets on screen — see ``DriveImageReference``. Nil in previews and tests, where a
    /// document holding a reference draws the placeholder.
    var resolveAttachment: ((String) async throws -> Data)?
    /// Lets the owning view drive the text view for what surrounds it: undo, redo, find & replace,
    /// and the formatting toolbar.
    let controller: DocumentEditorController

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> EditorTextView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        // Phase 1 — Editing: "Find", "Replace". UIKit's own find interaction gives both, with the
        // system UI and behaviour people already know.
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .yes
        // Prose, not source: there is no code span or link syntax left for a smart quote to
        // corrupt, so the substitutions people expect in a word processor are on.
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        // Without these the text view asks to be exactly as tall as its text, and a short document
        // leaves the status bar floating in the middle of the screen.
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        textView.onTapImage = { [weak controller] range in
            controller?.selectImage(at: range)
        }

        textView.imageStore.resolveAttachment = resolveAttachment

        textView.onToggleFold = { [weak textView] line in
            guard let textView else { return }
            if textView.foldedStartLines.contains(line) {
                textView.foldedStartLines.remove(line)
            } else {
                textView.foldedStartLines.insert(line)
            }
        }

        context.coordinator.project(document, into: textView, font: font)
        controller.attach(textView, coordinator: context.coordinator)
        context.coordinator.updateStyleBar(on: textView,
                                           controller: controller,
                                           isShown: showsStyleBar,
                                           isEditable: isEditable,
                                           actions: barActions)
        return textView
    }

    func updateUIView(_ textView: EditorTextView, context: Context) {
        context.coordinator.document = $document
        context.coordinator.font = font
        context.coordinator.inputRules = inputRules

        // Only for changes from *outside* the editor — a load, a restored version, or a sync.
        // Re-projecting the document the editor itself just produced would reset the caret to the
        // start of the document mid-sentence.
        if context.coordinator.needsProjection(of: document, font: font) {
            context.coordinator.project(document, into: textView, font: font)
        }

        textView.isEditable = isEditable
        // Re-assigned rather than only set at creation: the closure captures the content service,
        // and a representable is rebuilt whenever the view around it is.
        textView.imageStore.resolveAttachment = resolveAttachment
        controller.attach(textView, coordinator: context.coordinator)
        context.coordinator.updateStyleBar(on: textView,
                                           controller: controller,
                                           isShown: showsStyleBar,
                                           isEditable: isEditable,
                                           actions: barActions)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: $document, font: font, inputRules: inputRules)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {

        var document: Binding<ProseMirrorNode>
        var font: UIFont
        var inputRules: DocumentInputRules.Options

        /// Weak, and set by `attach`: the coordinator reports focus back so the style bar knows
        /// whether the keyboard is carrying it.
        weak var controller: DocumentEditorController?

        /// The document as the editor last projected or produced it.
        ///
        /// What makes an external change recognisable: SwiftUI hands the binding's value back on
        /// every update, and re-projecting the document the editor itself just wrote would move the
        /// caret to the start on every keystroke.
        private var lastKnownDocument: ProseMirrorNode?

        /// What the last projection was rendered with, so an unchanged font does not trigger a
        /// needless re-render on every SwiftUI update.
        private var projectedFont: UIFont?

        /// Hosts the style bar. Retained here because `inputAccessoryView` does not own the view
        /// controller behind it, and a released hosting controller stops updating its SwiftUI.
        private var styleBarHost: UIHostingController<EditorFormattingToolbar>?

        var style: DocumentStyle { DocumentStyle(bodyFont: font) }

        init(document: Binding<ProseMirrorNode>, font: UIFont,
             inputRules: DocumentInputRules.Options = .default) {
            self.document = document
            self.font = font
            self.inputRules = inputRules
        }

        // MARK: Delegate

        /// The single hook every as-you-type rule runs through.
        ///
        /// Each rule returns a whole replacement state or `nil`. Returning `false` here means the
        /// rule already applied its edit; returning `true` lets UIKit insert the text as normal,
        /// which keeps its own undo grouping and autocorrect intact for ordinary typing — and, for
        /// a tree document, keeps the block and mark attributes the new characters inherit.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            let state = EditorDocumentState(text: textView.attributedText, selection: range)

            let updated: EditorDocumentState?
            if replacement == "\n" {
                updated = DocumentInputRules.newline(in: state, style: style, options: inputRules)
            } else if replacement.isEmpty {
                updated = DocumentInputRules.deleteBackward(in: deletionState(range, in: textView),
                                                            style: style,
                                                            options: inputRules)
            } else if replacement.count == 1, let character = replacement.first {
                updated = DocumentInputRules.insert(character, in: state, style: style,
                                                    options: inputRules)
            } else {
                updated = nil
            }

            guard let updated else { return true }
            applyThroughUndo(updated, to: textView)
            return false
        }

        /// Backspace arrives as the single character *before* the caret rather than as the caret
        /// itself; the rules are written against a caret, which is what the deletion collapses to.
        private func deletionState(_ range: NSRange, in textView: UITextView) -> EditorDocumentState {
            guard range.length == 1 else {
                return EditorDocumentState(text: textView.attributedText, selection: range)
            }
            return EditorDocumentState(text: textView.attributedText,
                                       selection: NSRange(location: NSMaxRange(range), length: 0))
        }

        func textViewDidChange(_ textView: UITextView) {
            publish(from: textView)
            refreshChrome(textView)
        }

        /// Focus drives which copy of the style bar is on screen — the one riding the keyboard, or
        /// the one docked at the bottom of the editor.
        func textViewDidBeginEditing(_ textView: UITextView) {
            controller?.setEditing(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            controller?.setEditing(false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // The formatting toolbar's enabled state and its paragraph-style menu depend on where
            // the caret is. Nothing is re-rendered: what a document looks like does not depend on
            // the selection, which is the point.
            NotificationCenter.default.post(name: .documentEditorSelectionChanged, object: textView)
        }

        // MARK: Publishing

        /// Reads the document back out of the text view and pushes it through the binding.
        ///
        /// This runs on every change, which sounds expensive and is not: it is one linear walk of
        /// the runs. The tokenize-and-restyle pass it replaced rebuilt the entire attributed string
        /// on every keystroke, so this is strictly less work than what was here before.
        func publish(from textView: UITextView) {
            let built = DocumentBuilder.document(from: textView.attributedText)
            lastKnownDocument = built
            document.wrappedValue = built
        }

        // MARK: Projection

        /// Whether the document handed back through the binding is one the editor has not seen.
        func needsProjection(of document: ProseMirrorNode, font: UIFont) -> Bool {
            if projectedFont != font { return true }
            return lastKnownDocument != document
        }

        /// Replaces the whole text with a fresh projection. Used for external changes only.
        func project(_ document: ProseMirrorNode, into textView: UITextView, font: UIFont) {
            self.font = font

            let projected = DocumentProjection.attributedString(from: document, style: style)
            let withImages = DocumentImageAttachment.installing(
                in: projected,
                store: (textView as? EditorTextView)?.imageStore
            )

            textView.attributedText = withImages
            textView.selectedRange = NSRange(location: 0, length: 0)
            projectedFont = font
            lastKnownDocument = document

            refreshChrome(textView)
        }

        /// Brings the decorations, the folds and the picture attachments up to date with the text.
        func refreshChrome(_ textView: UITextView) {
            guard let editorView = textView as? EditorTextView else { return }

            // An attachment is presentation, so installing one is not an edit — but a picture that
            // has just been typed in has no attachment yet, and would lay out as a bare object
            // character until something else replaced the text.
            installMissingAttachments(in: editorView)

            editorView.decorationFont = font
            editorView.decorations = DocumentDecorations.decorations(in: editorView.attributedText)
            editorView.foldableRegions = CodeFolding.regions(in: editorView.attributedText)
            editorView.textDidChangeExternally()
        }

        /// Hangs an attachment on any image atom that does not have one yet.
        ///
        /// Done in place on the storage rather than by re-projecting: replacing `attributedText`
        /// would reset the caret, and this runs after every change.
        private func installMissingAttachments(in textView: EditorTextView) {
            let storage = textView.textStorage
            var pending: [(NSRange, DocumentImageAttachment)] = []

            storage.enumerateAttribute(.documentNode,
                                       in: NSRange(location: 0, length: storage.length),
                                       options: []) { value, range, _ in
                guard let atom = value as? DocumentAtom,
                      atom.node.type == DocumentNodeType.image,
                      let source = atom.node.attribute("src")?.stringValue else { return }

                let existing = storage.attribute(.attachment, at: range.location,
                                                 effectiveRange: nil) as? DocumentImageAttachment
                guard existing?.source != source
                        || existing?.attributes != ImageAttributes(proseMirror: atom.node.attrs)
                else { return }

                pending.append((range, DocumentImageAttachment(
                    source: source,
                    attributes: ImageAttributes(proseMirror: atom.node.attrs),
                    store: textView.imageStore
                )))
            }

            guard !pending.isEmpty else { return }
            storage.beginEditing()
            for (range, attachment) in pending {
                storage.addAttribute(.attachment, value: attachment, range: range)
            }
            storage.endEditing()
        }

        // MARK: Applying state

        /// Writes a computed state back into the text view through its own undo manager, so a
        /// rule's edit is a single undoable step like any other.
        func applyThroughUndo(_ state: EditorDocumentState, to textView: UITextView) {
            let withImages = DocumentImageAttachment.installing(
                in: state.text,
                store: (textView as? EditorTextView)?.imageStore
            )

            // `textStorage.replaceCharacters(in:with:)` inside an undo grouping is what registers
            // the change with the text view's own undo manager, unlike assigning `attributedText`.
            let full = NSRange(location: 0, length: textView.textStorage.length)
            textView.textStorage.beginEditing()
            textView.textStorage.replaceCharacters(in: full, with: withImages)
            textView.textStorage.endEditing()

            textView.selectedRange = NSRange(
                location: min(state.selection.location, withImages.length),
                length: min(state.selection.length,
                            max(0, withImages.length - min(state.selection.location, withImages.length)))
            )

            publish(from: textView)
            refreshChrome(textView)
        }

        // MARK: Style bar

        /// Docks the style bar above the keyboard, or takes it away.
        ///
        /// An `inputAccessoryView` rather than anything laid out in SwiftUI: it appears exactly when
        /// the document starts being edited and leaves with the keyboard, animating with it, which
        /// is otherwise a keyboard-frame notification and a pile of arithmetic. The copy that shows
        /// with the keyboard down is `DocEditorView`'s, docked in the layout.
        ///
        /// The root view is rebuilt on every update rather than only created once: the actions close
        /// over `DocEditorView`'s state — whether the document is pinned offline, whether the server
        /// is reachable — and a menu holding last week's closures would act on last week's answer.
        /// SwiftUI keeps the bar's own `@State` across the assignment.
        func updateStyleBar(on textView: UITextView,
                            controller: DocumentEditorController,
                            isShown: Bool,
                            isEditable: Bool,
                            actions: EditorBarActions) {
            guard isShown else {
                guard styleBarHost != nil else { return }
                styleBarHost = nil
                textView.inputAccessoryView = nil
                if textView.isFirstResponder { textView.reloadInputViews() }
                return
            }

            let bar = EditorFormattingToolbar(controller: controller,
                                              isEditable: isEditable,
                                              actions: actions)

            if let host = styleBarHost {
                host.rootView = bar
                return
            }

            let host = UIHostingController(rootView: bar)
            // The width is UIKit's to set; only the height is ours, and it has to match what the
            // bar lays itself out at or the keyboard leaves a gap above or below it.
            host.view.frame = CGRect(x: 0, y: 0,
                                     width: textView.bounds.width,
                                     height: EditorFormattingToolbar.height)
            host.view.autoresizingMask = .flexibleWidth
            host.view.backgroundColor = .clear
            // The bar sits against the keyboard, not against the screen edge: inheriting the
            // window's bottom safe area would pad it away from the keys.
            host.view.insetsLayoutMarginsFromSafeArea = false

            styleBarHost = host
            textView.inputAccessoryView = host.view
            if textView.isFirstResponder { textView.reloadInputViews() }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the editor's selection changes, so the formatting toolbar can update.
    static let documentEditorSelectionChanged = Notification.Name("documentEditorSelectionChanged")
}

// MARK: - DocumentEditorController

/// A handle on the editor's text view for what happens around it: the navigation bar's undo, redo,
/// and find & replace, the formatting toolbar, outline navigation, and the image panel.
///
/// Every editing action goes the same way — read the state out of the text view, hand it to a
/// ``DocumentEditing`` transform, write the result back through the coordinator's undo path. The
/// controller holds no document of its own, so there is nothing here that can fall out of step with
/// what is on screen.
final class DocumentEditorController: ObservableObject {

    /// Weak, and nil whenever the editor is not on screen, where the editing actions correctly
    /// appear disabled.
    private weak var textView: EditorTextView?
    private weak var coordinator: DocumentTextEditor.Coordinator?

    /// Points the controller at the editor it drives. Called as the text view is made and on every
    /// SwiftUI update, since a representable's view may be rebuilt under it.
    func attach(_ textView: EditorTextView, coordinator: DocumentTextEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        coordinator.controller = self
        // A text view that is already first responder when the representable is rebuilt would
        // otherwise leave this reading as not-editing until the next focus change.
        setEditing(textView.isFirstResponder)
    }

    /// Whether the document is being edited, which decides which copy of the style bar is shown:
    /// the one attached to the keyboard, or the one docked at the bottom of the editor.
    @Published private(set) var isEditing = false

    /// The only way this is written, and it compares first.
    ///
    /// `attach` runs from `updateUIView`, and `@Published` announces every assignment whether or
    /// not the value changed. Announcing invalidates the view that is *currently being updated*,
    /// which updates the view, which announces again: an unbounded render loop that freezes the app
    /// on whatever frame it last drew — the opening spinner — and logs nothing, because nothing
    /// failed.
    fileprivate func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
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
        syncAfterUndoRedo(textView)
    }

    func redo() {
        guard let textView, let undoManager = textView.undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        syncAfterUndoRedo(textView)
    }

    /// Undo and redo mutate the text view directly without firing `textViewDidChange`, so the
    /// binding — and therefore autosave — would otherwise never learn the document changed.
    private func syncAfterUndoRedo(_ textView: EditorTextView) {
        coordinator?.publish(from: textView)
        coordinator?.refreshChrome(textView)
    }

    // MARK: - Find & Replace

    func presentFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func presentFindAndReplace() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: true)
    }

    // MARK: - Formatting

    /// The text and selection a command transforms, and the style it is projected with. Both come
    /// from the editor, so a command can never be applied against a stale document.
    private var editing: (state: EditorDocumentState, style: DocumentStyle, view: EditorTextView)? {
        guard let textView, let coordinator else { return nil }
        return (EditorDocumentState(text: textView.attributedText, selection: textView.selectedRange),
                coordinator.style,
                textView)
    }

    var state: EditorDocumentState? { editing?.state }

    var hasSelection: Bool { textView.map { $0.selectedRange.length > 0 } ?? false }

    /// The heading level of the line the caret is on, 0 for body text — what the style bar shows as
    /// the current paragraph style.
    ///
    /// Read from the caret's line rather than the whole selection: a selection spanning a heading
    /// and a paragraph has no one style, and the line the caret is in is the one the user is
    /// looking at.
    var paragraphHeadingLevel: Int {
        guard let state else { return 0 }
        return DocumentEditing.headingLevel(of: state.caretBlock)
    }

    /// The alignment of the line the caret is on — what the style bar's alignment button shows.
    var paragraphAlignment: DocumentAlignment {
        guard let state else { return .left }
        return DocumentEditing.alignment(of: state.caretBlock)
    }

    /// Whether the selection already carries a mark, so the toolbar's toggles can show as active.
    func isActive(_ command: DocumentEditingCommand) -> Bool {
        guard let state, let type = command.markType else { return false }
        return DocumentEditing.allCharacters(in: state, carry: type)
    }

    /// Applies a formatting command.
    func apply(_ command: DocumentEditingCommand) {
        guard let editing else { return }
        write(command.apply(to: editing.state, style: editing.style))
    }

    /// Aligns every block the selection touches.
    func setAlignment(_ alignment: DocumentAlignment) {
        guard let editing else { return }
        write(DocumentEditing.setAlignment(editing.state, to: alignment, style: editing.style))
    }

    /// Puts a link on the selection, or takes the one that is there off.
    func setLink(href: String) {
        guard let editing else { return }
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        write(trimmed.isEmpty
              ? DocumentEditing.removeLink(editing.state, style: editing.style)
              : DocumentEditing.setLink(editing.state, href: trimmed, style: editing.style))
    }

    /// Tab / Shift-Tab — nests a list item under the one above it, or lifts it back out.
    func indent(outdent: Bool = false) {
        guard let editing else { return }
        write(DocumentEditing.indent(editing.state, outdent: outdent, style: editing.style),
              keepingKeyboard: false)
    }

    /// Writes a computed state back through the coordinator's undo path.
    ///
    /// The keyboard is kept up by default: the point of the toolbar is to carry on typing
    /// afterwards, and a command that dropped focus would take the bar off screen with it.
    private func write(_ state: EditorDocumentState, keepingKeyboard: Bool = true) {
        guard let textView, let coordinator else { return }
        coordinator.applyThroughUndo(state, to: textView)
        if keepingKeyboard { textView.becomeFirstResponder() }
    }

    // MARK: - Images

    /// The picture whose properties the user is looking at, set by tapping it.
    ///
    /// Held here rather than passed straight to a callback because the panel is SwiftUI and the tap
    /// arrives in UIKit; this is the one place both sides can see.
    @Published var selectedImage: EditorImageSelection?

    /// Reads the image atom at `range` and opens the properties panel on it.
    func selectImage(at range: NSRange) {
        guard let textView, range.length == 1, range.location < textView.textStorage.length,
              let atom = textView.textStorage.attribute(.documentNode, at: range.location,
                                                        effectiveRange: nil) as? DocumentAtom,
              atom.node.type == DocumentNodeType.image else { return }
        selectedImage = EditorImageSelection(range: range, node: atom.node)
    }

    /// Writes an image the insert-image sheet resolved into the document.
    func insertImage(alt: String, source: String) {
        guard let editing else { return }
        let node = EditorImageSelection.node(source: source, alt: alt, title: nil, attributes: .none)
        write(DocumentEditing.insertAtom(node, in: editing.state, style: editing.style))
    }

    /// Replaces the tapped picture with an edited copy of itself.
    ///
    /// The range is the one the tap reported, so it is checked against the document as it is now: a
    /// sync or an undo could have moved the picture out from under the open panel, and rewriting
    /// the wrong range would corrupt the document rather than fail.
    func updateSelectedImage(_ image: EditorImageDescriptor) {
        guard let editing, let selection = selectedImage,
              stillHolds(selection, in: editing.state) else { return }

        write(DocumentEditing.replaceAtom(editing.state,
                                          at: selection.range,
                                          with: selection.node(for: image),
                                          style: editing.style),
              keepingKeyboard: false)
    }

    func removeSelectedImage() {
        guard let editing, let selection = selectedImage,
              stillHolds(selection, in: editing.state) else { return }

        write(DocumentEditing.removeAtom(editing.state, at: selection.range, style: editing.style),
              keepingKeyboard: false)
    }

    /// Whether the document still has that picture where the panel was opened on it.
    private func stillHolds(_ selection: EditorImageSelection, in state: EditorDocumentState) -> Bool {
        guard selection.range.location >= 0, NSMaxRange(selection.range) <= state.length else {
            return false
        }
        let found = state.text.attribute(.documentNode, at: selection.range.location,
                                         effectiveRange: nil) as? DocumentAtom
        return found?.node == selection.node
    }

    // MARK: - Navigation

    /// Moves the caret to a heading and scrolls it into view.
    func moveCaret(toCharacterOffset offset: Int) {
        guard let textView else { return }
        let length = textView.textStorage.length
        let target = NSRange(location: min(max(0, offset), length), length: 0)
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
    }

    // MARK: - Folding

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

// MARK: - EditorImageSelection

/// The picture the properties panel is open on: which node, and where in the text it stands.
///
/// The whole node is carried rather than the attributes this app understands, so an image node
/// holding something a newer web release added is written back with that attribute intact.
struct EditorImageSelection: Identifiable {

    let range: NSRange
    let node: ProseMirrorNode

    /// Where it starts, which is unique within a document and stable while the panel is open.
    var id: Int { range.location }

    var source: String { node.attribute("src")?.stringValue ?? "" }
    var attributes: ImageAttributes { ImageAttributes(proseMirror: node.attrs) }

    /// The image as the panel edits it.
    var descriptor: EditorImageDescriptor {
        EditorImageDescriptor(alt: node.attribute("alt")?.stringValue ?? "",
                              source: source,
                              title: node.attribute("title")?.stringValue,
                              attributes: attributes)
    }

    /// This picture with the panel's edits on it, ready to be written back over the old node.
    func node(for image: EditorImageDescriptor) -> ProseMirrorNode {
        Self.node(source: image.source, alt: image.alt, title: image.title,
                  attributes: image.attributes)
    }

    /// An image node, carrying only the attributes that are actually set — the web's defaults are
    /// null, and an unstyled picture should arrive there as an unstyled node.
    static func node(source: String, alt: String, title: String?,
                     attributes: ImageAttributes) -> ProseMirrorNode {
        var attrs = attributes.proseMirrorAttributes
        attrs["src"] = .string(source)
        if !alt.isEmpty { attrs["alt"] = .string(alt) }
        if let title, !title.isEmpty { attrs["title"] = .string(title) }
        return ProseMirrorNode(type: DocumentNodeType.image, attrs: attrs)
    }
}
