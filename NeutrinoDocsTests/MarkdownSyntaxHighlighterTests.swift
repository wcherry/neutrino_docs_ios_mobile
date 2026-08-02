import XCTest
import UIKit
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Edit** — specifically Phase 1's "Syntax highlighting".
///
/// The tokenizer is a pure function, so these assert on the tokens rather than on pixels.
final class MarkdownSyntaxHighlighterTests: XCTestCase {

    // MARK: - Headings

    func testHeadingLevelsAreRecognised() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let tokens = MarkdownSyntaxHighlighter.tokens(in: "\(hashes) Title")
            XCTAssertEqual(tokens.first?.style, .heading(level: level), "level \(level)")
        }
    }

    func testSevenHashesIsNotAHeading() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "####### Not a heading")
        XCTAssertFalse(tokens.contains { if case .heading = $0.style { return true }; return false })
    }

    func testHashWithoutASpaceIsNotAHeading() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "#hashtag")
        XCTAssertFalse(tokens.contains { if case .heading = $0.style { return true }; return false })
    }

    /// The whole line carries the heading style — a heading's *text* is what should look like a
    /// heading, not merely its hashes.
    func testHeadingSpansTheWholeLine() {
        let source = "## Title here"
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
        XCTAssertEqual(tokens.first?.range, NSRange(location: 0, length: (source as NSString).length))
    }

    // MARK: - Inline emphasis

    func testStrongIsRecognisedForBothSpellings() {
        for source in ["**bold**", "__bold__"] {
            let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
            XCTAssertTrue(tokens.contains { $0.style == .strong }, source)
        }
    }

    func testEmphasisIsRecognisedForBothSpellings() {
        for source in ["*italic*", "_italic_"] {
            let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
            XCTAssertTrue(tokens.contains { $0.style == .emphasis }, source)
        }
    }

    /// Precedence matters: without it `**bold**` also matches the emphasis pattern and gets both.
    func testStrongIsNotAlsoTokenizedAsEmphasis() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "**bold**")

        XCTAssertEqual(tokens.filter { $0.style == .strong }.count, 1)
        XCTAssertTrue(tokens.filter { $0.style == .emphasis }.isEmpty)
    }

    func testStrikethroughIsRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "~~gone~~")
        XCTAssertTrue(tokens.contains { $0.style == .strikethrough })
    }

    func testUnderscoresInsideAWordDoNotItalicise() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "some_variable_name here")
        XCTAssertTrue(tokens.filter { $0.style == .emphasis }.isEmpty,
                      "snake_case is not emphasis")
    }

    func testEmptyEmphasisMarkersAreNotTokenized() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "** **")
        XCTAssertTrue(tokens.filter { $0.style == .strong }.isEmpty)
    }

    // MARK: - Code

    func testInlineCodeIsRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "call `foo()` now")
        XCTAssertTrue(tokens.contains { $0.style == .inlineCode })
    }

    /// A code span is inert: markup inside it is text, not formatting.
    func testMarkupInsideACodeSpanIsNotTokenized() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "`**not bold**`")

        XCTAssertTrue(tokens.contains { $0.style == .inlineCode })
        XCTAssertTrue(tokens.filter { $0.style == .strong }.isEmpty)
    }

    func testFencedCodeBlockLinesAreAllCode() {
        let source = """
        ```swift
        let x = 1
        ```
        """
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)

        XCTAssertEqual(tokens.count, 3)
        XCTAssertTrue(tokens.allSatisfy { $0.style == .codeBlock })
    }

    /// A fence suppresses inline markup for everything inside it, which is the main reason the
    /// tokenizer is line-stateful rather than a pile of independent regexes.
    func testMarkupInsideAFenceIsSuppressed() {
        let source = """
        ```
        # not a heading
        **not bold**
        ```
        """
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)

        XCTAssertTrue(tokens.allSatisfy { $0.style == .codeBlock })
    }

    func testTextAfterAClosedFenceIsHighlightedAgain() {
        let source = """
        ```
        code
        ```
        # Real heading
        """
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)

        XCTAssertTrue(tokens.contains { $0.style == .heading(level: 1) })
    }

    func testTildeFencesAreRecognised() {
        let source = """
        ~~~
        # not a heading
        ~~~
        """
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
        XCTAssertTrue(tokens.allSatisfy { $0.style == .codeBlock })
    }

    func testIndentedCodeBlocksAreRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "    let x = 1")
        XCTAssertEqual(tokens.first?.style, .codeBlock)
    }

    // MARK: - Lists

    func testBulletMarkersAreRecognised() {
        for marker in ["-", "*", "+"] {
            let tokens = MarkdownSyntaxHighlighter.tokens(in: "\(marker) item")
            XCTAssertTrue(tokens.contains { $0.style == .listMarker }, marker)
        }
    }

    func testOrderedListMarkersAreRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "1. item")
        XCTAssertTrue(tokens.contains { $0.style == .listMarker })
    }

    func testTaskMarkersRecordTheirCheckedState() {
        let unchecked = MarkdownSyntaxHighlighter.tokens(in: "- [ ] todo")
        XCTAssertTrue(unchecked.contains { $0.style == .taskMarker(checked: false) })

        let checked = MarkdownSyntaxHighlighter.tokens(in: "- [x] done")
        XCTAssertTrue(checked.contains { $0.style == .taskMarker(checked: true) })

        let upper = MarkdownSyntaxHighlighter.tokens(in: "- [X] done")
        XCTAssertTrue(upper.contains { $0.style == .taskMarker(checked: true) })
    }

    func testNestedListMarkersAreRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "  - nested")
        XCTAssertTrue(tokens.contains { $0.style == .listMarker })
    }

    // MARK: - Other block markup

    func testBlockQuoteMarkerIsRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "> quoted")
        XCTAssertTrue(tokens.contains { $0.style == .blockQuote })
    }

    func testThematicBreaksAreRecognised() {
        for source in ["---", "***", "___", "- - -"] {
            let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
            XCTAssertTrue(tokens.contains { $0.style == .thematicBreak }, source)
        }
    }

    func testLinksAreRecognised() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "see [docs](https://example.com) now")
        XCTAssertTrue(tokens.contains { $0.style == .link })
    }

    func testImagesAreRecognisedAsLinks() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "![alt](img.png)")
        XCTAssertTrue(tokens.contains { $0.style == .link })
    }

    /// An underscore in a URL must not italicise the rest of the line.
    func testUnderscoresInsideALinkDestinationDoNotItalicise() {
        let tokens = MarkdownSyntaxHighlighter.tokens(in: "[a](http://x.com/a_b_c) and _real_")

        XCTAssertTrue(tokens.contains { $0.style == .link })
        XCTAssertEqual(tokens.filter { $0.style == .emphasis }.count, 1)
    }

    // MARK: - Ranges

    func testTokenRangesAreOffsetCorrectlyOnLaterLines() {
        let source = "first line\n# Heading"
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)

        let heading = tokens.first { if case .heading = $0.style { return true }; return false }
        XCTAssertEqual(heading?.range.location, 11, "After \"first line\\n\"")
    }

    func testTokensAreReturnedInSourceOrder() {
        let source = "# One\n\n**two**\n\n`three`"
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)

        let locations = tokens.map(\.range.location)
        XCTAssertEqual(locations, locations.sorted())
    }

    func testEveryTokenRangeIsInsideTheSource() {
        let source = """
        # Title

        Some **bold** and `code` and a [link](https://x.com).

        - [ ] task
        > quote

        ```
        fenced
        ```
        """
        let length = (source as NSString).length

        for token in MarkdownSyntaxHighlighter.tokens(in: source) {
            XCTAssertGreaterThanOrEqual(token.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), length,
                                     "Token \(token.style) runs past the end of the source")
        }
    }

    // MARK: - Edge cases

    func testEmptySourceProducesNoTokens() {
        XCTAssertTrue(MarkdownSyntaxHighlighter.tokens(in: "").isEmpty)
    }

    func testPlainProseProducesNoTokens() {
        XCTAssertTrue(MarkdownSyntaxHighlighter.tokens(in: "Just some ordinary prose.").isEmpty)
    }

    func testUnterminatedFenceStillTokenizesTheRest() {
        let source = """
        ```
        never closed
        """
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
        XCTAssertTrue(tokens.allSatisfy { $0.style == .codeBlock })
    }

    /// Multi-byte characters shift NSRange offsets; a mismatch here would style the wrong span.
    func testEmojiDoNotDisplaceLaterTokenRanges() {
        let source = "🎉 party\n# Heading"
        let tokens = MarkdownSyntaxHighlighter.tokens(in: source)
        let nsSource = source as NSString

        let heading = tokens.first { if case .heading = $0.style { return true }; return false }
        let text = nsSource.substring(with: heading!.range)
        XCTAssertEqual(text, "# Heading")
    }

    // MARK: - Attributed output

    func testAttributedStringPreservesTheSourceExactly() {
        let source = "# Title\n\n**bold** and `code`"
        let attributed = MarkdownSyntaxHighlighter.attributedString(
            for: source, baseFont: .systemFont(ofSize: 17)
        )
        XCTAssertEqual(attributed.string, source)
    }

    func testHighlightingAppliesABoldFontToStrongText() {
        let source = "**bold**"
        let attributed = MarkdownSyntaxHighlighter.attributedString(
            for: source, baseFont: .systemFont(ofSize: 17)
        )

        let font = attributed.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testHeadingsRenderLargerThanBodyText() {
        let attributed = MarkdownSyntaxHighlighter.attributedString(
            for: "# Title", baseFont: .systemFont(ofSize: 17)
        )

        let font = attributed.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 17)
    }

    func testCodeRendersMonospaced() {
        let attributed = MarkdownSyntaxHighlighter.attributedString(
            for: "`code`", baseFont: .systemFont(ofSize: 17)
        )

        let font = attributed.attribute(.font, at: 1, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false)
    }

    func testUnstyledTextKeepsTheConfiguredBaseFont() {
        let base = UIFont.systemFont(ofSize: 22)
        let attributed = MarkdownSyntaxHighlighter.attributedString(for: "plain text", baseFont: base)

        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.pointSize, 22)
    }

    func testHighlightingALargeDocumentIsNotPathological() {
        // The editor re-highlights on every keystroke, so this running in linear time is a
        // correctness concern for typing latency, not just a nicety.
        let source = String(repeating: "# Heading\n\nSome **bold** text with `code`.\n\n", count: 500)

        measure {
            _ = MarkdownSyntaxHighlighter.tokens(in: source)
        }
    }
}
