import XCTest
import SwiftUI
@testable import NeutrinoDocs

/// Supports the **Open markdown documents** deliverable: the inline half of the viewer.
final class MarkdownInlineRendererTests: XCTestCase {

    func testPlainTextRendersVerbatim() {
        let result = MarkdownInlineRenderer.attributedString(for: [.text("hello")])
        XCTAssertEqual(String(result.characters), "hello")
    }

    func testAdjacentInlinesAreConcatenated() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .text("a"), .strong([.text("b")]), .text("c"),
        ])
        XCTAssertEqual(String(result.characters), "abc")
    }

    func testStrongCarriesTheStrongEmphasisIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.strong([.text("bold")])])
        let run = result.runs.first { $0.inlinePresentationIntent != nil }
        XCTAssertTrue(run?.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false)
    }

    func testEmphasisCarriesTheEmphasizedIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.emphasis([.text("it")])])
        let run = result.runs.first { $0.inlinePresentationIntent != nil }
        XCTAssertTrue(run?.inlinePresentationIntent?.contains(.emphasized) ?? false)
    }

    func testStrikethroughCarriesItsIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [.strikethrough([.text("x")])])
        let run = result.runs.first { $0.inlinePresentationIntent != nil }
        XCTAssertTrue(run?.inlinePresentationIntent?.contains(.strikethrough) ?? false)
    }

    /// Nested emphasis has to combine rather than replace, or bold-inside-italic loses one of them.
    func testNestedEmphasisCombinesBothIntents() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .strong([.emphasis([.text("both")])]),
        ])

        let intent = result.runs.first { $0.inlinePresentationIntent != nil }?.inlinePresentationIntent
        XCTAssertTrue(intent?.contains(.stronglyEmphasized) ?? false)
        XCTAssertTrue(intent?.contains(.emphasized) ?? false)
    }

    func testLinksCarryTheirDestination() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .link(inlines: [.text("docs")], destination: "https://example.com"),
        ])

        let run = result.runs.first { $0.link != nil }
        XCTAssertEqual(run?.link?.absoluteString, "https://example.com")
    }

    func testFormattingInsideALinkKeepsBothTheLinkAndTheIntent() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .link(inlines: [.strong([.text("bold link")])], destination: "https://example.com"),
        ])

        let run = result.runs.first { $0.link != nil }
        XCTAssertNotNil(run?.link)
        XCTAssertTrue(run?.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false)
    }

    func testInlineCodeRendersMonospaced() {
        let result = MarkdownInlineRenderer.attributedString(for: [.code("foo()")])
        XCTAssertEqual(String(result.characters), "foo()")
        XCTAssertNotNil(result.runs.first { $0.font != nil })
    }

    /// A softBreak is a single newline in the source, which CommonMark renders as a space.
    func testSoftBreakRendersAsASpace() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .text("a"), .softBreak, .text("b"),
        ])
        XCTAssertEqual(String(result.characters), "a b")
    }

    func testHardLineBreakRendersAsANewline() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .text("a"), .lineBreak, .text("b"),
        ])
        XCTAssertEqual(String(result.characters), "a\nb")
    }

    /// A mid-paragraph image cannot be drawn inside a `Text`, so it degrades to its alt text — a
    /// documented limitation rather than a silent drop.
    func testInlineImagesFallBackToAltText() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .image(alt: "a diagram", source: "x.png", title: nil),
        ])
        XCTAssertEqual(String(result.characters), "a diagram")
    }

    /// The marker shows the number; the link is what lets `MarkdownView` intercept the tap and
    /// scroll instead of handing an unopenable scheme to the system.
    func testFootnoteReferenceRendersItsIndexAndAnInternalLink() {
        let result = MarkdownInlineRenderer.attributedString(for: [
            .footnoteReference(label: "a", index: 3),
        ])

        XCTAssertEqual(String(result.characters), "3")
        let link = result.runs.first { $0.link != nil }?.link?.absoluteString
        XCTAssertEqual(link, "\(MarkdownParser.footnoteScheme)a")
    }

    func testEmptyInputRendersEmpty() {
        XCTAssertEqual(String(MarkdownInlineRenderer.attributedString(for: []).characters), "")
    }

    func testParserOutputRendersEndToEnd() {
        let model = MarkdownParser.parse("Some **bold** and a [link](https://x.com).")
        guard case .paragraph(let inlines) = model.blocks.first else {
            return XCTFail("Expected a paragraph")
        }

        let result = MarkdownInlineRenderer.attributedString(for: inlines)

        XCTAssertEqual(String(result.characters), "Some bold and a link.")
        XCTAssertNotNil(result.runs.first { $0.link != nil })
    }
}
