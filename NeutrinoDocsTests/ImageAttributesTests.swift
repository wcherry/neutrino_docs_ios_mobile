import XCTest
import UIKit
@testable import NeutrinoDocs

/// Phase 3 — Attachments: an image's width, position, border, shadow, tint and caption.
///
/// The attributes are the web editor's, and the point of most of what follows is that they survive
/// the trip through this app: a document styled on the web, opened on a phone and autosaved —
/// which it does within seconds, unprompted — has to come back with every one of them intact.
final class ImageAttributesTests: XCTestCase {

    // MARK: - Not losing what the web wrote

    /// The regression: a web-styled image, opened on a phone and saved back.
    func testAWebStyledImageSurvivesBeingOpenedAndSavedOnAPhone() throws {
        let stored = """
        {"type":"doc","content":[{"type":"paragraph","content":[
        {"type":"image","attrs":{"src":"cat.png","alt":"A cat","title":null,"width":"50%",
        "alignment":"center","shadow":"md","border":"2px solid #333",
        "imageFilter":"brightness(90%)","caption":"My cat"}}]}]}
        """

        let body = NeutrinoDocumentCodec.decode(stored)
        let saved = NeutrinoDocumentCodec.encode(body)
        let image = try XCTUnwrap(imageNode(in: saved))

        XCTAssertEqual(image["src"]?.stringValue, "cat.png")
        XCTAssertEqual(image["width"]?.stringValue, "50%")
        XCTAssertEqual(image["alignment"]?.stringValue, "center")
        XCTAssertEqual(image["shadow"]?.stringValue, "md")
        XCTAssertEqual(image["border"]?.stringValue, "2px solid #333")
        XCTAssertEqual(image["imageFilter"]?.stringValue, "brightness(90%)")
        XCTAssertEqual(image["caption"]?.stringValue, "My cat")
    }

    /// An attribute a later web release adds must not be deleted by a phone that has never heard of
    /// it — the failure would be silent and permanent.
    func testAnAttributeThisAppDoesNotKnowIsCarriedThroughAnyway() throws {
        let stored = """
        {"type":"doc","content":[{"type":"paragraph","content":[
        {"type":"image","attrs":{"src":"cat.png","alt":"","objectFit":"cover"}}]}]}
        """

        let saved = NeutrinoDocumentCodec.encode(NeutrinoDocumentCodec.decode(stored))

        XCTAssertEqual(try XCTUnwrap(imageNode(in: saved))["objectFit"]?.stringValue, "cover")
    }

    /// The web's defaults are null: an unstyled picture arrives as an unstyled node rather than
    /// one carrying six attributes that say "nothing special".
    func testAPlainImageGainsNoAttributes() throws {
        let document = Doc.document(.paragraph([Doc.image(source: "cat.png", alt: "A cat")]))
        let saved = NeutrinoDocumentCodec.encode(DocumentBody(doc: document))
        let image = try XCTUnwrap(imageNode(in: saved))

        XCTAssertEqual(image["src"]?.stringValue, "cat.png")
        XCTAssertNil(image["width"])
        XCTAssertNil(image["shadow"])
        XCTAssertNil(image["alignment"], "The web's default is \"none\"; saying so adds nothing")
    }

    private func imageNode(in stored: String) -> [String: JSONValue]? {
        guard let document = ProseMirrorDocument.decode(from: stored) else { return nil }

        func find(_ node: ProseMirrorNode) -> ProseMirrorNode? {
            if node.type == "image" { return node }
            for child in node.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(document.doc).flatMap(\.attrs)
    }

    // MARK: - CSS

    func testWidthInPerCentIsOfTheColumn() {
        var attributes = ImageAttributes()
        attributes.width = "50%"

        XCTAssertEqual(attributes.drawnWidth(naturalWidth: 1000, availableWidth: 300), 150)
    }

    func testWidthInPixelsIsTakenAsPoints() {
        var attributes = ImageAttributes()
        attributes.width = "120px"

        XCTAssertEqual(attributes.drawnWidth(naturalWidth: 1000, availableWidth: 300), 120)
    }

    /// Nothing may be drawn wider than the column, whatever it asks for.
    func testAWidthLargerThanTheColumnIsClamped() {
        var attributes = ImageAttributes()
        attributes.width = "900px"

        XCTAssertEqual(attributes.drawnWidth(naturalWidth: 1000, availableWidth: 300), 300)
    }

    func testNoWidthMeansTheSmallerOfTheColumnAndThePicture() {
        XCTAssertEqual(ImageAttributes.none.drawnWidth(naturalWidth: 100, availableWidth: 300), 100)
        XCTAssertEqual(ImageAttributes.none.drawnWidth(naturalWidth: 900, availableWidth: 300), 300)
        var auto = ImageAttributes()
        auto.width = "auto"
        XCTAssertEqual(auto.drawnWidth(naturalWidth: 100, availableWidth: 300), 100)
    }

    func testABorderIsReadInAnyOrder() throws {
        let border = try XCTUnwrap(ImageAttributes.Border(css: "2px dashed #336699"))

        XCTAssertEqual(border.width, 2)
        XCTAssertEqual(border.style, .dashed)
        XCTAssertEqual(border.color, UIColor(red: 0x33 / 255, green: 0x66 / 255, blue: 0x99 / 255,
                                             alpha: 1))
        XCTAssertEqual(ImageAttributes.Border(css: "solid red 4px")?.width, 4)
    }

    func testAThreeDigitHexIsExpanded() {
        XCTAssertEqual(ImageAttributes.color("#333"),
                       UIColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1))
    }

    func testABorderOfNoneIsNoBorder() {
        XCTAssertNil(ImageAttributes.Border(css: "none"))
        XCTAssertNil(ImageAttributes.Border(css: "0px solid #333"))
        XCTAssertNil(ImageAttributes.Border(css: nil))
    }

    func testAFilterIsReadAsMultipliers() throws {
        let filter = try XCTUnwrap(ImageAttributes.Filter(css: "brightness(80%) saturate(120%)"))

        XCTAssertEqual(filter.brightness, 0.8, accuracy: 0.001)
        XCTAssertEqual(filter.contrast, 1, "Anything the CSS omits is left alone")
        XCTAssertEqual(filter.saturation, 1.2, accuracy: 0.001)
    }

    /// The web omits any component still at 100%, and so does this.
    func testAFilterWritesOnlyWhatChanged() {
        XCTAssertEqual(ImageAttributes.Filter.css(brightness: 0.9, contrast: 1, saturation: 1),
                       "brightness(90%)")
        XCTAssertNil(ImageAttributes.Filter.css(brightness: 1, contrast: 1, saturation: 1))
    }
}
