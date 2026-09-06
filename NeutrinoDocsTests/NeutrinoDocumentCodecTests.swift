import XCTest
import NeutrinoOOXML
@testable import NeutrinoDocs

/// Covers the wire format a Neutrino document is stored in.
///
/// A document is a real `.docx` (issue #127), and this is the seam: the editor holds a ProseMirror
/// tree, Drive holds a Word package, and the codec is the only thing in the app that knows both.
/// What is asserted here is the app's half of that — the envelope, the fallbacks, and the promise
/// that a document opened on a phone and saved again is the same document. The mapping itself is
/// asserted where it lives, in `NeutrinoOOXMLTests`.
final class NeutrinoDocumentCodecTests: XCTestCase {

    // MARK: - Helpers

    /// A body as the codec stores it, then read straight back.
    private func roundTrip(_ body: DocumentBody, title: String = "Report",
                           images: [String: Data] = [:]) -> DocumentBody {
        NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(body, title: title, images: images))
    }

    /// A paragraph with nothing to say about itself carries no attributes at all — which is what
    /// the editor builds and what the codec reads back.
    private func paragraph(_ text: String, attrs: [String: JSONValue] = [:]) -> ProseMirrorNode {
        ProseMirrorNode(type: "paragraph", attrs: attrs.isEmpty ? nil : attrs,
                        content: [.text(text)])
    }

    // MARK: - What is stored

    func testASavedDocumentIsARealWordDocument() {
        let stored = NeutrinoDocumentCodec.encode(DocumentBody.text("Hello"), title: "Report")

        XCTAssertTrue(DocxCodec.isDocument(stored),
                      "Drive holds a .docx, and so must anything Word is asked to open")
    }

    func testAWebAuthoredDocumentDecodesToItsOwnTree() {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading", attrs: ["level": .int(1)],
                            content: [.text("Quarterly Review")]),
            ProseMirrorNode(type: "paragraph", content: [
                .text("Revenue was "),
                .text("up 12%", marks: [ProseMirrorMark(type: "bold")]),
                .text(" this quarter."),
            ]),
        ]))

        let reread = roundTrip(body)

        XCTAssertEqual(reread.blocks.map(\.type), ["heading", "paragraph"])
        XCTAssertEqual(reread.blocks.first?.attribute("level")?.intValue, 1)
        XCTAssertEqual(reread.plainText, "Quarterly Review Revenue was up 12% this quarter.")
    }

    func testAnEmptyDocumentIsStoredAndReadBackAsOne() {
        XCTAssertEqual(roundTrip(.empty).blocks, [])
    }

    // MARK: - Nothing is touched in passing

    /// A document opened on a phone and saved without being edited — which is what an autosave does
    /// — must come back as the same document.
    func testOpeningAndSavingAWebDocumentChangesNothing() {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "heading",
                            attrs: ["level": .int(1), "textAlign": .string("center")],
                            content: [.text("Title")]),
            ProseMirrorNode(type: "paragraph", attrs: ["textAlign": .string("justify")], content: [
                .text("Coloured, in Georgia.", marks: [
                    ProseMirrorMark(type: "textStyle", attrs: ["color": .string("#0a7d32"),
                                                               "fontFamily": .string("Georgia"),
                                                               "fontSize": .string("14pt")]),
                ]),
                .text(" and suggested", marks: [
                    ProseMirrorMark(type: "trackedInsertion", attrs: ["author": .string("ana")]),
                ]),
            ]),
            ProseMirrorNode(type: "table", content: [
                ProseMirrorNode(type: "tableRow", content: [
                    ProseMirrorNode(type: "tableCell",
                                    attrs: ["colspan": .int(2), "rowspan": .int(1),
                                            "colwidth": .null,
                                            "backgroundColor": .string("#eeeeee"),
                                            "borderColor": .null, "borderWidth": .null],
                                    content: [paragraph("Wide")]),
                ]),
            ]),
        ]))

        // The tree, not the whole body: a document stored with no layout block comes back with the
        // defaults every client applies to one, which is what the test below says.
        XCTAssertEqual(roundTrip(body).doc, body.doc)
    }

    /// Spelled out, because it is the guarantee a lossy converter could not make.
    func testEveryAttributeOfAWebDocumentSurvivesASave() throws {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "paragraph", attrs: ["textAlign": .string("center")], content: [
                .text("Highlighted", marks: [
                    ProseMirrorMark(type: "highlight", attrs: ["color": .string("#ffff00")]),
                ]),
            ]),
        ]))

        let paragraph = try XCTUnwrap(roundTrip(body).blocks.first)

        XCTAssertEqual(paragraph.attribute("textAlign")?.stringValue, "center")
        XCTAssertEqual(paragraph.children.first?.mark("highlight")?.attrs?["color"]?.stringValue,
                       "#ffff00")
    }

    // MARK: - The layout block

    func testTheLayoutBlockIsPreservedThroughAnEdit() throws {
        var body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [paragraph("Hi")]),
                                layout: Self.layout(watermark: "DRAFT", header: "ACME Confidential"))

        body.doc = ProseMirrorNode(type: "doc", content: [paragraph("Hi there")])
        let reread = roundTrip(body)

        XCTAssertEqual(reread.layout?["watermarkText"]?.stringValue, "DRAFT")
        XCTAssertEqual(reread.layout?["headerFooter"]?["variants"]?["default"]?["header"]?["center"]?
                        .stringValue, "ACME Confidential")
        XCTAssertEqual(reread.plainText, "Hi there")
    }

    /// Page setup is layout the phone has no editor for, and losing it would silently reset a
    /// document's margins the first time it was opened here.
    func testPageSetupSurvivesASaveMadeOnThePhone() {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [paragraph("Hi")]),
                                layout: Self.layout(pageSize: "a4", orientation: "landscape"))

        let reread = roundTrip(body)

        XCTAssertEqual(reread.layout?["pageSetup"]?["pageSize"]?.stringValue, "a4")
        XCTAssertEqual(reread.layout?["pageSetup"]?["orientation"]?.stringValue, "landscape")
    }

    /// A document stored with no layout at all still opens, and comes back with the defaults every
    /// client applies to one — not with nothing.
    func testADocumentWithoutLayoutGetsTheDefaultsRatherThanNothing() {
        let reread = roundTrip(DocumentBody.text("Plain"))

        XCTAssertEqual(reread.layout?["pageSetup"]?["pageSize"]?.stringValue, "letter")
        XCTAssertEqual(reread.layout?["docTheme"]?.stringValue, "default")
    }

    // MARK: - Images

    /// A picture is a Drive file, and a `.docx` has to carry the bytes. The reference is what the
    /// editor stores, so it has to be what comes back — not the megabytes it resolved to.
    func testAResolvedPictureIsEmbeddedAndComesBackAsAReference() {
        let image = ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:file-7"),
                                                           "width": .string("320")])
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "paragraph", content: [image]),
        ]))

        let reread = roundTrip(body, images: ["neutrino-drive:file-7": Self.png])

        XCTAssertEqual(reread.blocks.first?.children.first, image)
    }

    /// The offline case: a save that could not fetch the picture must not lose it.
    func testAnUnresolvedPictureIsStillInTheDocumentAfterASave() {
        let image = ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:file-7"),
                                                           "width": .string("320")])
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "paragraph", content: [image]),
        ]))

        XCTAssertEqual(roundTrip(body).blocks.first?.children.first, image)
    }

    func testTheSourcesACallerHasToResolveAreReported() {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "paragraph", content: [
                ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:a")]),
                ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:b")]),
                ProseMirrorNode(type: "image", attrs: ["src": .string("neutrino-drive:a")]),
            ]),
        ]))

        XCTAssertEqual(body.imageSources, ["neutrino-drive:a", "neutrino-drive:b"])
    }

    // MARK: - Writing

    /// The stored bytes have to be stable, or every autosave uploads a "changed" document.
    func testEncodingIsDeterministic() {
        let body = DocumentBody.text("One")
        XCTAssertEqual(NeutrinoDocumentCodec.encode(body, title: "R"),
                       NeutrinoDocumentCodec.encode(body, title: "R"))
    }

    // MARK: - Bodies that are not packages

    /// A body that is not a document opens as the text it is — kept, so it can be read and saved
    /// back, and not interpreted, because there is no syntax to interpret it as.
    func testABodyThatIsNotAPackageOpensAsPlainText() {
        let body = NeutrinoDocumentCodec.decode(
            Data("# Old\n\nWritten before the format changed.".utf8))

        XCTAssertEqual(body.blocks.map(\.type), ["paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(body.plainText, "# Old Written before the format changed.")
        XCTAssertNil(body.layout)
        XCTAssertTrue(DocxCodec.isDocument(NeutrinoDocumentCodec.encode(body, title: "Old")),
                      "Saving such a body must write it in the format Drive holds")
    }

    /// Every line of it, in order — nothing is dropped on the way in.
    func testEveryLineOfAPlainTextBodySurvives() {
        let body = NeutrinoDocumentCodec.decode(Data("One\nTwo\nThree".utf8))

        XCTAssertEqual(body.blocks.map(\.plainText), ["One", "Two", "Three"])
    }

    func testAnEmptyBodyDecodesToTheEmptyDocument() {
        XCTAssertEqual(NeutrinoDocumentCodec.decode(Data()), .empty)
    }

    // MARK: - Nodes this app does not model

    /// A node type from a newer web release still round-trips: the writer maps what it knows and
    /// keeps the rest as its own shape, so a column layout written on the web survives a save here.
    func testANodeThisAppDoesNotDrawIsWrittenBackUnchanged() {
        let body = DocumentBody(doc: ProseMirrorNode(type: "doc", content: [
            ProseMirrorNode(type: "columnLayout", attrs: ["columns": .int(3)], content: [
                paragraph("Inside a column."),
            ]),
        ]))

        XCTAssertEqual(roundTrip(body).doc, body.doc)
    }

    // MARK: - Fixtures

    /// The layout block as the web app writes it, with only what a test cares about filled in.
    private static func layout(watermark: String = "", header: String = "",
                               pageSize: String = "letter",
                               orientation: String = "portrait") -> JSONValue {
        func slots(_ center: String) -> JSONValue {
            .object(["left": .string(""), "center": .string(center), "right": .string("")])
        }
        let band = JSONValue.object(["header": slots(""), "footer": slots("")])
        return .object([
            "headerFooter": .object([
                "differentFirstPage": .bool(false),
                "differentEvenOdd": .bool(false),
                "headerMargin": .int(36),
                "footerMargin": .int(36),
                "variants": .object([
                    "default": .object(["header": slots(header), "footer": slots("")]),
                    "first": band,
                    "even": band,
                ]),
            ]),
            "headerText": .string(header),
            "footerText": .string(""),
            "showPageNumbers": .bool(false),
            "watermarkText": .string(watermark),
            "bgColor": .string(""),
            "docTheme": .string("default"),
            "properties": .object(["author": .string(""), "subject": .string(""),
                                   "company": .string(""), "category": .string(""),
                                   "keywords": .string(""), "manager": .string(""),
                                   "custom": .object([:])]),
            "pageSetup": .object(["marginTop": .int(72), "marginBottom": .int(72),
                                  "marginLeft": .int(72), "marginRight": .int(72),
                                  "orientation": .string(orientation),
                                  "pageSize": .string(pageSize)]),
        ])
    }

    /// A one-pixel PNG, which is enough to be embedded as a real picture.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}
