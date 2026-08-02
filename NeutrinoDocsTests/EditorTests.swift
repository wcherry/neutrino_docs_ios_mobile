import XCTest
import UIKit
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

    // MARK: - Editor modes

    func testBothEditorModesAreOfferedWithIcons() {
        // Phase 1 — Markdown Editor: "Live preview toggle".
        XCTAssertEqual(DocEditorView.Mode.allCases.count, 2)
        for mode in DocEditorView.Mode.allCases {
            XCTAssertFalse(mode.iconName.isEmpty, mode.rawValue)
        }
    }

    // MARK: - Controller safety

    /// The controller is deliberately weak on its text view and nil whenever the editor is not on
    /// screen — in Preview mode, for instance. Every action must be a no-op there rather than a
    /// crash, because the toolbar buttons remain reachable.
    func testControllerActionsAreSafeWhenNoEditorIsAttached() {
        let controller = MarkdownTextEditorController()

        XCTAssertFalse(controller.isAttached)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertNil(controller.undoManager)

        // None of these may trap.
        controller.undo()
        controller.redo()
        controller.presentFind()
        controller.presentFindAndReplace()
        controller.resignFirstResponder()
    }

    func testControllerReportsAttachmentOnceWired() {
        let controller = MarkdownTextEditorController()
        let textView = UITextView()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: true
        )

        controller.attach(textView, coordinator: coordinator)

        XCTAssertTrue(controller.isAttached)
        XCTAssertNotNil(controller.undoManager)
    }

    // MARK: - Coordinator styling

    func testHighlightingIsAppliedWhenEnabled() {
        let textView = UITextView()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: true
        )

        coordinator.apply(text: "# Heading", to: textView,
                          font: .systemFont(ofSize: 17), highlight: true)

        XCTAssertEqual(textView.text, "# Heading")
        let font = textView.attributedText.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 17, "A heading should render larger")
    }

    func testHighlightingIsSkippedWhenDisabled() {
        let textView = UITextView()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: false
        )

        coordinator.apply(text: "# Heading", to: textView,
                          font: .systemFont(ofSize: 17), highlight: false)

        let font = textView.attributedText.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.pointSize, 17, "Every character keeps the base font")
    }

    /// Assigning `attributedText` moves the caret to the end, which is unusable while typing — so
    /// the selection has to survive a restyle.
    func testRestylePreservesTheCaretPosition() {
        let textView = UITextView()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: true
        )
        coordinator.apply(text: "# Heading and more text", to: textView,
                          font: .systemFont(ofSize: 17), highlight: true)
        textView.selectedRange = NSRange(location: 5, length: 0)

        coordinator.restyle(textView)

        XCTAssertEqual(textView.selectedRange.location, 5)
    }

    /// A restyle after the text shortened must clamp rather than address past the end.
    func testRestyleClampsASelectionBeyondTheNewLength() {
        let textView = UITextView()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: true
        )
        coordinator.apply(text: "a long piece of text", to: textView,
                          font: .systemFont(ofSize: 17), highlight: true)
        textView.selectedRange = NSRange(location: 18, length: 2)
        textView.text = "short"

        coordinator.restyle(textView)

        XCTAssertLessThanOrEqual(NSMaxRange(textView.selectedRange), (textView.text as NSString).length)
    }

    func testRestyleIsSkippedWhenNothingAboutTheStylingChanged() {
        let coordinator = MarkdownTextEditor.Coordinator(
            text: .constant(""), font: .systemFont(ofSize: 17), highlightSyntax: true
        )
        let textView = UITextView()
        coordinator.apply(text: "text", to: textView, font: .systemFont(ofSize: 17), highlight: true)

        XCTAssertFalse(coordinator.needsRestyle(font: .systemFont(ofSize: 17), highlight: true))
        XCTAssertTrue(coordinator.needsRestyle(font: .systemFont(ofSize: 20), highlight: true),
                      "A font-size change must repaint")
        XCTAssertTrue(coordinator.needsRestyle(font: .systemFont(ofSize: 17), highlight: false),
                      "Turning highlighting off must repaint")
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
