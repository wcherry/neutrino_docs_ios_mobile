import XCTest
@testable import NeutrinoDocs

/// Phase 2 — Rich Markdown: front matter, callouts, math, and Mermaid.
///
/// Tables, footnotes, and task lists shipped in Phase 1 and are covered by `ModelTests`.
final class RichMarkdownTests: XCTestCase {

    // MARK: - Front matter

    func testFrontMatterIsSplitOffAndParsedAsKeyValuePairs() {
        let split = FrontMatterParser.split("""
        ---
        title: Quarterly Report
        author: Dana
        ---
        # Heading

        Body.
        """)

        XCTAssertEqual(split.frontMatter.title, "Quarterly Report")
        XCTAssertEqual(split.frontMatter["author"], ["Dana"])
        XCTAssertEqual(split.body, "# Heading\n\nBody.")
    }

    func testFrontMatterReadsInlineAndDashLists() {
        let split = FrontMatterParser.split("""
        ---
        tags: [swift, ios, markdown]
        reviewers:
          - Ana
          - Ben
        ---
        Body.
        """)

        XCTAssertEqual(split.frontMatter.tags, ["swift", "ios", "markdown"])
        XCTAssertEqual(split.frontMatter["reviewers"], ["Ana", "Ben"])
    }

    /// A quoted value is one value even when it contains commas — otherwise a title like
    /// "Retention, revisited" would silently become two.
    func testQuotedFrontMatterValueWithCommasStaysOneValue() {
        let split = FrontMatterParser.split("""
        ---
        title: "Retention, revisited"
        ---
        Body.
        """)

        XCTAssertEqual(split.frontMatter.title, "Retention, revisited")
    }

    /// Without a closing fence there is no front matter, and consuming the document would delete
    /// the whole thing.
    func testUnterminatedFrontMatterIsTreatedAsBody() {
        let source = "---\ntitle: Nope\n\n# Heading"
        let split = FrontMatterParser.split(source)

        XCTAssertTrue(split.frontMatter.isEmpty)
        XCTAssertEqual(split.body, source)
    }

    /// `---` further down a document is a thematic break, not the start of front matter.
    func testThematicBreakMidDocumentIsNotFrontMatter() {
        let source = "# Heading\n\n---\n\nMore."
        let split = FrontMatterParser.split(source)

        XCTAssertTrue(split.frontMatter.isEmpty)
        XCTAssertEqual(split.body, source)
    }

    func testParserExposesFrontMatterAndDropsItFromTheBlocks() {
        let document = MarkdownParser.parse("""
        ---
        title: Spec
        ---
        # Real Heading
        """)

        XCTAssertEqual(document.frontMatter.title, "Spec")
        XCTAssertEqual(document.blocks.count, 1)
        guard case .heading(let level, _)? = document.blocks.first else {
            return XCTFail("expected a heading, got \(document.blocks)")
        }
        XCTAssertEqual(level, 1)
    }

    // MARK: - Callouts

    func testBlockQuoteWithKindMarkerBecomesACallout() {
        let document = MarkdownParser.parse("""
        > [!WARNING]
        > This deletes everything.
        """)

        guard case .callout(let callout)? = document.blocks.first else {
            return XCTFail("expected a callout, got \(document.blocks)")
        }
        XCTAssertEqual(callout.kind, .warning)
        XCTAssertNil(callout.title)
        XCTAssertEqual(callout.content.count, 1)
    }

    func testCalloutKeepsACustomTitleFromTheMarkerLine() {
        let document = MarkdownParser.parse("""
        > [!NOTE] Read this first
        > Body text.
        """)

        guard case .callout(let callout)? = document.blocks.first else {
            return XCTFail("expected a callout, got \(document.blocks)")
        }
        XCTAssertEqual(callout.kind, .note)
        XCTAssertEqual(callout.title, "Read this first")
    }

    func testCalloutKindIsCaseInsensitive() {
        for token in ["tip", "TIP", "Tip"] {
            let document = MarkdownParser.parse("> [!\(token)]\n> Body.")
            guard case .callout(let callout)? = document.blocks.first else {
                return XCTFail("expected a callout for \(token)")
            }
            XCTAssertEqual(callout.kind, .tip)
        }
    }

    /// An unknown keyword is much more likely to be literal text than a callout kind this app
    /// has not heard of, so the block quote is left alone.
    func testUnknownCalloutKeywordStaysAnOrdinaryBlockQuote() {
        let document = MarkdownParser.parse("> [!SOMETHING]\n> Body.")

        guard case .blockQuote? = document.blocks.first else {
            return XCTFail("expected a block quote, got \(document.blocks)")
        }
    }

    func testPlainBlockQuoteIsUnaffected() {
        let document = MarkdownParser.parse("> Just a quote.")

        guard case .blockQuote? = document.blocks.first else {
            return XCTFail("expected a block quote, got \(document.blocks)")
        }
    }

    // MARK: - Math

    func testInlineMathIsExtractedFromSurroundingText() {
        let document = MarkdownParser.parse("The area is $\\pi r^2$ exactly.")

        guard case .paragraph(let inlines)? = document.blocks.first else {
            return XCTFail("expected a paragraph")
        }
        let math = inlines.compactMap { inline -> String? in
            if case .inlineMath(let source) = inline { return source }
            return nil
        }
        XCTAssertEqual(math, ["\\pi r^2"])
    }

    /// Currency is far more common in prose than math, and `$5 and $10` must not become an
    /// equation. The delimiters have to hug non-space characters.
    func testCurrencyAmountsAreNotTreatedAsMath() {
        let document = MarkdownParser.parse("It cost $5 and then $10 more.")

        guard case .paragraph(let inlines)? = document.blocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertFalse(inlines.contains { if case .inlineMath = $0 { return true } else { return false } })
    }

    func testDisplayMathBecomesItsOwnBlock() {
        let document = MarkdownParser.parse("""
        Before.

        $$
        x = \\frac{1}{2}
        $$

        After.
        """)

        let mathBlocks = document.blocks.compactMap { block -> String? in
            if case .mathBlock(let source) = block { return source }
            return nil
        }
        XCTAssertEqual(mathBlocks.count, 1)
        XCTAssertTrue(mathBlocks[0].contains("\\frac{1}{2}"))
    }

    func testSingleLineDisplayMathBecomesABlock() {
        let document = MarkdownParser.parse("$$a^2 + b^2 = c^2$$")

        guard case .mathBlock(let source)? = document.blocks.first else {
            return XCTFail("expected a math block, got \(document.blocks)")
        }
        XCTAssertEqual(source.trimmingCharacters(in: .whitespacesAndNewlines), "a^2 + b^2 = c^2")
    }

    func testMathFenceLanguageBecomesAMathBlock() {
        let document = MarkdownParser.parse("```math\nE = mc^2\n```")

        guard case .mathBlock? = document.blocks.first else {
            return XCTFail("expected a math block, got \(document.blocks)")
        }
    }

    /// A shell snippet full of `$` must stay a code block.
    func testDollarSignsInsideACodeFenceAreNotMath() {
        let document = MarkdownParser.parse("""
        ```sh
        echo $$
        echo $HOME
        ```
        """)

        guard case .codeBlock? = document.blocks.first else {
            return XCTFail("expected a code block, got \(document.blocks)")
        }
    }

    func testMathInsideACodeSpanIsNotExtracted() {
        let document = MarkdownParser.parse("Write `$x^2$` to get math.")

        guard case .paragraph(let inlines)? = document.blocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertFalse(inlines.contains { if case .inlineMath = $0 { return true } else { return false } })
        XCTAssertTrue(inlines.contains { if case .code = $0 { return true } else { return false } })
    }

    // MARK: - Math parsing

    func testMathParserReadsFractionsAndScripts() {
        let node = MathParser.parse("\\frac{a}{b}")

        guard case .fraction(let numerator, let denominator) = node else {
            return XCTFail("expected a fraction, got \(node)")
        }
        XCTAssertEqual(numerator, .identifier("a"))
        XCTAssertEqual(denominator, .identifier("b"))
    }

    func testMathParserCombinesSubscriptAndSuperscriptOnOneBase() {
        let node = MathParser.parse("x_i^2")

        guard case .subsuperscript(let base, let sub, let exponent) = node else {
            return XCTFail("expected a sub-superscript, got \(node)")
        }
        XCTAssertEqual(base, .identifier("x"))
        XCTAssertEqual(sub, .identifier("i"))
        XCTAssertEqual(exponent, .text("2"))
    }

    /// `x^2_i` and `x_i^2` are the same formula and must parse identically.
    func testScriptOrderDoesNotChangeTheResult() {
        XCTAssertEqual(MathParser.parse("x_i^2"), MathParser.parse("x^2_i"))
    }

    func testMathParserMapsGreekLettersAndOperators() {
        XCTAssertEqual(MathParser.parse("\\alpha"), .symbol("α"))
        XCTAssertEqual(MathParser.parse("\\leq"), .binaryOperator("≤"))
        XCTAssertEqual(MathParser.parse("\\sum"), .bigOperator("∑"))
    }

    /// An unknown command shows its own source instead of disappearing.
    func testUnknownMathCommandIsPreservedRatherThanDropped() {
        XCTAssertEqual(MathParser.parse("\\notacommand"), .unparsed("\\notacommand"))
    }

    func testMathParserReadsRootsWithAnIndex() {
        let node = MathParser.parse("\\sqrt[3]{x}")

        guard case .sqrt(let radicand, let index) = node else {
            return XCTFail("expected a root, got \(node)")
        }
        XCTAssertEqual(radicand, .identifier("x"))
        XCTAssertEqual(index, .text("3"))
    }

    /// `\frac12` without braces is legal TeX and means `\frac{1}{2}`.
    func testFractionWithoutBracesTakesSingleAtoms() {
        XCTAssertEqual(MathParser.parse("\\frac12"),
                       .fraction(numerator: .text("1"), denominator: .text("2")))
    }

    /// A missing closing brace must not hang the parser or eat the document.
    func testUnbalancedBracesTerminate() {
        let node = MathParser.parse("\\frac{a}{b")
        guard case .fraction = node else {
            return XCTFail("expected a fraction, got \(node)")
        }
    }

    // MARK: - Math to text

    func testInlineMathFlattensToUnicodeSuperscripts() {
        XCTAssertEqual(MathTextRenderer.string(from: "x^2"), "x²")
        XCTAssertEqual(MathTextRenderer.string(from: "a_1"), "a₁")
    }

    /// A script with no Unicode form falls back to caret notation rather than half-converting.
    func testScriptWithoutUnicodeFormFallsBackToCaretNotation() {
        XCTAssertEqual(MathTextRenderer.string(from: "x^{abc}"), "x^(abc)")
    }

    // MARK: - Mermaid

    func testMermaidFenceBecomesADiagramBlock() {
        let document = MarkdownParser.parse("```mermaid\ngraph TD\n  A --> B\n```")

        guard case .mermaid? = document.blocks.first else {
            return XCTFail("expected a mermaid block, got \(document.blocks)")
        }
    }

    func testMermaidParserReadsNodesEdgesAndLabels() {
        let diagram = MermaidParser.parse("""
        graph TD
            A[Start] --> B{Decision}
            B -->|Yes| C[Done]
        """)

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.direction, .topToBottom)
        XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(diagram.node(id: "A")?.label, "Start")
        XCTAssertEqual(diagram.node(id: "B")?.shape, .diamond)
        XCTAssertEqual(diagram.edges.count, 2)
        XCTAssertEqual(diagram.edges.last?.label, "Yes")
    }

    func testMermaidChainedEdgesProduceOneEdgePerHop() {
        let diagram = MermaidParser.parse("graph LR\n  A --> B --> C")

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.direction, .leftToRight)
        XCTAssertEqual(diagram.edges.count, 2)
        XCTAssertEqual(diagram.edges[0].from, "A")
        XCTAssertEqual(diagram.edges[0].to, "B")
        XCTAssertEqual(diagram.edges[1].from, "B")
        XCTAssertEqual(diagram.edges[1].to, "C")
    }

    func testMermaidReadsTheMidArrowLabelForm() {
        let diagram = MermaidParser.parse("graph TD\n  A -- yes --> B")

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.edges.count, 1)
        XCTAssertEqual(diagram.edges.first?.label, "yes")
    }

    func testMermaidReadsEdgeStyles() {
        let diagram = MermaidParser.parse("""
        graph TD
            A -.-> B
            B ==> C
        """)

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.edges[0].style, .dotted)
        XCTAssertEqual(diagram.edges[1].style, .thick)
    }

    /// An arrow inside a node label is part of the label, not a connector.
    func testArrowInsideANodeLabelDoesNotSplitTheLine() {
        let diagram = MermaidParser.parse("graph TD\n  A[a --> b] --> C")

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.nodes.count, 2)
        XCTAssertEqual(diagram.node(id: "A")?.label, "a --> b")
        XCTAssertEqual(diagram.edges.count, 1)
    }

    /// Only flowcharts render natively; everything else falls back to source, which the view keys
    /// off a `nil` parse.
    func testNonFlowchartDiagramsReturnNil() {
        XCTAssertNil(MermaidParser.parse("sequenceDiagram\n  Alice->>Bob: Hi"))
        XCTAssertNil(MermaidParser.parse("gantt\n  title A"))
        XCTAssertNil(MermaidParser.parse("not a diagram at all"))
    }

    func testMermaidIgnoresCommentsAndStyleDirectives() {
        let diagram = MermaidParser.parse("""
        graph TD
            %% this is a comment
            A --> B
            style A fill:#f9f
        """)

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B"])
        XCTAssertEqual(diagram.edges.count, 1)
    }

    /// A node mentioned bare first and labelled later keeps the label.
    func testLaterLabelUpgradesAnEarlierBareReference() {
        let diagram = MermaidParser.parse("""
        graph TD
            A --> B
            B[Finished]
        """)

        guard let diagram else { return XCTFail("expected a diagram") }
        XCTAssertEqual(diagram.node(id: "B")?.label, "Finished")
    }

    // MARK: - Mermaid layout

    func testLayoutRanksNodesByLongestPathFromARoot() {
        let diagram = MermaidParser.parse("graph TD\n  A --> B\n  B --> C\n  A --> C")!
        let result = MermaidLayout.layout(diagram)

        XCTAssertEqual(result.placement(for: "A")?.rank, 0)
        XCTAssertEqual(result.placement(for: "B")?.rank, 1)
        // C is reachable in one hop from A, but the longest path is two — it must sit below B.
        XCTAssertEqual(result.placement(for: "C")?.rank, 2)
    }

    func testLayoutPlacesSiblingsSideBySide() {
        let diagram = MermaidParser.parse("graph TD\n  A --> B\n  A --> C")!
        let result = MermaidLayout.layout(diagram)

        let b = result.placement(for: "B")
        let c = result.placement(for: "C")
        XCTAssertEqual(b?.rank, 1)
        XCTAssertEqual(c?.rank, 1)
        XCTAssertNotEqual(b?.frame.minX, c?.frame.minX)
        XCTAssertEqual(b?.frame.minY, c?.frame.minY)
    }

    /// Left-to-right swaps the axes: rank advances along x, siblings stack down y.
    func testLeftToRightLayoutAdvancesAlongX() {
        let diagram = MermaidParser.parse("graph LR\n  A --> B")!
        let result = MermaidLayout.layout(diagram)

        let a = result.placement(for: "A")!
        let b = result.placement(for: "B")!
        XCTAssertLessThan(a.frame.minX, b.frame.minX)
        XCTAssertEqual(a.frame.minY, b.frame.minY)
    }

    /// A cyclic graph must still lay out rather than recursing forever.
    func testCyclicGraphTerminates() {
        let diagram = MermaidParser.parse("graph TD\n  A --> B\n  B --> C\n  C --> A")!
        let result = MermaidLayout.layout(diagram)

        XCTAssertEqual(result.placements.count, 3)
        XCTAssertGreaterThan(result.size.width, 0)
    }

    func testLayoutIsDeterministic() {
        let diagram = MermaidParser.parse("graph TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D")!
        XCTAssertEqual(MermaidLayout.layout(diagram), MermaidLayout.layout(diagram))
    }
}
