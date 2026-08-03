import XCTest
@testable import NeutrinoDocs

/// Covers the wire format a Neutrino Doc is actually stored in.
///
/// The bug these exist for: this app treated a document's body as Markdown, but the web editor and
/// the backend both store ProseMirror JSON in the same file, so every document written on the web
/// opened here as a screenful of JSON.
final class NeutrinoDocumentCodecTests: XCTestCase {

    // MARK: - Reading what the web app writes

    func testAWebAuthoredDocumentReadsAsMarkdownRatherThanJSON() {
        let stored = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":1},"content":[{"type":"text","text":"Quarterly Review"}]},
          {"type":"paragraph","content":[
            {"type":"text","text":"Revenue was "},
            {"type":"text","marks":[{"type":"bold"}],"text":"up 12%"},
            {"type":"text","text":" this quarter."}]}]}
        """

        let body = NeutrinoDocumentCodec.decode(stored)

        XCTAssertEqual(body.markdown, """
        # Quarterly Review

        Revenue was **up 12%** this quarter.
        """)
        XCTAssertFalse(body.markdown.contains("\"type\""), "The raw JSON must never reach the editor")
    }

    /// The shape the backend seeds a brand-new file with.
    func testTheBackendsEmptyDocumentReadsAsEmptyMarkdown() {
        let body = NeutrinoDocumentCodec.decode(#"{"type":"doc","content":[]}"#)
        XCTAssertEqual(body.markdown, "")
    }

    // MARK: - The layout envelope

    func testTheLayoutBlockIsPreservedThroughAnEdit() throws {
        let stored = """
        {"doc":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hi"}]}]},
         "_meta":{"headerText":"ACME Confidential","footerText":"","showPageNumbers":true,
                  "watermarkText":"DRAFT","bgColor":"#fff","docTheme":"default"}}
        """

        var body = NeutrinoDocumentCodec.decode(stored)
        XCTAssertEqual(body.markdown, "Hi")
        XCTAssertEqual(body.layout?["watermarkText"]?.stringValue, "DRAFT")

        body.markdown = "Hi there"
        let rewritten = NeutrinoDocumentCodec.encode(body)

        // The wrapper shape and every web-only setting survive a save made from the phone.
        let reread = try XCTUnwrap(ProseMirrorDocument.decode(from: rewritten))
        XCTAssertEqual(reread.layout?["watermarkText"]?.stringValue, "DRAFT")
        XCTAssertEqual(reread.layout?["headerText"]?.stringValue, "ACME Confidential")
        XCTAssertEqual(reread.layout?["showPageNumbers"]?.boolValue, true)
        XCTAssertEqual(NeutrinoDocumentCodec.decode(rewritten).markdown, "Hi there")
    }

    /// A document stored without `_meta` must not gain one — that would change its envelope for the
    /// web app, which reads the two shapes differently.
    func testADocumentWithoutLayoutIsWrittenBackWithoutOne() {
        let body = NeutrinoDocumentCodec.decode(#"{"type":"doc","content":[]}"#)
        XCTAssertNil(body.layout)
        XCTAssertFalse(NeutrinoDocumentCodec.encode(body).contains("_meta"))
    }

    // MARK: - Writing what the web app can read

    func testAnEditedDocumentIsStoredAsProseMirrorJSON() throws {
        let stored = NeutrinoDocumentCodec.encode(DocumentBody(markdown: "# Title\n\nText."))

        let document = try XCTUnwrap(ProseMirrorDocument.decode(from: stored))
        XCTAssertEqual(document.doc.type, "doc")
        XCTAssertEqual(document.doc.children.first?.type, "heading")
        XCTAssertEqual(document.doc.children.first?.attribute("level")?.intValue, 1)
        XCTAssertEqual(document.doc.children.last?.type, "paragraph")
    }

    /// An empty document still has to be a valid ProseMirror document: a `doc` with no children at
    /// all is rejected by the web editor's schema.
    func testAnEmptyDocumentIsStoredAsOneEmptyParagraph() throws {
        let document = try XCTUnwrap(
            ProseMirrorDocument.decode(from: NeutrinoDocumentCodec.encode(.empty))
        )
        XCTAssertEqual(document.doc.children.map(\.type), ["paragraph"])
    }

    // MARK: - Legacy bodies

    /// Documents this app created before it stored JSON are still readable, and are converted the
    /// first time they are saved.
    func testARawMarkdownBodyStillOpens() {
        let body = NeutrinoDocumentCodec.decode("# Old\n\nWritten before the format changed.")

        XCTAssertEqual(body.markdown, "# Old\n\nWritten before the format changed.")
        XCTAssertNil(body.layout)
        XCTAssertTrue(NeutrinoDocumentCodec.encode(body).hasPrefix("{"),
                      "Saving a legacy body must migrate it to the shared wire format")
    }

    /// Prose that merely starts with a brace is not JSON and must not be mangled.
    func testTextThatLooksLikeJSONButIsNotIsLeftAlone() {
        let markdown = "{ this is not a document }"
        XCTAssertEqual(NeutrinoDocumentCodec.decode(markdown).markdown, markdown)
    }

    // MARK: - Round trips

    /// Everything the Markdown editor can express has to survive a save and a reopen unchanged,
    /// because that is what an autosave does on every keystroke pause.
    func testMarkdownSurvivesAFullRoundTrip() {
        let cases: [(name: String, markdown: String)] = [
            ("heading",        "## A heading"),
            ("emphasis",       "Some **bold**, *italic*, and ~~struck~~ text."),
            ("code span",      "Call `reticulate(splines:)` first."),
            ("link",           "See [the docs](https://example.com/a_b)."),
            ("bullet list",    "- One\n- Two\n- Three"),
            ("ordered list",   "1. First\n2. Second"),
            ("ordered start",  "3. Third\n4. Fourth"),
            ("task list",      "- [x] Done\n- [ ] Not done"),
            ("code block",     "```swift\nlet x = 1\n```"),
            ("block quote",    "> Quoted text."),
            ("thematic break", "---"),
            ("table",          "| A | B |\n| --- | --- |\n| 1 | 2 |"),
            ("image",          "![Alt text](https://example.com/i.png)"),
            ("nested list",    "- Outer\n  - Inner"),
            ("multi block",    "# Title\n\nA paragraph.\n\n- A list item"),
        ]

        for (name, markdown) in cases {
            let stored = NeutrinoDocumentCodec.encode(DocumentBody(markdown: markdown))
            let reread = NeutrinoDocumentCodec.decode(stored).markdown
            XCTAssertEqual(reread, markdown, "\(name) did not survive the round trip")
        }
    }

    /// A second save must produce the same document as the first: a round trip that drifts would
    /// rewrite the user's file a little more on every autosave.
    func testASecondRoundTripChangesNothing() {
        let markdown = "# Title\n\nText with **bold** and a [link](https://example.com).\n\n- Item"

        let once = NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(DocumentBody(markdown: markdown))
        ).markdown
        let twice = NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(DocumentBody(markdown: once))
        ).markdown

        XCTAssertEqual(once, twice)
    }

    func testFrontMatterSurvivesARoundTrip() {
        let markdown = "---\ntitle: Notes\ntags: [swift, ios]\n---\n\n# Body"

        let reread = NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(DocumentBody(markdown: markdown))
        ).markdown

        let parsed = MarkdownParser.parse(reread)
        XCTAssertEqual(parsed.frontMatter.title, "Notes")
        XCTAssertEqual(parsed.frontMatter.tags, ["swift", "ios"])
        XCTAssertTrue(reread.contains("# Body"))
    }

    // MARK: - Escaping

    /// Text the web app stored as plain characters must not become syntax when it is read as
    /// Markdown and written back.
    func testProseThatLooksLikeMarkdownIsNotReinterpreted() {
        let stored = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"- not a list, and 2 * 3 * 4"}]},
          {"type":"paragraph","content":[{"type":"text","text":"# not a heading"}]}]}
        """

        let markdown = NeutrinoDocumentCodec.decode(stored).markdown
        let blocks = MarkdownParser.parse(markdown).blocks

        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            guard case .paragraph = block else {
                return XCTFail("Prose was re-read as \(block) instead of a paragraph")
            }
        }
    }

    /// Mid-word underscores are literal in CommonMark, so escaping them would put backslashes in
    /// front of every identifier the user reads in the editor.
    func testIdentifiersAreNotStrewnWithBackslashes() {
        let stored = """
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"Call read_plaintext on the store."}]}]}
        """

        XCTAssertEqual(NeutrinoDocumentCodec.decode(stored).markdown,
                       "Call read_plaintext on the store.")
    }

    // MARK: - Nodes this app has no syntax for

    /// A node type this app does not model contributes its text instead of vanishing.
    func testAnUnknownWrapperNodeStillContributesItsText() {
        let stored = """
        {"type":"doc","content":[
          {"type":"columnLayout","content":[
            {"type":"paragraph","content":[{"type":"text","text":"Inside a column."}]}]}]}
        """

        XCTAssertEqual(NeutrinoDocumentCodec.decode(stored).markdown, "Inside a column.")
    }

    /// The web app's tracked-change marks wrap ordinary text; the text has to come through even
    /// though the mark itself has no Markdown spelling.
    func testTextUnderAnUnknownMarkIsStillReadable() {
        let stored = """
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","marks":[{"type":"trackedInsertion","attrs":{"author":"ana"}}],
           "text":"newly added"}]}]}
        """

        XCTAssertEqual(NeutrinoDocumentCodec.decode(stored).markdown, "newly added")
    }

    // MARK: - Encoding details

    func testAHardBreakBecomesALineBreakAndBack() {
        let stored = """
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"first"},{"type":"hardBreak"},{"type":"text","text":"second"}]}]}
        """

        let markdown = NeutrinoDocumentCodec.decode(stored).markdown
        XCTAssertEqual(markdown, "first  \nsecond")

        let rewritten = ProseMirrorDocument.decode(from: NeutrinoDocumentCodec.encode(
            DocumentBody(markdown: markdown)
        ))
        let inlineTypes = rewritten?.doc.children.first?.children.map(\.type)
        XCTAssertEqual(inlineTypes, ["text", "hardBreak", "text"])
    }

    /// A code block whose content holds a triple backtick must not end its own fence.
    func testACodeBlockContainingBackticksIsFencedLongEnough() {
        let stored = """
        {"type":"doc","content":[{"type":"codeBlock","attrs":{"language":"md"},
          "content":[{"type":"text","text":"``` not the end"}]}]}
        """

        let markdown = NeutrinoDocumentCodec.decode(stored).markdown
        guard case .codeBlock(let code, let language)? = MarkdownParser.parse(markdown).blocks.first else {
            return XCTFail("Expected a code block, got \(markdown)")
        }
        XCTAssertEqual(language, "md")
        XCTAssertEqual(code.trimmingCharacters(in: .newlines), "``` not the end")
    }

    /// The stored bytes have to be stable, or every autosave uploads a "changed" document.
    func testEncodingIsDeterministic() {
        let body = DocumentBody(markdown: "# One\n\n- a\n- b")
        XCTAssertEqual(NeutrinoDocumentCodec.encode(body), NeutrinoDocumentCodec.encode(body))
    }
}
