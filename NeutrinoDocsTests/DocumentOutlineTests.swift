import XCTest
@testable import NeutrinoDocs

/// Phase 2 — Document Outline: "Heading navigation", "Collapse sections", "Search headings".
final class DocumentOutlineTests: XCTestCase {

    /// The outline is read off the projected document, which is what the editor is showing — so
    /// every test here describes a document and asks what the outline of it is.
    private func outline(_ blocks: ProseMirrorNode...) -> DocumentOutline {
        DocumentOutline.outline(of: ProseMirrorNode(type: DocumentNodeType.doc, content: blocks),
                                style: Doc.style)
    }

    // MARK: - Building

    func testOutlineCollectsHeadingsInDocumentOrder() {
        let outline = outline(Doc.heading(1, "One"),
                              Doc.paragraph("text"),
                              Doc.heading(2, "Two"),
                              Doc.heading(3, "Three"),
                              Doc.heading(1, "Four"))

        XCTAssertEqual(outline.headings.map(\.title), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(outline.headings.map(\.level), [1, 2, 3, 1])
    }

    /// A line is a block, so a heading's line number is its place among the document's blocks.
    func testHeadingsRecordTheirLineNumbers() {
        let outline = outline(Doc.paragraph("intro"),
                              Doc.heading(1, "One"),
                              Doc.paragraph("body"),
                              Doc.heading(2, "Two"))

        XCTAssertEqual(outline.headings.map(\.line), [1, 3])
    }

    /// The character offset is what moves the editor's caret, so it has to point at the start of
    /// the heading's line in the text the editor holds.
    func testHeadingCharacterOffsetPointsAtTheStartOfItsLine() {
        let document = ProseMirrorNode(type: DocumentNodeType.doc, content: [
            Doc.paragraph("intro"),
            Doc.heading(1, "One"),
            Doc.paragraph("body"),
        ])
        let outline = DocumentOutline.outline(of: document, style: Doc.style)
        let projected = Doc.projection(of: document).string as NSString

        let offset = outline.headings.first!.characterOffset
        XCTAssertTrue(projected.substring(from: offset).hasPrefix("One"))
    }

    /// A `#` in a shell snippet is text in a code block, not a section — which needs no rule here,
    /// because a code block is not a heading node.
    func testHeadingsInsideCodeBlocksAreIgnored() {
        let outline = outline(Doc.heading(1, "Real"),
                              Doc.codeBlock("# not a heading", language: "sh"),
                              Doc.heading(2, "Also real"))

        XCTAssertEqual(outline.headings.map(\.title), ["Real", "Also real"])
    }

    func testFrontMatterDoesNotProduceAHeading() {
        let outline = outline(Doc.frontMatter("title: Spec"), Doc.heading(1, "Real"))

        XCTAssertEqual(outline.headings.map(\.title), ["Real"])
    }

    func testAnEmptyDocumentProducesAnEmptyOutline() {
        XCTAssertTrue(DocumentOutline.outline(of: DocumentBody.empty.doc, style: Doc.style).isEmpty)
        XCTAssertTrue(outline(Doc.paragraph("no headings here")).isEmpty)
    }

    // MARK: - Nesting

    func testHeadingsNestUnderTheirParents() {
        let outline = outline(Doc.heading(1, "One"),
                              Doc.heading(2, "Two"),
                              Doc.heading(3, "Three"),
                              Doc.heading(2, "Four"),
                              Doc.heading(1, "Five"))

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

    /// A skipped level still nests — a level 4 directly under a level 2 belongs to it.
    func testSkippedLevelsStillNest() {
        let outline = outline(Doc.heading(2, "Two"), Doc.heading(4, "Four"))

        XCTAssertEqual(outline.headings[1].parentID, outline.headings[0].id)
    }

    /// A document that starts deep and later goes shallower must not attach the shallow heading
    /// to the deep one.
    func testShallowerHeadingAfterADeepOneIsNotNestedUnderIt() {
        let outline = outline(Doc.heading(3, "Deep"), Doc.heading(1, "Shallow"))

        XCTAssertNil(outline.headings[1].parentID)
    }

    func testDescendantsIncludeEveryDepth() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(2, "Two"),
                              Doc.heading(3, "Three"), Doc.heading(1, "Four"))
        let descendants = outline.descendantIDs(of: outline.headings[0].id)

        XCTAssertEqual(Set(descendants), [outline.headings[1].id, outline.headings[2].id])
    }

    // MARK: - Collapsing

    func testCollapsingASectionHidesItsDescendants() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(2, "Two"),
                              Doc.heading(3, "Three"), Doc.heading(1, "Four"))
        let visible = outline.visibleHeadings(collapsed: [outline.headings[0].id])

        XCTAssertEqual(visible.map(\.title), ["One", "Four"])
    }

    func testCollapsingNothingShowsEverything() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(2, "Two"))
        XCTAssertEqual(outline.visibleHeadings(collapsed: []).count, 2)
    }

    // MARK: - Search

    func testSearchMatchesTitlesCaseInsensitively() {
        let outline = outline(Doc.heading(1, "Introduction"), Doc.heading(1, "Methods"),
                              Doc.heading(1, "Results"))

        XCTAssertEqual(outline.filtered(by: "meth").map(\.title), ["Methods"])
        XCTAssertEqual(outline.filtered(by: "METH").map(\.title), ["Methods"])
    }

    /// A nested match has to stay reachable through its parents, or it appears as an orphan.
    func testSearchKeepsAncestorsOfAMatch() {
        let outline = outline(Doc.heading(1, "Introduction"), Doc.heading(2, "Background"),
                              Doc.heading(3, "Prior work"), Doc.heading(1, "Results"))

        XCTAssertEqual(outline.filtered(by: "prior").map(\.title),
                       ["Introduction", "Background", "Prior work"])
    }

    func testEmptySearchReturnsEverything() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(1, "Two"))
        XCTAssertEqual(outline.filtered(by: "   ").count, 2)
    }

    func testSearchWithNoMatchesReturnsNothing() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(1, "Two"))
        XCTAssertTrue(outline.filtered(by: "zzz").isEmpty)
    }

    // MARK: - Anchors

    func testAnchorIDsFollowHeadingOrdinals() {
        let outline = outline(Doc.heading(1, "One"), Doc.heading(2, "Two"))

        XCTAssertEqual(DocumentOutline.anchorID(forHeadingAt: 0), "heading-0")
        XCTAssertEqual(outline.anchorIDsByHeading[outline.headings[1].id], "heading-1")
    }
}
