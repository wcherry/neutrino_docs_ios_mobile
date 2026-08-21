import XCTest
import UIKit
@testable import NeutrinoDocs

// MARK: - DocumentProjectionTests

/// The property the whole editor rests on: projecting a document into the editor's text and reading
/// it back is the identity.
///
/// If this holds, opening a document on a phone and saving it without typing changes nothing, and
/// every edit is a change to exactly what the user touched. If it does not, the app silently
/// rewrites documents it was only asked to display.
final class DocumentProjectionTests: XCTestCase {

    private let style = DocumentStyle(bodyFont: .systemFont(ofSize: 17))

    // MARK: - Helpers

    private func roundTrip(_ doc: ProseMirrorNode) -> ProseMirrorNode {
        DocumentBuilder.document(from: DocumentProjection.attributedString(from: doc, style: style))
    }

    private func assertRoundTrips(_ content: [ProseMirrorNode],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let doc = ProseMirrorNode(type: "doc", content: content)
        XCTAssertEqual(roundTrip(doc), doc, file: file, line: line)
    }

    private func text(_ doc: ProseMirrorNode) -> String {
        DocumentProjection.attributedString(from: doc, style: style).string
    }

    // MARK: - Blocks

    func testParagraphsRoundTrip() {
        assertRoundTrips([
            .paragraph([.text("The first paragraph.")]),
            .paragraph([.text("The second.")]),
        ])
    }

    func testHeadingKeepsItsLevel() {
        assertRoundTrips([
            ProseMirrorNode(type: "heading", attrs: ["level": .int(2)],
                            content: [.text("Findings")]),
            .paragraph([.text("Body.")]),
        ])
    }

    func testBlocksAreSeparatedByNewlinesInTheText() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading", attrs: ["level": .int(1)], content: [.text("Title")]),
            .paragraph([.text("Body")]),
        ])
        XCTAssertEqual(text(doc), "Title\nBody")
    }

    /// No syntax reaches the text: a heading is its words, and nothing else.
    func testNoMarkupAppearsInTheText() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading", attrs: ["level": .int(3)], content: [.text("Heading")]),
            .paragraph([.text("bold", marks: [ProseMirrorMark(type: "bold")])]),
        ])
        XCTAssertEqual(text(doc), "Heading\nbold")
    }

    func testEmptyParagraphInTheMiddleSurvives() {
        assertRoundTrips([
            .paragraph([.text("Above")]),
            .paragraph([]),
            .paragraph([.text("Below")]),
        ])
    }

    /// A trailing empty line has no character of its own to carry a block, so it takes the block of
    /// the line before it. For a paragraph — which is what pressing Return at the end of a document
    /// produces — that is the identity.
    func testTrailingEmptyParagraphSurvives() {
        assertRoundTrips([
            .paragraph([.text("Above")]),
            .paragraph([]),
        ])
    }

    /// The documented limit of the rule above: an empty block after a heading comes back as an
    /// empty heading. TipTap never writes one — Return from a heading makes a paragraph.
    func testTrailingEmptyBlockAfterAHeadingTakesTheHeadingsType() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading", attrs: ["level": .int(1)], content: [.text("Title")]),
            .paragraph([]),
        ])
        let rebuilt = roundTrip(doc)
        XCTAssertEqual(rebuilt.children.last?.type, "heading")
    }

    /// The backend seeds a new file with an empty doc; it opens as one empty paragraph, which is
    /// what the web editor shows for the same file.
    func testEmptyDocumentBecomesOneEmptyParagraph() {
        let rebuilt = roundTrip(ProseMirrorNode(type: "doc", content: []))
        XCTAssertEqual(rebuilt.children.count, 1)
        XCTAssertEqual(rebuilt.children.first?.type, "paragraph")
        XCTAssertNil(rebuilt.children.first?.content)
    }

    // MARK: - Marks

    func testMarksRoundTrip() {
        assertRoundTrips([
            .paragraph([
                .text("plain "),
                .text("bold", marks: [ProseMirrorMark(type: "bold")]),
                .text(" and "),
                .text("italic", marks: [ProseMirrorMark(type: "italic")]),
            ]),
        ])
    }

    func testLinkKeepsItsHref() {
        assertRoundTrips([
            .paragraph([
                .text("see ", marks: nil),
                .text("the spec", marks: [ProseMirrorMark(type: "link",
                                                          attrs: ["href": .string("https://example.com")])]),
            ]),
        ])
    }

    /// Colour and font live on a `textStyle` mark. The phone draws what it can and carries the rest.
    func testTextStyleAttributesSurvive() {
        assertRoundTrips([
            .paragraph([
                .text("coloured", marks: [ProseMirrorMark(type: "textStyle",
                                                          attrs: ["color": .string("#ff0000"),
                                                                  "fontFamily": .string("Georgia"),
                                                                  "fontSize": .string("14px")])]),
            ]),
        ])
    }

    /// The reason marks are held whole rather than mapped onto what the editor can draw: a tracked
    /// change from the web app draws nothing here, and must still be there afterwards.
    func testUnknownMarkSurvives() {
        assertRoundTrips([
            .paragraph([
                .text("suggested", marks: [ProseMirrorMark(type: "trackedInsertion",
                                                           attrs: ["author": .string("u1")])]),
            ]),
        ])
    }

    func testAdjacentRunsWithTheSameMarksAreOneTextNode() {
        let doc = ProseMirrorNode(type: "doc", content: [
            .paragraph([.text("one "), .text("two")]),
        ])
        let rebuilt = roundTrip(doc)
        XCTAssertEqual(rebuilt.children.first?.children.count, 1)
        XCTAssertEqual(rebuilt.children.first?.children.first?.text, "one two")
    }

    // MARK: - Lists

    func testBulletListRoundTrips() {
        assertRoundTrips([
            ProseMirrorNode(type: "bulletList", content: [
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("First")])]),
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Second")])]),
            ]),
        ])
    }

    func testNestedListRoundTrips() {
        assertRoundTrips([
            ProseMirrorNode(type: "bulletList", content: [
                ProseMirrorNode(type: "listItem", content: [
                    .paragraph([.text("Outer")]),
                    ProseMirrorNode(type: "bulletList", content: [
                        ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Inner")])]),
                    ]),
                ]),
            ]),
        ])
    }

    func testOrderedListKeepsItsStart() {
        assertRoundTrips([
            ProseMirrorNode(type: "orderedList", attrs: ["start": .int(3)], content: [
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Third")])]),
            ]),
        ])
    }

    /// Two lists that happen to sit next to each other are two lists. Grouping on type alone would
    /// weld them into one, which is why a level carries an identity.
    func testTwoAdjacentListsStayApart() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "bulletList", content: [
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("A")])]),
            ]),
            ProseMirrorNode(type: "bulletList", content: [
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("B")])]),
            ]),
        ])
        XCTAssertEqual(roundTrip(doc), doc)
        XCTAssertEqual(roundTrip(doc).children.count, 2)
    }

    func testListNumberingIsProjectedFromTheListsStart() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "orderedList", attrs: ["start": .int(5)], content: [
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Five")])]),
                ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Six")])]),
            ]),
        ])
        let attributed = DocumentProjection.attributedString(from: doc, style: style)
        let second = attributed.string.distance(from: attributed.string.startIndex,
                                                to: attributed.string.range(of: "Six")!.lowerBound)
        let block = attributed.attribute(.documentBlock, at: second,
                                         effectiveRange: nil) as? DocumentBlock
        XCTAssertEqual(block?.listItem?.ordinal, 6)
    }

    // MARK: - Quotes, code, breaks

    func testBlockquoteAroundAListRoundTrips() {
        assertRoundTrips([
            ProseMirrorNode(type: "blockquote", content: [
                .paragraph([.text("Quoted")]),
                ProseMirrorNode(type: "bulletList", content: [
                    ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Point")])]),
                ]),
            ]),
        ])
    }

    /// A code block's newlines are inside its text node. They must not split it into blocks.
    func testCodeBlockKeepsItsNewlines() {
        assertRoundTrips([
            ProseMirrorNode(type: "codeBlock", attrs: ["language": .string("swift")],
                            content: [.text("let a = 1\nlet b = 2")]),
            .paragraph([.text("After")]),
        ])
    }

    func testCodeBlockIsOneBlockInTheText() {
        let doc = ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "codeBlock", content: [.text("one\ntwo")]),
            .paragraph([.text("After")]),
        ])
        // One `\n` only: the one separating the code block from the paragraph.
        XCTAssertEqual(text(doc).filter { $0 == "\n" }.count, 1)
    }

    func testHardBreakRoundTrips() {
        assertRoundTrips([
            .paragraph([
                .text("first line"),
                ProseMirrorNode(type: "hardBreak"),
                .text("second line"),
            ]),
        ])
    }

    // MARK: - Atomic nodes

    func testInlineImageKeepsItsAttributes() {
        assertRoundTrips([
            .paragraph([
                .text("before "),
                ProseMirrorNode(type: "image", attrs: [
                    "src": .string("neutrino-drive:file-1"),
                    "alt": .string("A chart"),
                    "width": .int(320),
                    "alignment": .string("center"),
                ]),
                .text(" after"),
            ]),
        ])
    }

    func testHorizontalRuleRoundTrips() {
        assertRoundTrips([
            .paragraph([.text("Above")]),
            ProseMirrorNode(type: "horizontalRule"),
            .paragraph([.text("Below")]),
        ])
    }

    // MARK: - Tables

    func testTableRoundTrips() {
        assertRoundTrips([
            ProseMirrorNode(type: "table", content: [
                ProseMirrorNode(type: "tableRow", content: [
                    ProseMirrorNode(type: "tableHeader", attrs: ["colspan": .int(1)],
                                    content: [.paragraph([.text("Name")])]),
                    ProseMirrorNode(type: "tableHeader", attrs: ["colspan": .int(1)],
                                    content: [.paragraph([.text("Size")])]),
                ]),
                ProseMirrorNode(type: "tableRow", content: [
                    ProseMirrorNode(type: "tableCell", attrs: ["backgroundColor": .string("#eee")],
                                    content: [.paragraph([.text("Report")])]),
                    ProseMirrorNode(type: "tableCell", content: [.paragraph([.text("4 MB")])]),
                ]),
            ]),
        ])
    }

    // MARK: - Unknown nodes

    /// A node type from a newer web release survives being opened and saved on a phone.
    func testUnknownContainerSurvives() {
        assertRoundTrips([
            ProseMirrorNode(type: "columnLayout", attrs: ["columns": .int(2)], content: [
                .paragraph([.text("Left")]),
                .paragraph([.text("Right")]),
            ]),
        ])
    }

    func testUnknownAtomicNodeSurvives() {
        assertRoundTrips([
            .paragraph([.text("Above")]),
            ProseMirrorNode(type: "sheetEmbed", attrs: ["sheetId": .string("s1"),
                                                        "range": .string("A1:D9")]),
        ])
    }

    // MARK: - A real document

    /// Everything at once, in the shape the web app writes: the case the phone actually meets.
    func testAWebAuthoredDocumentSurvivesUntouched() {
        assertRoundTrips([
            ProseMirrorNode(type: "heading", attrs: ["level": .int(1), "textAlign": .string("center")],
                            content: [.text("Quarterly Review")]),
            ProseMirrorNode(type: "paragraph", attrs: ["textAlign": .string("justify")], content: [
                .text("Revenue rose "),
                .text("18%", marks: [ProseMirrorMark(type: "bold"),
                                     ProseMirrorMark(type: "textStyle",
                                                     attrs: ["color": .string("#0a7d32")])]),
                .text(" against plan."),
            ]),
            ProseMirrorNode(type: "bulletList", content: [
                ProseMirrorNode(type: "listItem", content: [
                    .paragraph([.text("North", marks: [ProseMirrorMark(type: "underline")])]),
                ]),
                ProseMirrorNode(type: "listItem", content: [
                    .paragraph([.text("South")]),
                    ProseMirrorNode(type: "bulletList", content: [
                        ProseMirrorNode(type: "listItem", content: [.paragraph([.text("Coastal")])]),
                    ]),
                ]),
            ]),
            ProseMirrorNode(type: "blockquote", content: [
                .paragraph([.text("A quiet quarter.", marks: [ProseMirrorMark(type: "italic")])]),
            ]),
            ProseMirrorNode(type: "codeBlock", attrs: ["language": .string("swift")],
                            content: [.text("print(\"hello\")\nprint(\"world\")")]),
            .paragraph([
                ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:img-9"),
                                                        "width": .int(480)]),
            ]),
            ProseMirrorNode(type: "horizontalRule"),
            .paragraph([]),
        ])
    }
}
