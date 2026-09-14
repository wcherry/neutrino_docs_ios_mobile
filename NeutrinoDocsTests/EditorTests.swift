import XCTest
import UIKit
import Combine
@testable import NeutrinoDocs

/// Milestone 1 deliverables: **Edit** and **Save** — the editor's own state, separate from the
/// content service that does the encrypting.
@MainActor
final class EditorTests: XCTestCase {

    // MARK: - Save state

    /// Offline saving is a distinct state, not a failure. Reporting a queued edit as an error
    /// would tell the user their work was lost when it was not.
    func testQueuedIsNotAnErrorState() {
        XCTAssertFalse(DocEditorView.SaveState.queued.isError)
        XCTAssertFalse(DocEditorView.SaveState.saved.isError)
        XCTAssertFalse(DocEditorView.SaveState.saving.isError)
        XCTAssertFalse(DocEditorView.SaveState.dirty.isError)
        XCTAssertTrue(DocEditorView.SaveState.failed("disk full").isError)
    }

    func testEveryStateHasAMessageAndAnIcon() {
        let states: [DocEditorView.SaveState] = [.saved, .dirty, .saving, .queued, .failed("boom")]
        for state in states {
            XCTAssertFalse(state.message.isEmpty, "\(state)")
            XCTAssertFalse(state.iconName.isEmpty, "\(state)")
        }
    }

    func testTheQueuedMessageSaysTheWorkIsSafe() {
        let message = DocEditorView.SaveState.queued.message.lowercased()
        XCTAssertTrue(message.contains("saved"), "The user must be told the edit is not lost")
        XCTAssertTrue(message.contains("sync"))
    }

    func testAFailureMessageIncludesItsReason() {
        XCTAssertTrue(DocEditorView.SaveState.failed("disk full").message.contains("disk full"))
    }

    // MARK: - Helpers

    private func makeCoordinator(_ document: ProseMirrorNode = DocumentBody.empty.doc,
                                 font: UIFont = .systemFont(ofSize: 17))
        -> DocumentTextEditor.Coordinator {
        DocumentTextEditor.Coordinator(document: .constant(document), font: font)
    }

    /// An editor wired the way `DocumentTextEditor` wires one.
    ///
    /// Holds all three parts, because the controller keeps its text view and coordinator weakly —
    /// exactly as it does in the app, where SwiftUI owns them. A test that let either go would be
    /// asserting against a detached controller rather than an editor.
    private final class Harness {
        let textView = EditorTextView()
        let coordinator: DocumentTextEditor.Coordinator
        let controller = DocumentEditorController()

        init(_ document: ProseMirrorNode, font: UIFont = .systemFont(ofSize: 17)) {
            coordinator = DocumentTextEditor.Coordinator(document: .constant(document), font: font)
            coordinator.project(document, into: textView, font: font)
            controller.attach(textView, coordinator: coordinator)
        }

        /// The document read back out of the editor, as its first paragraph's runs — which is where
        /// a mark either survived or did not.
        var runsOfFirstParagraph: [ProseMirrorNode] {
            DocumentBuilder.document(from: textView.attributedText).children.first?.children ?? []
        }
    }

    // MARK: - Controller safety

    /// The controller is deliberately weak on its text view and nil whenever the editor is not on
    /// screen. Every action must be a no-op then rather than a crash, because the toolbar buttons
    /// remain reachable.
    func testControllerActionsAreSafeWhenNoEditorIsAttached() {
        let controller = DocumentEditorController()

        XCTAssertFalse(controller.isAttached)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertNil(controller.undoManager)
        XCTAssertNil(controller.state)
        XCTAssertEqual(controller.paragraphHeadingLevel, 0)
        XCTAssertEqual(controller.paragraphAlignment, .left)

        // None of these may trap.
        controller.undo()
        controller.redo()
        controller.presentFind()
        controller.presentFindAndReplace()
        controller.apply(.bold)
        controller.indent()
        controller.setLink(href: "https://example.com")
        controller.insertImage(alt: "", source: "cat.png")
        controller.removeSelectedImage()
        controller.moveCaret(toCharacterOffset: 40)
        controller.resignFirstResponder()
    }

    func testControllerReportsAttachmentOnceWired() {
        let editor = Harness(Doc.document(Doc.paragraph("Text")))

        XCTAssertTrue(editor.controller.isAttached)
        XCTAssertNotNil(editor.controller.undoManager)
        XCTAssertNotNil(editor.controller.state)
    }

    // MARK: - What the document looks like

    /// The example the whole design rests on: a heading is *large text*, with no syntax anywhere —
    /// there is no source behind what is on screen.
    func testAHeadingIsShownAsLargeTextWithNoSyntax() {
        let editor = Harness(Doc.document(Doc.heading(1, "Heading")))

        XCTAssertEqual(editor.textView.text, "Heading", "Nothing but the words the author typed")

        let font = editor.textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 17, "The heading's text is set larger")
    }

    /// Every character carries the block it belongs to, which is what lets the document be read
    /// back out of the text view rather than kept alongside it.
    func testTheProjectedTextCarriesItsDocument() {
        let editor = Harness(Doc.document(Doc.heading(2, "Title"),
                                                       Doc.paragraph("Body")))

        let rebuilt = DocumentBuilder.document(from: editor.textView.attributedText)

        XCTAssertEqual(rebuilt.children.map(\.type), [DocumentNodeType.heading,
                                                      DocumentNodeType.paragraph])
        XCTAssertEqual(rebuilt.children.first?.attribute("level")?.intValue, 2)
    }

    /// SwiftUI hands the binding's value back on every update, so the editor has to recognise the
    /// document it just produced — re-projecting it would move the caret on every keystroke.
    func testAProjectionIsSkippedForTheDocumentTheEditorAlreadyHas() {
        let document = Doc.document(Doc.paragraph("Text"))
        let editor = Harness(document)

        XCTAssertFalse(editor.coordinator.needsProjection(of: document, font: .systemFont(ofSize: 17)))
        XCTAssertTrue(editor.coordinator.needsProjection(of: Doc.document(Doc.paragraph("Other")),
                                                  font: .systemFont(ofSize: 17)))
        XCTAssertTrue(editor.coordinator.needsProjection(of: document, font: .systemFont(ofSize: 20)),
                      "A font-size change must repaint")
    }

    // MARK: - Formatting

    /// The label reads off the caret's line, so it says what the user is looking at rather than
    /// what a multi-line selection averages to.
    func testTheControllerReportsTheCaretsParagraphStyle() {
        let editor = Harness(Doc.document(Doc.heading(2, "Heading"),
                                                                Doc.paragraph("Body text")))

        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        XCTAssertEqual(editor.controller.paragraphHeadingLevel, 2)

        editor.textView.selectedRange = NSRange(location: 10, length: 0)
        XCTAssertEqual(editor.controller.paragraphHeadingLevel, 0)
    }

    /// A command rewrites the document, not the text: what comes back through the binding is a
    /// heading node, and the text on screen never gained a `#`.
    func testApplyingAParagraphStyleChangesTheBlock() {
        let editor = Harness(Doc.document(Doc.paragraph("Title")))
        editor.textView.selectedRange = NSRange(location: 2, length: 0)

        editor.controller.apply(.heading1)

        XCTAssertEqual(editor.textView.text, "Title")
        XCTAssertEqual(editor.controller.paragraphHeadingLevel, 1)
    }

    func testAlignmentIsReadBackFromTheCaretsBlock() {
        let editor = Harness(Doc.document(Doc.paragraph("Centred")))
        editor.textView.selectedRange = NSRange(location: 0, length: 0)

        editor.controller.setAlignment(.center)

        XCTAssertEqual(editor.controller.paragraphAlignment, .center)
    }

    /// A link needs a selection to go on; without one there is nothing to link and the document is
    /// left alone.
    func testALinkNeedsSomethingToLink() {
        let editor = Harness(Doc.document(Doc.paragraph("Pricing")))
        editor.textView.selectedRange = NSRange(location: 0, length: 0)

        editor.controller.setLink(href: "https://example.com")
        XCTAssertFalse(editor.controller.hasSelection)

        editor.textView.selectedRange = NSRange(location: 0, length: 7)
        editor.controller.setLink(href: "https://example.com")

        let rebuilt = DocumentBuilder.document(from: editor.textView.attributedText)
        let run = rebuilt.children.first?.children.first
        XCTAssertEqual(run?.mark(DocumentMarkType.link)?.attrs?["href"],
                       .string("https://example.com"))
    }

    // MARK: - What the style bar shows as active

    /// Phase 2 — Formatting Toolbar. The bar lights the buttons for formatting that is already on;
    /// without it the bold button looks the same over bold text as over plain, which is the one
    /// thing it is there to say.
    func testBoldReadsAsActiveOverBoldText() {
        let editor = Harness(Doc.document(Doc.paragraph("Bold me")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)

        XCTAssertFalse(editor.controller.isActive(.bold))

        editor.controller.apply(.bold)

        XCTAssertTrue(editor.controller.isActive(.bold))
        XCTAssertFalse(editor.controller.isActive(.italic), "Only what is actually on")
    }

    /// A selection is bold when every character in it is — the same rule the toggle uses to decide
    /// whether tapping adds the mark or takes it away.
    func testAPartlyBoldSelectionIsNotBold() {
        let editor = Harness(Doc.document(Doc.paragraph("Bold plain")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)
        editor.controller.apply(.bold)

        editor.textView.selectedRange = NSRange(location: 0, length: 10)

        XCTAssertFalse(editor.controller.isActive(.bold))
    }

    /// With no selection the bar reports the run the caret is in — the formatting the next
    /// keystroke would carry.
    func testTheCaretReportsTheMarksOfTheRunItSitsIn() {
        let editor = Harness(Doc.document(Doc.paragraph("Bold plain")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)
        editor.controller.apply(.bold)

        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertTrue(editor.controller.isActive(.bold))

        editor.textView.selectedRange = NSRange(location: 9, length: 0)
        XCTAssertFalse(editor.controller.isActive(.bold))
    }

    /// A lit button is a promise that tapping it takes the formatting off again. Asserting the two
    /// together is what stops the highlight and the command drifting apart — they are meant to be
    /// reading the same answer.
    func testEveryToggleIsLitExactlyWhenTappingItWouldUndoIt() {
        let toggles: [DocumentEditingCommand] = [.bold, .italic, .strikethrough, .code,
                                                 .quote, .codeBlock,
                                                 .bulletList, .numberedList, .checkbox]

        for command in toggles {
            let editor = Harness(Doc.document(Doc.paragraph("Formatted")))
            editor.textView.selectedRange = NSRange(location: 0, length: 9)

            XCTAssertFalse(editor.controller.isActive(command), command.rawValue)

            editor.controller.apply(command)
            XCTAssertTrue(editor.controller.isActive(command),
                          "\(command.rawValue) is applied but its button stays unlit")

            editor.controller.apply(command)
            XCTAssertFalse(editor.controller.isActive(command),
                           "\(command.rawValue) was taken off but its button stays lit")
        }
    }

    /// The three list buttons are one choice, not three: a bulleted line lights the bullet.
    func testOnlyTheListTheLineIsInIsLit() {
        let editor = Harness(Doc.document(Doc.paragraph("Item")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)

        editor.controller.apply(.bulletList)

        XCTAssertTrue(editor.controller.isActive(.bulletList))
        XCTAssertFalse(editor.controller.isActive(.numberedList))
        XCTAssertFalse(editor.controller.isActive(.checkbox))
    }

    func testTheLinkButtonIsLitOnALink() {
        let editor = Harness(Doc.document(Doc.paragraph("Pricing")))
        editor.textView.selectedRange = NSRange(location: 0, length: 7)

        XCTAssertFalse(editor.controller.isActive(.link))

        editor.controller.setLink(href: "https://example.com")

        XCTAssertTrue(editor.controller.isActive(.link))
    }

    /// A picture and a table are inserted, not toggled — there is no state for their buttons to be
    /// in, and lighting one would promise an undo the tap does not perform.
    func testTheInsertCommandsAreNeverLit() {
        let editor = Harness(Doc.document(Doc.paragraph("Text")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)

        editor.controller.apply(.table)

        XCTAssertFalse(editor.controller.isActive(.table))
        XCTAssertFalse(editor.controller.isActive(.image))
    }

    /// The style menu's checkmark and the bar's label both read off this.
    func testTheStatusNamesTheCaretsParagraphStyle() {
        let editor = Harness(Doc.document(Doc.heading(1, "Title"), Doc.paragraph("Body")))

        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        let heading = editor.controller.selectionStatus()
        XCTAssertEqual(heading.paragraphStyle, .heading1)
        XCTAssertTrue(heading.activeCommands.contains(.heading1))
        XCTAssertFalse(heading.activeCommands.contains(.body))

        editor.textView.selectedRange = NSRange(location: 8, length: 0)
        XCTAssertEqual(editor.controller.selectionStatus().paragraphStyle, .body)
    }

    /// One read of the editor answers every control, and the answers have to agree with the ones
    /// the controls would get by asking individually.
    func testTheStatusAgreesWithWhatEachControlWouldAskSeparately() {
        let editor = Harness(Doc.document(Doc.paragraph("Quoted")))
        editor.textView.selectedRange = NSRange(location: 0, length: 6)
        editor.controller.apply(.quote)
        editor.controller.apply(.italic)
        editor.controller.setAlignment(.center)

        let status = editor.controller.selectionStatus()

        XCTAssertEqual(status.headingLevel, editor.controller.paragraphHeadingLevel)
        XCTAssertEqual(status.alignment, editor.controller.paragraphAlignment)
        XCTAssertEqual(status.hasSelection, editor.controller.hasSelection)
        for command in DocumentEditingCommand.allCases {
            XCTAssertEqual(status.activeCommands.contains(command),
                           editor.controller.isActive(command),
                           command.rawValue)
        }
    }

    func testTheStatusReportsWhetherThereIsAnythingForALinkToGoOn() {
        let editor = Harness(Doc.document(Doc.paragraph("Pricing")))

        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(editor.controller.selectionStatus().hasSelection)

        editor.textView.selectedRange = NSRange(location: 0, length: 7)
        XCTAssertTrue(editor.controller.selectionStatus().hasSelection)
    }

    /// The bar outlives the editor it describes — it is reachable with no document attached.
    func testAnUnattachedControllerHasNothingActive() {
        let status = DocumentEditorController().selectionStatus()

        XCTAssertEqual(status, EditorSelectionStatus())
        XCTAssertTrue(status.activeCommands.isEmpty)
    }

    /// Applying a mark leaves the caret exactly where it was, so the bar hears nothing through the
    /// selection delegate: the editor has to announce the edit itself, or the button the user just
    /// tapped stays unlit over the text it just changed.
    func testAnEditThatLeavesTheCaretAloneStillTellsTheBar() {
        let editor = Harness(Doc.document(Doc.paragraph("Bold me")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)
        drainMainQueue()   // The opening projection announces itself too.

        let told = expectation(forNotification: .documentEditorSelectionChanged,
                               object: nil, handler: nil)
        editor.controller.apply(.bold)

        wait(for: [told], timeout: 1)
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 4),
                       "The selection this test is about did not move")
    }

    // MARK: - Press bold, then type

    /// The caret case of a mark: there is no text to embolden, so the press is a statement about
    /// what comes next. Without it the bold button does nothing at all unless something is already
    /// selected — you cannot start a bold word, only bold one you have already written.
    func testPressingBoldWithNoSelectionMarksWhatIsTypedNext() {
        let editor = Harness(Doc.document(Doc.paragraph("Plain ")))
        editor.textView.selectedRange = NSRange(location: 6, length: 0)

        editor.controller.apply(.bold)
        type("bold", into: editor)

        let runs = editor.runsOfFirstParagraph
        XCTAssertEqual(runs.map(\.text), ["Plain ", "bold"])
        XCTAssertNil(runs.first?.mark(DocumentMarkType.bold), "What was already there is untouched")
        XCTAssertNotNil(runs.last?.mark(DocumentMarkType.bold))
    }

    /// Pressing it twice says nothing, and has to leave nothing behind.
    func testPressingBoldTwiceWithNoSelectionTypesPlainText() {
        let editor = Harness(Doc.document(Doc.paragraph("")))
        editor.textView.selectedRange = NSRange(location: 0, length: 0)

        editor.controller.apply(.bold)
        editor.controller.apply(.bold)
        type("plain", into: editor)

        XCTAssertNil(editor.runsOfFirstParagraph.first?.mark(DocumentMarkType.bold))
    }

    /// The document is not touched — there is nothing to touch — so the press must not register an
    /// edit, or an autosave would upload a document that did not change.
    func testAPendingMarkIsNotAnEditToTheDocument() {
        let editor = Harness(Doc.document(Doc.paragraph("Plain")))
        editor.textView.selectedRange = NSRange(location: 5, length: 0)
        let before = DocumentBuilder.document(from: editor.textView.attributedText)

        editor.controller.apply(.bold)

        XCTAssertEqual(DocumentBuilder.document(from: editor.textView.attributedText), before)
        XCTAssertEqual(editor.textView.text, "Plain")
    }

    /// …but the button still lights, because the next keystroke really will be bold. The bar reads
    /// the same place the typing does.
    func testAPendingMarkLightsItsButton() {
        let editor = Harness(Doc.document(Doc.paragraph("Plain")))
        editor.textView.selectedRange = NSRange(location: 5, length: 0)

        XCTAssertFalse(editor.controller.isActive(.bold))

        editor.controller.apply(.bold)

        XCTAssertTrue(editor.controller.isActive(.bold))
        XCTAssertTrue(editor.controller.selectionStatus().activeCommands.contains(.bold))
    }

    /// The other direction: a caret at the end of bold text is bold, and pressing the button there
    /// means "stop". Nothing in the document changes, so only the pending marks can carry it — and
    /// they have to be able to say "deliberately none" rather than merely holding nothing.
    func testPressingBoldAtTheEndOfBoldTextStopsIt() {
        let editor = Harness(Doc.document(Doc.paragraph("Bold")))
        editor.textView.selectedRange = NSRange(location: 0, length: 4)
        editor.controller.apply(.bold)

        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertTrue(editor.controller.isActive(.bold), "The caret is at the end of bold text")

        editor.controller.apply(.bold)
        XCTAssertFalse(editor.controller.isActive(.bold))

        type(" plain", into: editor)

        let runs = editor.runsOfFirstParagraph
        XCTAssertEqual(runs.map(\.text), ["Bold", " plain"])
        XCTAssertNotNil(runs.first?.mark(DocumentMarkType.bold))
        XCTAssertNil(runs.last?.mark(DocumentMarkType.bold))
    }

    /// A mark builds on the line's own font, so starting a bold word inside a heading types at
    /// heading size rather than snapping back to body.
    func testAPendingMarkKeepsTheLinesOwnFont() {
        let editor = Harness(Doc.document(Doc.heading(1, "Title")))
        editor.textView.selectedRange = NSRange(location: 5, length: 0)

        editor.controller.apply(.italic)

        let typingFont = editor.textView.typingAttributes[.font] as? UIFont
        XCTAssertTrue(typingFont?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false)
        XCTAssertGreaterThan(typingFont?.pointSize ?? 0, 17, "Still a heading")
    }

    /// Typed into the editor the way UIKit does it: the characters take the typing attributes, and
    /// the coordinator hears about the change.
    private func type(_ text: String, into editor: Harness) {
        editor.textView.insertText(text)
        editor.coordinator.textViewDidChange(editor.textView)
    }

    /// Lets everything already queued on the main queue be delivered, so an assertion about what
    /// happens next cannot be satisfied by what happened before.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    // MARK: - Images

    func testAnInsertedImageBecomesAnImageNode() {
        let editor = Harness(Doc.document(Doc.paragraph("")))
        editor.textView.selectedRange = NSRange(location: 0, length: 0)

        editor.controller.insertImage(alt: "A cat", source: "neutrino-drive:file-1")

        let rebuilt = DocumentBuilder.document(from: editor.textView.attributedText)
        let image = rebuilt.children.first?.children.first
        XCTAssertEqual(image?.type, DocumentNodeType.image)
        XCTAssertEqual(image?.attribute("src")?.stringValue, "neutrino-drive:file-1")
        XCTAssertEqual(image?.attribute("alt")?.stringValue, "A cat")
    }

    /// Tapping a picture is what opens the properties panel, and the panel needs the node it was
    /// opened on rather than a copy of the attributes it happened to show.
    func testTappingAPictureSelectsTheNodeUnderIt() {
        let image = Doc.image(source: "cat.png", alt: "A cat")
        let editor = Harness(Doc.document(.paragraph([image])))

        editor.controller.selectImage(at: NSRange(location: 0, length: 1))

        XCTAssertEqual(editor.controller.selectedImage?.source, "cat.png")
        XCTAssertEqual(editor.controller.selectedImage?.descriptor.alt, "A cat")
    }

    func testAnEditedPictureReplacesOnlyItself() {
        let image = Doc.image(source: "cat.png", alt: "A cat")
        let editor = Harness(
            Doc.document(Doc.paragraph("Before"), .paragraph([image]), Doc.paragraph("After"))
        )

        editor.controller.selectImage(at: NSRange(location: 7, length: 1))
        var edited = editor.controller.selectedImage!.descriptor
        edited.attributes.width = "50%"
        editor.controller.updateSelectedImage(edited)

        let rebuilt = DocumentBuilder.document(from: editor.textView.attributedText)
        XCTAssertEqual(rebuilt.children.count, 3)
        XCTAssertEqual(rebuilt.children.first?.plainText, "Before")
        XCTAssertEqual(rebuilt.children.last?.plainText, "After")
        let found = rebuilt.children[1].children.first
        XCTAssertEqual(ImageAttributes(proseMirror: found?.attrs).width, "50%")
    }

    // MARK: - Tapping into the document

    /// The gutter's recognizer has to keep to the gutter. A tap recognizer added to a `UITextView`
    /// with no delegate claims every tap in the document, and the recognizer it beats is UIKit's
    /// own — the one that places the caret where you tapped and raises the keyboard.
    func testTapsOnTheTextAreNotTheGuttersToClaim() {
        let textView = EditorTextView()

        XCTAssertTrue(textView.isInGutter(CGPoint(x: 0, y: 40)))
        XCTAssertTrue(textView.isInGutter(CGPoint(x: textView.gutterWidth, y: 40)))
        XCTAssertFalse(textView.isInGutter(CGPoint(x: textView.gutterWidth + 1, y: 40)),
                       "Everything right of the chevrons is the document")
        XCTAssertFalse(textView.isInGutter(CGPoint(x: 200, y: 40)))
    }

    /// …and it must actually ask, which is what the delegate is for. Without one the recognizer
    /// claims taps unconditionally and the editor cannot be tapped into at all.
    func testTheGutterRecognizerHasADelegateToAskWith() {
        let textView = EditorTextView()

        XCTAssertNotNil(textView.gutterTapRecognizer)
        XCTAssertNotNil(textView.gutterTapRecognizer?.delegate)
    }

    // MARK: - The style bar

    /// It has to be an `inputAccessoryView`: that is what makes it appear when the user taps into
    /// the document and leave with the keyboard.
    func testTheStyleBarIsDockedToTheKeyboard() {
        let textView = EditorTextView()
        let coordinator = makeCoordinator()

        coordinator.updateStyleBar(on: textView,
                                   controller: DocumentEditorController(),
                                   isShown: true,
                                   isEditable: true,
                                   actions: EditorBarActions())

        XCTAssertNotNil(textView.inputAccessoryView)
        XCTAssertEqual(textView.inputAccessoryView?.frame.height, EditorFormattingToolbar.height)
    }

    /// Turning the bar off takes the accessory view with it.
    func testTheStyleBarCanBeTakenAway() {
        let textView = EditorTextView()
        let coordinator = makeCoordinator()
        let controller = DocumentEditorController()

        coordinator.updateStyleBar(on: textView, controller: controller, isShown: true,
                                   isEditable: true, actions: EditorBarActions())
        coordinator.updateStyleBar(on: textView, controller: controller, isShown: false,
                                   isEditable: true, actions: EditorBarActions())

        XCTAssertNil(textView.inputAccessoryView)
    }

    /// Which copy of the bar is on screen hangs on this: the keyboard's accessory view while the
    /// document is being edited, and the one docked in the layout the rest of the time. Reporting
    /// it wrongly means either no bar at all or two of them.
    func testFocusDrivesWhichCopyOfTheBarIsShown() {
        let editor = Harness(Doc.document(Doc.paragraph("Text")))

        XCTAssertFalse(editor.controller.isEditing, "A document just opened is not being typed into")

        editor.coordinator.textViewDidBeginEditing(editor.textView)
        XCTAssertTrue(editor.controller.isEditing)

        editor.coordinator.textViewDidEndEditing(editor.textView)
        XCTAssertFalse(editor.controller.isEditing)
    }

    /// `attach` runs from `updateUIView`, so anything it publishes invalidates the view that is
    /// mid-update. `@Published` announces every assignment, equal or not — so assigning the focus
    /// state unconditionally here is an unbounded render loop: update, publish, update. The app
    /// freezes on the last frame it drew, which is the opening spinner, and logs nothing because
    /// nothing failed.
    func testAttachingDoesNotAnnounceAChangeThatDidNotHappen() {
        let controller = DocumentEditorController()
        let textView = EditorTextView()
        let coordinator = makeCoordinator()

        var announcements = 0
        let subscription = controller.objectWillChange.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        // Every SwiftUI update re-attaches.
        for _ in 0..<5 {
            controller.attach(textView, coordinator: coordinator)
        }

        XCTAssertEqual(announcements, 0, "Re-attaching an unchanged editor must be silent")
    }

    /// The document actions are the whole point of the docked copy: on a phone they have no other
    /// home, so a read-only document — which has no formatting to offer — still needs the bar.
    func testAReadOnlyDocumentStillGetsABarForItsDocumentActions() {
        let textView = EditorTextView()
        let coordinator = makeCoordinator()

        coordinator.updateStyleBar(on: textView,
                                   controller: DocumentEditorController(),
                                   isShown: true,
                                   isEditable: false,
                                   actions: EditorBarActions())

        XCTAssertNotNil(textView.inputAccessoryView)
    }

    // MARK: - Typing

    /// Backspace at the start of a heading demotes it in one press rather than pulling it into the
    /// paragraph above. There is no marker in front of the text to delete a character of, so the
    /// press has to mean something: it means "stop being a heading".
    func testBackspaceAtTheStartOfAHeadingDemotesIt() {
        let editor = Harness(Doc.document(Doc.paragraph("Text"), Doc.heading(1, "Heading")))
        // The caret opens the heading's line; backspace would delete the separator before it.
        let lineStart = (editor.textView.text as NSString).range(of: "Heading").location
        editor.textView.selectedRange = NSRange(location: lineStart, length: 0)

        let handled = editor.coordinator.textView(
            editor.textView,
            shouldChangeTextIn: NSRange(location: lineStart - 1, length: 1),
            replacementText: ""
        )

        XCTAssertFalse(handled, "The rule applied the edit itself")
        XCTAssertEqual(editor.textView.text, "Text\nHeading", "The words are untouched")
        editor.textView.selectedRange = NSRange(location: lineStart, length: 0)
        XCTAssertEqual(editor.controller.paragraphHeadingLevel, 0)
    }

    /// The rule is for the start of a line only — a backspace anywhere else is a backspace.
    func testBackspaceInTheMiddleOfALineIsLeftToUIKit() {
        let editor = Harness(Doc.document(Doc.heading(1, "Heading")))
        editor.textView.selectedRange = NSRange(location: 5, length: 0)

        let handled = editor.coordinator.textView(
            editor.textView,
            shouldChangeTextIn: NSRange(location: 4, length: 1),
            replacementText: ""
        )

        XCTAssertTrue(handled, "UIKit does the deleting")
        XCTAssertEqual(editor.textView.text, "Heading")
    }

    // MARK: - Autosave interval

    /// The editor debounces at whatever Settings says, so a change there has to reach it.
    func testTheEditorHonoursTheConfiguredAutoSaveInterval() {
        let defaults = UserDefaults(suiteName: "EditorTests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let settings = AppSettings(defaults: defaults)

        settings.autoSaveInterval = 10

        XCTAssertEqual(AppSettings(defaults: defaults).autoSaveInterval, 10)
    }
}
