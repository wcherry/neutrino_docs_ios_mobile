import XCTest
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Open markdown documents** — the viewer half.
///
/// Phase 1's Document Viewer lists exactly what must render: headings, lists, tables, blockquotes,
/// code blocks, images, links, and checklists. There is a test per item, plus the footnote handling
/// that sits on top of GFM.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Headings

    func testHeadingsParseAtEveryLevel() {
        for level in 1...6 {
            let source = String(repeating: "#", count: level) + " Title"
            let model = MarkdownParser.parse(source)

            guard case .heading(let parsedLevel, let inlines) = model.blocks.first else {
                return XCTFail("Expected a heading at level \(level)")
            }
            XCTAssertEqual(parsedLevel, level)
            XCTAssertEqual(inlines, [.text("Title")])
        }
    }

    // MARK: - Lists

    func testUnorderedListsParseTheirItems() {
        let model = MarkdownParser.parse("- one\n- two")

        guard case .list(let list) = model.blocks.first else { return XCTFail("Expected a list") }
        XCTAssertFalse(list.isOrdered)
        XCTAssertEqual(list.items.count, 2)
    }

    func testOrderedListsKeepTheirStartIndex() {
        let model = MarkdownParser.parse("3. three\n4. four")

        guard case .list(let list) = model.blocks.first else { return XCTFail("Expected a list") }
        XCTAssertTrue(list.isOrdered)
        XCTAssertEqual(list.startIndex, 3, "A list starting at 3 is numbered 3, 4 — not renumbered")
    }

    func testNestedListsParseAsNestedBlocks() {
        let model = MarkdownParser.parse("- outer\n  - inner")

        guard case .list(let list) = model.blocks.first,
              let firstItem = list.items.first else {
            return XCTFail("Expected a list")
        }
        let hasNested = firstItem.content.contains { if case .list = $0 { return true }; return false }
        XCTAssertTrue(hasNested)
    }

    // MARK: - Checklists

    func testTaskListItemsCarryTheirCheckedState() {
        let model = MarkdownParser.parse("- [ ] todo\n- [x] done")

        guard case .list(let list) = model.blocks.first else { return XCTFail("Expected a list") }
        XCTAssertEqual(list.items.map(\.checkbox), [false, true])
    }

    func testPlainListItemsHaveNoCheckbox() {
        let model = MarkdownParser.parse("- plain")

        guard case .list(let list) = model.blocks.first else { return XCTFail("Expected a list") }
        XCTAssertNil(list.items.first?.checkbox)
    }

    // MARK: - Tables

    func testTablesParseHeaderAndRows() {
        let model = MarkdownParser.parse("""
        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        """)

        guard case .table(let table) = model.blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.header.count, 2)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows.first?.count, 2)
    }

    func testTableColumnAlignmentsAreParsed() {
        let model = MarkdownParser.parse("""
        | L | C | R |
        | :-- | :-: | --: |
        | 1 | 2 | 3 |
        """)

        guard case .table(let table) = model.blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
    }

    // MARK: - Block quotes

    func testBlockQuotesParseTheirContents() {
        let model = MarkdownParser.parse("> quoted text")

        guard case .blockQuote(let blocks) = model.blocks.first else {
            return XCTFail("Expected a block quote")
        }
        guard case .paragraph(let inlines) = blocks.first else {
            return XCTFail("Expected a paragraph inside the quote")
        }
        XCTAssertEqual(inlines, [.text("quoted text")])
    }

    // MARK: - Code blocks

    func testFencedCodeBlocksKeepTheirLanguage() {
        let model = MarkdownParser.parse("""
        ```swift
        let x = 1
        ```
        """)

        guard case .codeBlock(let code, let language) = model.blocks.first else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("let x = 1"))
    }

    func testCodeBlocksWithoutALanguageParse() {
        let model = MarkdownParser.parse("```\nplain\n```")

        guard case .codeBlock(_, let language) = model.blocks.first else {
            return XCTFail("Expected a code block")
        }
        XCTAssertNil(language)
    }

    // MARK: - Images and links

    func testImagesParseWithAltTextAndSource() {
        let model = MarkdownParser.parse("![alt text](https://example.com/a.png)")

        guard case .paragraph(let inlines) = model.blocks.first,
              case .image(let alt, let source, _) = inlines.first else {
            return XCTFail("Expected an image")
        }
        XCTAssertEqual(alt, "alt text")
        XCTAssertEqual(source, "https://example.com/a.png")
    }

    func testLinksParseWithDestination() {
        let model = MarkdownParser.parse("[docs](https://example.com)")

        guard case .paragraph(let inlines) = model.blocks.first,
              case .link(let children, let destination) = inlines.first else {
            return XCTFail("Expected a link")
        }
        XCTAssertEqual(destination, "https://example.com")
        XCTAssertEqual(children, [.text("docs")])
    }

    // MARK: - Inline formatting

    func testInlineEmphasisStrongAndCodeParse() {
        let model = MarkdownParser.parse("*em* **strong** `code`")

        guard case .paragraph(let inlines) = model.blocks.first else {
            return XCTFail("Expected a paragraph")
        }
        XCTAssertTrue(inlines.contains { if case .emphasis = $0 { return true }; return false })
        XCTAssertTrue(inlines.contains { if case .strong = $0 { return true }; return false })
        XCTAssertTrue(inlines.contains { if case .code = $0 { return true }; return false })
    }

    func testStrikethroughParses() {
        let model = MarkdownParser.parse("~~gone~~")

        guard case .paragraph(let inlines) = model.blocks.first else {
            return XCTFail("Expected a paragraph")
        }
        XCTAssertTrue(inlines.contains { if case .strikethrough = $0 { return true }; return false })
    }

    func testThematicBreakParses() {
        let model = MarkdownParser.parse("---")
        XCTAssertEqual(model.blocks.first, .thematicBreak)
    }

    // MARK: - Footnotes

    /// Footnotes are not part of GFM, so they are pre-processed into links and rebuilt afterwards.
    func testFootnoteDefinitionsAreLiftedOutOfTheBody() {
        let model = MarkdownParser.parse("Text[^1].\n\n[^1]: The note.")

        XCTAssertEqual(model.footnotes.count, 1)
        XCTAssertEqual(model.footnotes.first?.id, "1")
        XCTAssertEqual(model.footnotes.first?.index, 1)
        XCTAssertEqual(model.footnotes.first?.content, [.text("The note.")])
    }

    func testFootnoteReferencesBecomeReferenceInlines() {
        let model = MarkdownParser.parse("Text[^a].\n\n[^a]: Note.")

        guard case .paragraph(let inlines) = model.blocks.first else {
            return XCTFail("Expected a paragraph")
        }
        XCTAssertTrue(inlines.contains {
            if case .footnoteReference(let label, let index) = $0 { return label == "a" && index == 1 }
            return false
        })
    }

    /// Numbering follows the reader's eye — first appearance, not definition order.
    func testFootnotesAreNumberedByFirstAppearance() {
        let model = MarkdownParser.parse("""
        Second[^b] then first[^a].

        [^a]: A.
        [^b]: B.
        """)

        let indexByLabel = Dictionary(uniqueKeysWithValues: model.footnotes.map { ($0.id, $0.index) })
        XCTAssertEqual(indexByLabel["b"], 1)
        XCTAssertEqual(indexByLabel["a"], 2)
    }

    /// A reference with no definition is somebody's literal text, not a broken footnote.
    func testAnUndefinedFootnoteReferenceStaysLiteralText() {
        let model = MarkdownParser.parse("Text[^missing].")

        XCTAssertTrue(model.footnotes.isEmpty)
        guard case .paragraph(let inlines) = model.blocks.first else {
            return XCTFail("Expected a paragraph")
        }
        XCTAssertFalse(inlines.contains {
            if case .footnoteReference = $0 { return true }; return false
        })
    }

    func testUnreferencedDefinitionsAreStillListedAfterTheReferencedOnes() {
        let model = MarkdownParser.parse("""
        Text[^a].

        [^a]: Used.
        [^z]: Unused.
        """)

        XCTAssertEqual(model.footnotes.map(\.id), ["a", "z"])
        XCTAssertEqual(model.footnotes.map(\.index), [1, 2])
    }

    func testDuplicateFootnoteDefinitionsKeepTheFirst() {
        let model = MarkdownParser.parse("""
        Text[^a].

        [^a]: First.
        [^a]: Second.
        """)

        XCTAssertEqual(model.footnotes.count, 1)
        XCTAssertEqual(model.footnotes.first?.content, [.text("First.")])
    }

    func testTheSameFootnoteReferencedTwiceKeepsOneIndex() {
        let model = MarkdownParser.parse("""
        One[^a] and two[^a].

        [^a]: Note.
        """)

        XCTAssertEqual(model.footnotes.count, 1)
        XCTAssertEqual(model.footnotes.first?.index, 1)
    }

    // MARK: - Edge cases

    func testEmptySourceParsesToAnEmptyDocument() {
        XCTAssertEqual(MarkdownParser.parse(""), .empty)
    }

    func testWhitespaceOnlySourceHasNoBlocks() {
        XCTAssertTrue(MarkdownParser.parse("   \n\n  ").blocks.isEmpty)
    }

    func testARealisticDocumentParsesEveryBlockType() {
        let model = MarkdownParser.parse("""
        # Title

        Intro with **bold** and a [link](https://x.com).

        ## Section

        - [ ] todo
        - [x] done

        | A | B |
        | --- | --- |
        | 1 | 2 |

        > A quote.

        ```swift
        let x = 1
        ```

        ---

        Footnote[^1].

        [^1]: Note.
        """)

        func has(_ predicate: (MarkdownBlock) -> Bool) -> Bool {
            model.blocks.contains(where: predicate)
        }

        XCTAssertTrue(has { if case .heading = $0 { return true }; return false })
        XCTAssertTrue(has { if case .paragraph = $0 { return true }; return false })
        XCTAssertTrue(has { if case .list = $0 { return true }; return false })
        XCTAssertTrue(has { if case .table = $0 { return true }; return false })
        XCTAssertTrue(has { if case .blockQuote = $0 { return true }; return false })
        XCTAssertTrue(has { if case .codeBlock = $0 { return true }; return false })
        XCTAssertTrue(has { $0 == .thematicBreak })
        XCTAssertEqual(model.footnotes.count, 1)
    }

    func testParsingIsDeterministic() {
        let source = "# Title\n\nBody[^1].\n\n[^1]: Note."
        XCTAssertEqual(MarkdownParser.parse(source), MarkdownParser.parse(source))
    }
}
