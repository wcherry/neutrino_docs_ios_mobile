import XCTest
@testable import NeutrinoDocs

/// Covers the wire format a Neutrino Doc is stored in.
///
/// The codec used to translate between the stored ProseMirror JSON and a narrower editing format.
/// Everything that narrower format could not say — colour, font, alignment,
/// tracked changes — was lost on the way through, so opening a web-authored document on a phone and
/// letting it autosave quietly rewrote it. The editor now holds the same tree the file stores, and
/// this is what is left: the envelope, and the promise that nothing is touched in passing.
final class NeutrinoDocumentCodecTests: XCTestCase {

    // MARK: - Reading what the web app writes

    func testAWebAuthoredDocumentDecodesToItsOwnTree() {
        let stored = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":1},"content":[{"type":"text","text":"Quarterly Review"}]},
          {"type":"paragraph","content":[
            {"type":"text","text":"Revenue was "},
            {"type":"text","marks":[{"type":"bold"}],"text":"up 12%"},
            {"type":"text","text":" this quarter."}]}]}
        """

        let body = NeutrinoDocumentCodec.decode(stored)

        XCTAssertEqual(body.blocks.map(\.type), ["heading", "paragraph"])
        XCTAssertEqual(body.blocks.first?.attribute("level")?.intValue, 1)
        XCTAssertEqual(body.plainText, "Quarterly Review Revenue was up 12% this quarter.")
    }

    /// The shape the backend seeds a brand-new file with.
    func testTheBackendsEmptyDocumentDecodesToAnEmptyTree() {
        let body = NeutrinoDocumentCodec.decode(#"{"type":"doc","content":[]}"#)
        XCTAssertEqual(body.blocks, [])
        XCTAssertNil(body.layout)
    }

    // MARK: - Nothing is touched in passing

    /// The bug this whole change exists for. A document opened on a phone and saved without being
    /// edited — which is what an autosave does — must come back byte-identical.
    func testOpeningAndSavingAWebDocumentChangesNothing() {
        let stored = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":1,"textAlign":"center"},
           "content":[{"type":"text","text":"Title"}]},
          {"type":"paragraph","attrs":{"textAlign":"justify"},"content":[
            {"type":"text","marks":[{"type":"textStyle","attrs":{"color":"#0a7d32",
             "fontFamily":"Georgia","fontSize":"14px"}}],"text":"Coloured, in Georgia."},
            {"type":"text","marks":[{"type":"trackedInsertion","attrs":{"author":"ana"}}],
             "text":" and suggested"}]},
          {"type":"table","content":[{"type":"tableRow","content":[
            {"type":"tableCell","attrs":{"colspan":2,"backgroundColor":"#eee"},
             "content":[{"type":"paragraph","content":[{"type":"text","text":"Wide"}]}]}]}]}]}
        """

        let reencoded = NeutrinoDocumentCodec.encode(NeutrinoDocumentCodec.decode(stored))

        XCTAssertEqual(ProseMirrorDocument.decode(from: reencoded),
                       ProseMirrorDocument.decode(from: stored))
    }

    /// Spelled out, because it is the guarantee the old codec could not make.
    func testEveryAttributeOfAWebDocumentSurvivesASave() throws {
        let stored = """
        {"type":"doc","content":[
          {"type":"paragraph","attrs":{"textAlign":"center","lineHeight":1.5},"content":[
            {"type":"text","marks":[{"type":"highlight","attrs":{"color":"#ffff00"}}],
             "text":"Highlighted"}]}]}
        """

        let reencoded = NeutrinoDocumentCodec.encode(NeutrinoDocumentCodec.decode(stored))
        let document = try XCTUnwrap(ProseMirrorDocument.decode(from: reencoded))
        let paragraph = document.doc.children[0]

        XCTAssertEqual(paragraph.attribute("textAlign")?.stringValue, "center")
        XCTAssertNotNil(paragraph.attribute("lineHeight"), "A web-only attribute is still there")
        XCTAssertEqual(paragraph.children.first?.mark("highlight")?.attrs?["color"]?.stringValue,
                       "#ffff00")
    }

    // MARK: - The layout envelope

    func testTheLayoutBlockIsPreservedThroughAnEdit() throws {
        let stored = """
        {"doc":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hi"}]}]},
         "_meta":{"headerText":"ACME Confidential","footerText":"","showPageNumbers":true,
                  "watermarkText":"DRAFT","bgColor":"#fff","docTheme":"default"}}
        """

        var body = NeutrinoDocumentCodec.decode(stored)
        XCTAssertEqual(body.plainText, "Hi")
        XCTAssertEqual(body.layout?["watermarkText"]?.stringValue, "DRAFT")

        body.doc = DocumentBody.text("Hi there").doc
        let rewritten = NeutrinoDocumentCodec.encode(body)

        // The wrapper shape and every web-only setting survive a save made from the phone.
        let reread = try XCTUnwrap(ProseMirrorDocument.decode(from: rewritten))
        XCTAssertEqual(reread.layout?["watermarkText"]?.stringValue, "DRAFT")
        XCTAssertEqual(reread.layout?["headerText"]?.stringValue, "ACME Confidential")
        XCTAssertEqual(reread.layout?["showPageNumbers"]?.boolValue, true)
        XCTAssertEqual(NeutrinoDocumentCodec.decode(rewritten).plainText, "Hi there")
    }

    /// A document stored without `_meta` must not gain one — that would change its envelope for the
    /// web app, which reads the two shapes differently.
    func testADocumentWithoutLayoutIsWrittenBackWithoutOne() {
        let body = NeutrinoDocumentCodec.decode(#"{"type":"doc","content":[]}"#)
        XCTAssertNil(body.layout)
        XCTAssertFalse(NeutrinoDocumentCodec.encode(body).contains("_meta"))
    }

    // MARK: - Writing

    func testAnEditedDocumentIsStoredAsProseMirrorJSON() throws {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading", attrs: ["level": .int(1)],
                            content: [.text("Title")]),
            .paragraph([.text("Text.")]),
        ]))

        let document = try XCTUnwrap(
            ProseMirrorDocument.decode(from: NeutrinoDocumentCodec.encode(body))
        )
        XCTAssertEqual(document.doc.type, "doc")
        XCTAssertEqual(document.doc.children.map(\.type), ["heading", "paragraph"])
        XCTAssertEqual(document.doc.children.first?.attribute("level")?.intValue, 1)
    }

    /// The stored bytes have to be stable, or every autosave uploads a "changed" document.
    func testEncodingIsDeterministic() {
        let body = DocumentBody.text("One")
        XCTAssertEqual(NeutrinoDocumentCodec.encode(body), NeutrinoDocumentCodec.encode(body))
    }

    // MARK: - Legacy bodies

    /// Documents whose bodies are not ProseMirror JSON still open, with
    /// their structure, and are migrated the first time they are saved.
    /// A body that is not a document opens as the text it is — kept, so it can be read and saved
    /// back, and not interpreted, because there is no syntax to interpret it as.
    func testABodyThatIsNotADocumentOpensAsPlainText() {
        let body = NeutrinoDocumentCodec.decode("# Old\n\nWritten before the format changed.")

        XCTAssertEqual(body.blocks.map(\.type), ["paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(body.plainText, "# Old Written before the format changed.")
        XCTAssertNil(body.layout)
        XCTAssertTrue(NeutrinoDocumentCodec.encode(body).hasPrefix("{"),
                      "Saving such a body must write it in the shared wire format")
    }

    /// Every line of it, in order — nothing is dropped on the way in.
    func testEveryLineOfAPlainTextBodySurvives() {
        let body = NeutrinoDocumentCodec.decode("One\nTwo\nThree")

        XCTAssertEqual(body.blocks.map(\.plainText), ["One", "Two", "Three"])
    }

    /// Prose that merely starts with a brace is not JSON and must not be mangled.
    func testTextThatLooksLikeJSONButIsNotIsKeptAsProse() {
        let body = NeutrinoDocumentCodec.decode("{ this is not a document }")
        XCTAssertEqual(body.blocks.map(\.type), ["paragraph"])
        XCTAssertEqual(body.plainText, "{ this is not a document }")
    }

    func testAnEmptyBodyDecodesToTheEmptyDocument() {
        XCTAssertEqual(NeutrinoDocumentCodec.decode("   \n  "), .empty)
    }

    // MARK: - Nodes this app does not model

    /// A node type from a newer web release is stored again exactly as it arrived, rather than
    /// being reduced to what a phone can draw.
    func testAnUnknownNodeIsWrittenBackUnchanged() {
        let stored = """
        {"type":"doc","content":[
          {"type":"columnLayout","attrs":{"columns":3},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"Inside a column."}]}]}]}
        """

        XCTAssertEqual(ProseMirrorDocument.decode(from:
                            NeutrinoDocumentCodec.encode(NeutrinoDocumentCodec.decode(stored))),
                       ProseMirrorDocument.decode(from: stored))
    }
}
