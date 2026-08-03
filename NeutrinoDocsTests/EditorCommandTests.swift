import XCTest
@testable import NeutrinoDocs

// MARK: - Offset helper

private extension String {
    /// UTF-16 offset of an index, which is the unit `NSRange` and `UITextView` both work in.
    /// `distance(from:to:)` counts Characters, and would be wrong the moment a test string held a
    /// multi-unit grapheme — including the guillemets the helpers below use.
    func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index.samePosition(in: utf16)!)
    }
}

/// Phase 2 — Formatting Toolbar and Editor Improvements.
///
/// Every command is a pure `EditorTextState -> EditorTextState`, so what happens with a caret,
/// with a selection, and when the markup is already there is asserted directly rather than by
/// tapping buttons.
final class EditorCommandTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a state from a string with `‸` marking the caret, or `«` and `»` marking a selection.
    ///
    /// Guillemets rather than square brackets: the inputs here are Markdown, and `[` / `]` appear
    /// inside links and task-list boxes, where they would be mistaken for the selection markers.
    private func state(_ annotated: String) -> EditorTextState {
        if let caret = annotated.firstIndex(of: "‸") {
            let offset = annotated.utf16Offset(of: caret)
            var text = annotated
            text.remove(at: caret)
            return EditorTextState(text: text, selection: NSRange(location: offset, length: 0))
        }

        guard let open = annotated.firstIndex(of: "«"),
              let close = annotated.firstIndex(of: "»") else {
            return EditorTextState(text: annotated, selection: NSRange(location: 0, length: 0))
        }
        let start = annotated.utf16Offset(of: open)
        // The closing marker's offset counts the opening one, which is about to be removed.
        let end = annotated.utf16Offset(of: close) - 1
        var text = annotated
        text.remove(at: close)
        text.remove(at: open)
        return EditorTextState(text: text, selection: NSRange(location: start, length: end - start))
    }

    /// Renders a state back into the annotated form, for readable assertions.
    private func annotated(_ state: EditorTextState) -> String {
        let text = state.nsText
        if state.selection.length == 0 {
            return text.substring(to: state.selection.location) + "‸"
                + text.substring(from: state.selection.location)
        }
        return text.substring(to: state.selection.location)
            + "«" + text.substring(with: state.selection) + "»"
            + text.substring(from: NSMaxRange(state.selection))
    }

    // MARK: - Inline wrapping

    func testBoldWrapsTheSelection() {
        let result = MarkdownEditingCommand.bold.apply(to: state("say «hello» there"))
        XCTAssertEqual(result.text, "say **hello** there")
    }

    func testBoldWithNoSelectionLeavesTheCaretBetweenTheMarkers() {
        let result = MarkdownEditingCommand.bold.apply(to: state("say ‸"))
        XCTAssertEqual(annotated(result), "say **‸**")
    }

    func testBoldOnAlreadyBoldSelectionUnwrapsIt() {
        let result = MarkdownEditingCommand.bold.apply(to: state("say «**hello**» there"))
        XCTAssertEqual(result.text, "say hello there")
    }

    /// Selecting just the word inside existing markers should also unwrap — the markers are right
    /// there on either side.
    func testBoldOnTextSurroundedByMarkersUnwrapsThem() {
        let result = MarkdownEditingCommand.bold.apply(to: state("say **«hello»** there"))
        XCTAssertEqual(result.text, "say hello there")
    }

    func testItalicAndCodeUseTheirOwnMarkers() {
        XCTAssertEqual(MarkdownEditingCommand.italic.apply(to: state("«x»")).text, "*x*")
        XCTAssertEqual(MarkdownEditingCommand.code.apply(to: state("«x»")).text, "`x`")
        XCTAssertEqual(MarkdownEditingCommand.strikethrough.apply(to: state("«x»")).text, "~~x~~")
    }

    // MARK: - Links and images

    func testLinkWrapsTheSelectionAndSelectsTheURL() {
        let result = MarkdownEditingCommand.link.apply(to: state("see «docs» here"))
        XCTAssertEqual(result.text, "see [docs](url) here")
        XCTAssertEqual(result.selectedText, "url")
    }

    func testLinkWithNoSelectionInsertsAPlaceholderTitle() {
        let result = MarkdownEditingCommand.link.apply(to: state("‸"))
        XCTAssertEqual(result.text, "[title](url)")
        XCTAssertEqual(result.selectedText, "url")
    }

    func testImageUsesTheImageSyntax() {
        let result = MarkdownEditingCommand.image.apply(to: state("‸"))
        XCTAssertEqual(result.text, "![alt text](url)")
        XCTAssertEqual(result.selectedText, "url")
    }

    // MARK: - Line prefixes

    func testQuoteAddsAMarkerToEverySelectedLine() {
        let result = MarkdownEditingCommand.quote.apply(to: state("«one\ntwo»"))
        XCTAssertEqual(result.text, "> one\n> two")
    }

    func testQuoteOnAlreadyQuotedLinesRemovesTheMarker() {
        let result = MarkdownEditingCommand.quote.apply(to: state("«> one\n> two»"))
        XCTAssertEqual(result.text, "one\ntwo")
    }

    func testBulletListTogglesOnAndOff() {
        let bulleted = MarkdownEditingCommand.bulletList.apply(to: state("«one\ntwo»"))
        XCTAssertEqual(bulleted.text, "- one\n- two")

        let plain = MarkdownEditingCommand.bulletList.apply(
            to: EditorTextState(text: bulleted.text, selection: bulleted.selection)
        )
        XCTAssertEqual(plain.text, "one\ntwo")
    }

    func testNumberedListNumbersSequentially() {
        let result = MarkdownEditingCommand.numberedList.apply(to: state("«one\ntwo\nthree»"))
        XCTAssertEqual(result.text, "1. one\n2. two\n3. three")
    }

    /// Switching list type must replace the marker, not stack a second one on top.
    func testSwitchingFromBulletToNumberedReplacesTheMarker() {
        let result = MarkdownEditingCommand.numberedList.apply(to: state("«- one\n- two»"))
        XCTAssertEqual(result.text, "1. one\n2. two")
    }

    func testCheckboxTurnsLinesIntoTaskItems() {
        let result = MarkdownEditingCommand.checkbox.apply(to: state("«one\ntwo»"))
        XCTAssertEqual(result.text, "- [ ] one\n- [ ] two")
    }

    /// Toggling off a task list leaves the bullet, which is what the item was before the box.
    func testCheckboxOnExistingTasksLeavesPlainBullets() {
        let result = MarkdownEditingCommand.checkbox.apply(to: state("«- [x] one\n- [ ] two»"))
        XCTAssertEqual(result.text, "- one\n- two")
    }

    func testBlankLinesInASelectionAreLeftAlone() {
        let result = MarkdownEditingCommand.bulletList.apply(to: state("«one\n\ntwo»"))
        XCTAssertEqual(result.text, "- one\n\n- two")
    }

    // MARK: - Blocks

    func testTableInsertsAStarterGridAndSelectsTheFirstHeader() {
        let result = MarkdownEditingCommand.table.apply(to: state("‸"))
        XCTAssertTrue(result.text.contains("| Column 1 | Column 2 |"))
        XCTAssertTrue(result.text.contains("| --- | --- |"))
        XCTAssertEqual(result.selectedText, "Column 1")
    }

    func testCodeBlockWrapsTheSelectionInFences() {
        let result = MarkdownEditingCommand.codeBlock.apply(to: state("«let x = 1»"))
        XCTAssertTrue(result.text.contains("```\nlet x = 1\n```"))
    }

    /// A block insertion must start on its own line rather than gluing itself to the text above.
    func testBlockInsertionSeparatesItselfFromSurroundingText() {
        let result = MarkdownEditingCommand.table.apply(to: state("Some text‸"))
        XCTAssertTrue(result.text.hasPrefix("Some text\n\n|"),
                      "expected a blank line before the table, got: \(result.text)")
    }

    // MARK: - Selection clamping

    /// A selection beyond the end of the text would trap on the first substring call.
    func testOutOfBoundsSelectionIsClamped() {
        let clamped = EditorTextState(text: "abc", selection: NSRange(location: 99, length: 99))
        XCTAssertEqual(clamped.selection, NSRange(location: 3, length: 0))
    }
}

// MARK: - SmartTypingTests

/// Phase 2 — Editor Improvements: smart indentation, auto bullets, auto numbering, auto closing
/// brackets.
final class SmartTypingTests: XCTestCase {

    private func caret(_ text: String, at offset: Int) -> EditorTextState {
        EditorTextState(text: text, selection: NSRange(location: offset, length: 0))
    }

    // MARK: - List continuation

    func testReturnContinuesABulletList() {
        let result = SmartTypingBehavior.newline(in: caret("- one", at: 5))
        XCTAssertEqual(result?.text, "- one\n- ")
    }

    func testReturnIncrementsANumberedList() {
        let result = SmartTypingBehavior.newline(in: caret("3. three", at: 8))
        XCTAssertEqual(result?.text, "3. three\n4. ")
    }

    /// A continued task item starts unchecked whatever the one above it was.
    func testReturnContinuesATaskListUnchecked() {
        let result = SmartTypingBehavior.newline(in: caret("- [x] done", at: 10))
        XCTAssertEqual(result?.text, "- [x] done\n- [ ] ")
    }

    func testReturnContinuesABlockQuote() {
        let result = SmartTypingBehavior.newline(in: caret("> quoted", at: 8))
        XCTAssertEqual(result?.text, "> quoted\n> ")
    }

    func testListContinuationPreservesIndentation() {
        let result = SmartTypingBehavior.newline(in: caret("  - nested", at: 10))
        XCTAssertEqual(result?.text, "  - nested\n  - ")
    }

    /// Return on an empty item ends the list — the standard way to stop.
    func testReturnOnAnEmptyItemClearsTheMarker() {
        let result = SmartTypingBehavior.newline(in: caret("- one\n- ", at: 8))
        XCTAssertEqual(result?.text, "- one\n")
    }

    /// Return in the middle of an item is a split, not a new item.
    func testReturnMidLineIsNotIntercepted() {
        XCTAssertNil(SmartTypingBehavior.newline(in: caret("- one two", at: 5)))
    }

    func testReturnOnAPlainParagraphIsNotIntercepted() {
        XCTAssertNil(SmartTypingBehavior.newline(in: caret("just text", at: 9)))
    }

    func testListContinuationCanBeDisabled() {
        let options = SmartTypingBehavior.Options(continueLists: false)
        XCTAssertNil(SmartTypingBehavior.newline(in: caret("- one", at: 5), options: options))
    }

    // MARK: - Bracket closing

    func testOpeningBracketInsertsItsPartner() {
        let result = SmartTypingBehavior.insert("(", in: caret("call", at: 4))
        XCTAssertEqual(result?.text, "call()")
        XCTAssertEqual(result?.selection.location, 5)
    }

    func testOpeningBracketWrapsASelection() {
        let state = EditorTextState(text: "wrap me", selection: NSRange(location: 5, length: 2))
        let result = SmartTypingBehavior.insert("(", in: state)
        XCTAssertEqual(result?.text, "wrap (me)")
        XCTAssertEqual(result?.selectedText, "me")
    }

    /// Typing the closer that is already there should step over it, not double it.
    func testTypingAClosingBracketStepsOverTheAutoInsertedOne() {
        let result = SmartTypingBehavior.insert(")", in: caret("call()", at: 5))
        XCTAssertEqual(result?.text, "call()")
        XCTAssertEqual(result?.selection.location, 6)
    }

    /// `(` typed before a word should not produce `()word`.
    func testBracketIsNotClosedDirectlyBeforeAWord() {
        XCTAssertNil(SmartTypingBehavior.insert("(", in: caret("abc", at: 0)))
    }

    /// A third backtick is a fence being typed, not a code span to close.
    func testBacktickAfterBacktickIsNotClosed() {
        XCTAssertNil(SmartTypingBehavior.insert("`", in: caret("`", at: 1)))
    }

    func testDeletingBetweenAPairRemovesBoth() {
        let result = SmartTypingBehavior.deleteBackward(in: caret("()", at: 1))
        XCTAssertEqual(result?.text, "")
    }

    func testDeletingElsewhereIsNotIntercepted() {
        XCTAssertNil(SmartTypingBehavior.deleteBackward(in: caret("abc", at: 2)))
    }

    func testBracketClosingCanBeDisabled() {
        let options = SmartTypingBehavior.Options(closeBrackets: false)
        XCTAssertNil(SmartTypingBehavior.insert("(", in: caret("x", at: 1), options: options))
    }

    // MARK: - Indentation

    func testIndentAddsSpacesToEverySelectedLine() {
        let state = EditorTextState(text: "one\ntwo", selection: NSRange(location: 0, length: 7))
        let result = SmartTypingBehavior.indent(state)
        XCTAssertEqual(result.text, "  one\n  two")
    }

    func testOutdentRemovesUpToOneIndentLevel() {
        let state = EditorTextState(text: "    one\n  two", selection: NSRange(location: 0, length: 13))
        let result = SmartTypingBehavior.indent(state, outdent: true)
        XCTAssertEqual(result.text, "  one\ntwo")
    }

    func testOutdentOnUnindentedTextIsANoOp() {
        let state = EditorTextState(text: "one", selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(SmartTypingBehavior.indent(state, outdent: true).text, "one")
    }

    /// A caret mid-line still behaves like a plain tab key.
    func testTabMidLineInsertsSpacesRatherThanIndentingTheLine() {
        let result = SmartTypingBehavior.indent(caret("abc", at: 3))
        XCTAssertEqual(result.text, "abc  ")
    }

    func testIndentWidthIsConfigurable() {
        let options = SmartTypingBehavior.Options(indentWidth: 4)
        let state = EditorTextState(text: "one", selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(SmartTypingBehavior.indent(state, options: options).text, "    one")
    }

    func testIndentLeavesBlankLinesAlone() {
        let state = EditorTextState(text: "one\n\ntwo", selection: NSRange(location: 0, length: 8))
        XCTAssertEqual(SmartTypingBehavior.indent(state).text, "  one\n\n  two")
    }
}

// MARK: - CodeFoldingTests

/// Phase 2 — Editor Improvements, "Code folding".
final class CodeFoldingTests: XCTestCase {

    func testHeadingFoldsThroughToTheNextSameLevelHeading() {
        let regions = CodeFolding.regions(in: """
        # One
        body
        body
        # Two
        other
        """)

        let section = regions.first { $0.startLine == 0 }
        XCTAssertEqual(section?.startLine, 0)
        XCTAssertEqual(section?.endLine, 2)
        XCTAssertEqual(section?.kind, .section(level: 1))
    }

    /// A deeper heading is inside its parent's region, so folding the parent hides it too.
    func testParentSectionEnclosesDeeperHeadings() {
        let regions = CodeFolding.regions(in: """
        # One
        ## Sub
        body
        # Two
        """)

        let parent = regions.first { $0.startLine == 0 }
        XCTAssertEqual(parent?.endLine, 2)
    }

    func testFencedCodeBlockIsFoldable() {
        let regions = CodeFolding.regions(in: """
        ```swift
        let x = 1
        let y = 2
        ```
        """)

        let block = regions.first { $0.kind == .codeBlock }
        XCTAssertEqual(block?.startLine, 0)
        XCTAssertEqual(block?.endLine, 3)
        XCTAssertEqual(block?.summary, "swift — 2 lines")
    }

    /// A `#` comment inside a shell snippet is not a section heading.
    func testHeadingsInsideCodeFencesAreIgnored() {
        let regions = CodeFolding.regions(in: """
        ```sh
        # not a heading
        echo hi
        ```
        """)

        XCTAssertFalse(regions.contains { if case .section = $0.kind { return true } else { return false } })
    }

    func testFoldingASectionHidesItsBodyButNotItsHeading() {
        let source = "# One\nbody\nbody\n# Two"
        let regions = CodeFolding.regions(in: source)
        let hidden = CodeFolding.hiddenLines(folding: [0], regions: regions)

        XCTAssertFalse(hidden.contains(0), "the heading itself stays visible")
        XCTAssertEqual(hidden, [1, 2])
    }

    func testDisplayLinesDropHiddenLinesAndAppendASummary() {
        let source = "# One\nbody\nbody\n# Two"
        let regions = CodeFolding.regions(in: source)
        let lines = CodeFolding.displayLines(for: source, folding: [0], regions: regions)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("# One"))
        XCTAssertTrue(lines[0].contains("2 lines"))
        XCTAssertEqual(lines[1], "# Two")
    }

    func testTrailingBlankLinesAreNotPartOfASection() {
        let regions = CodeFolding.regions(in: "# One\nbody\n\n\n# Two")
        XCTAssertEqual(regions.first { $0.startLine == 0 }?.endLine, 1)
    }

    func testEmptySourceHasNoRegions() {
        XCTAssertTrue(CodeFolding.regions(in: "").isEmpty)
    }

    /// A heading with nothing under it cannot be folded — there would be nothing to hide.
    func testEmptySectionIsNotFoldable() {
        let regions = CodeFolding.regions(in: "# One\n# Two")
        XCTAssertTrue(regions.isEmpty)
    }
}
