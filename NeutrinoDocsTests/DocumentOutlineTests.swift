import XCTest
@testable import NeutrinoDocs

/// Phase 2 — Document Outline: "Heading navigation", "Collapse sections", "Search headings".
final class DocumentOutlineTests: XCTestCase {

    // MARK: - Parsing

    func testOutlineCollectsHeadingsInDocumentOrder() {
        let outline = DocumentOutline.parse("""
        # One
        text
        ## Two
        ### Three
        # Four
        """)

        XCTAssertEqual(outline.headings.map(\.title), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(outline.headings.map(\.level), [1, 2, 3, 1])
    }

    func testHeadingsRecordTheirLineNumbers() {
        let outline = DocumentOutline.parse("intro\n\n# One\nbody\n## Two")

        XCTAssertEqual(outline.headings.map(\.line), [2, 4])
    }

    /// The character offset is what moves the editor's caret, so it has to point at the start of
    /// the heading's line.
    func testHeadingCharacterOffsetPointsAtTheStartOfItsLine() {
        let source = "intro\n# One\nbody"
        let outline = DocumentOutline.parse(source)

        let offset = outline.headings.first!.characterOffset
        XCTAssertEqual((source as NSString).substring(from: offset).hasPrefix("# One"), true)
    }

    func testSetextHeadingsAreRecognized() {
        let outline = DocumentOutline.parse("""
        Title
        =====
        Subtitle
        --------
        """)

        XCTAssertEqual(outline.headings.map(\.title), ["Title", "Subtitle"])
        XCTAssertEqual(outline.headings.map(\.level), [1, 2])
    }

    /// A `#` comment in a shell snippet is not a section.
    func testHeadingsInsideCodeFencesAreIgnored() {
        let outline = DocumentOutline.parse("""
        # Real
        ```sh
        # not a heading
        ```
        ## Also real
        """)

        XCTAssertEqual(outline.headings.map(\.title), ["Real", "Also real"])
    }

    /// Front matter's closing `---` would otherwise read as a Setext underline for the line above.
    func testFrontMatterDoesNotProduceAHeading() {
        let outline = DocumentOutline.parse("""
        ---
        title: Spec
        ---
        # Real
        """)

        XCTAssertEqual(outline.headings.map(\.title), ["Real"])
    }

    func testTrailingHashesAreStrippedFromTitles() {
        let outline = DocumentOutline.parse("## Closed ##")
        XCTAssertEqual(outline.headings.first?.title, "Closed")
    }

    func testEmptySourceProducesAnEmptyOutline() {
        XCTAssertTrue(DocumentOutline.parse("").isEmpty)
        XCTAssertTrue(DocumentOutline.parse("no headings here").isEmpty)
    }

    // MARK: - Nesting

    func testHeadingsNestUnderTheirParents() {
        let outline = DocumentOutline.parse("""
        # One
        ## Two
        ### Three
        ## Four
        # Five
        """)

        let one = outline.headings[0]
        let two = outline.headings[1]
        let three = outline.headings[2]
        let four = outline.headings[3]
        let five = outline.headings[4]

        XCTAssertNil(one.parentID)
        XCTAssertEqual(one.childIDs, [two.id, four.id])
        XCTAssertEqual(two.childIDs, [three.id])
        XCTAssertEqual(three.parentID, two.id)
        XCTAssertNil(five.parentID)
    }

    /// A skipped level still nests — `####` directly under `##` belongs to it.
    func testSkippedLevelsStillNest() {
        let outline = DocumentOutline.parse("## Two\n#### Four")

        XCTAssertEqual(outline.headings[1].parentID, outline.headings[0].id)
    }

    /// A document that starts deep and later goes shallower must not attach the shallow heading
    /// to the deep one.
    func testShallowerHeadingAfterADeepOneIsNotNestedUnderIt() {
        let outline = DocumentOutline.parse("### Deep\n# Shallow")

        XCTAssertNil(outline.headings[1].parentID)
    }

    func testDescendantsIncludeEveryDepth() {
        let outline = DocumentOutline.parse("# One\n## Two\n### Three\n# Four")
        let descendants = outline.descendantIDs(of: outline.headings[0].id)

        XCTAssertEqual(Set(descendants), [outline.headings[1].id, outline.headings[2].id])
    }

    // MARK: - Collapsing

    func testCollapsingASectionHidesItsDescendants() {
        let outline = DocumentOutline.parse("# One\n## Two\n### Three\n# Four")
        let visible = outline.visibleHeadings(collapsed: [outline.headings[0].id])

        XCTAssertEqual(visible.map(\.title), ["One", "Four"])
    }

    func testCollapsingNothingShowsEverything() {
        let outline = DocumentOutline.parse("# One\n## Two")
        XCTAssertEqual(outline.visibleHeadings(collapsed: []).count, 2)
    }

    // MARK: - Search

    func testSearchMatchesTitlesCaseInsensitively() {
        let outline = DocumentOutline.parse("# Introduction\n# Methods\n# Results")

        XCTAssertEqual(outline.filtered(by: "meth").map(\.title), ["Methods"])
        XCTAssertEqual(outline.filtered(by: "METH").map(\.title), ["Methods"])
    }

    /// A nested match has to stay reachable through its parents, or it appears as an orphan.
    func testSearchKeepsAncestorsOfAMatch() {
        let outline = DocumentOutline.parse("""
        # Introduction
        ## Background
        ### Prior work
        # Results
        """)

        XCTAssertEqual(outline.filtered(by: "prior").map(\.title),
                       ["Introduction", "Background", "Prior work"])
    }

    func testEmptySearchReturnsEverything() {
        let outline = DocumentOutline.parse("# One\n# Two")
        XCTAssertEqual(outline.filtered(by: "   ").count, 2)
    }

    func testSearchWithNoMatchesReturnsNothing() {
        let outline = DocumentOutline.parse("# One\n# Two")
        XCTAssertTrue(outline.filtered(by: "zzz").isEmpty)
    }

    // MARK: - Anchors

    /// The outline's anchor ids have to match the ones `MarkdownView` puts on rendered headings,
    /// or selecting a heading in Preview scrolls nowhere.
    func testAnchorIDsFollowHeadingOrdinals() {
        let outline = DocumentOutline.parse("# One\n## Two")

        XCTAssertEqual(DocumentOutline.anchorID(forHeadingAt: 0), "heading-0")
        XCTAssertEqual(outline.anchorIDsByHeading[outline.headings[1].id], "heading-1")
    }
}
