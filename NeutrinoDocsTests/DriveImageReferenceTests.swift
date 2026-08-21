import XCTest
@testable import NeutrinoDocs

/// The `neutrino-drive:<fileId>` reference a document stores in place of a picture.
///
/// The spelling is shared with the web app's `driveImageRef` / `parseDriveImageRef`
/// (`web/apps/web/src/lib/driveImages.ts`) and both apps read and write the same file, so these
/// assert the exact string rather than merely that it round-trips: a reference this app wrote and
/// only this app could read would look correct here and show nothing in the web editor.
final class DriveImageReferenceTests: XCTestCase {

    // MARK: - Building

    func testAReferenceIsTheSchemeFollowedByTheFileID() {
        XCTAssertEqual(DriveImageReference.source(fileID: "abc-123"), "neutrino-drive:abc-123")
    }

    func testTheSchemeIsTheOneTheWebAppWrites() {
        XCTAssertEqual(DriveImageReference.scheme, "neutrino-drive:")
    }

    // MARK: - Parsing

    func testParsingReturnsTheFileID() {
        XCTAssertEqual(DriveImageReference.fileID(from: "neutrino-drive:abc-123"), "abc-123")
    }

    func testRoundTrip() {
        let id = "9f8e7d6c-5b4a-4321-9876-0123456789ab"
        XCTAssertEqual(DriveImageReference.fileID(from: DriveImageReference.source(fileID: id)), id)
    }

    /// A source travels as text, where a stray space either side of it is
    /// invisible on screen and easy to introduce by hand.
    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(DriveImageReference.fileID(from: "neutrino-drive: abc-123 "), "abc-123")
    }

    func testAReferenceWithNoIDIsNotAReference() {
        XCTAssertNil(DriveImageReference.fileID(from: "neutrino-drive:"))
        XCTAssertNil(DriveImageReference.fileID(from: "neutrino-drive:   "))
    }

    // MARK: - What is not a reference

    /// Documents written before this format hold these, and both still render — so neither may be
    /// mistaken for a reference and sent to Drive.
    func testSourcesFromOlderDocumentsArePassedOver() {
        XCTAssertNil(DriveImageReference.fileID(from: "https://example.com/cat.png"))
        XCTAssertNil(DriveImageReference.fileID(from: "http://example.com/cat.png"))
        XCTAssertNil(DriveImageReference.fileID(from: "data:image/jpeg;base64,AAAA"))
        XCTAssertNil(DriveImageReference.fileID(from: "cat.png"))
        XCTAssertNil(DriveImageReference.fileID(from: ""))
    }

    /// The scheme is matched at the start, not anywhere: a URL that mentions it in a query string
    /// is still a URL.
    func testTheSchemeOnlyCountsAtTheStart() {
        XCTAssertNil(DriveImageReference.fileID(from: "https://x.test/?to=neutrino-drive:abc"))
    }

    func testIsReferenceAgreesWithParsing() {
        XCTAssertTrue(DriveImageReference.isReference("neutrino-drive:abc"))
        XCTAssertFalse(DriveImageReference.isReference("https://example.com/cat.png"))
    }

    // MARK: - In a document

    /// A reference has to survive being projected and read back — it is the src of an image node
    /// like any other, and a destination containing a colon is the thing worth checking.
    func testAReferenceSurvivesTheEditorsProjection() {
        let image = Doc.image(source: DriveImageReference.source(fileID: "file-1"), alt: "A cat")
        let document = Doc.document(.paragraph([image]))

        let rebuilt = DocumentBuilder.document(from: Doc.projection(of: document))
        let found = rebuilt.children.first?.children.first

        XCTAssertEqual(found?.type, DocumentNodeType.image)
        XCTAssertEqual(found?.attribute("src")?.stringValue, "neutrino-drive:file-1")
        XCTAssertEqual(found?.attribute("alt")?.stringValue, "A cat")
    }

    /// A picture in Drive is styled like any other, and its styling has to survive the same trip.
    func testAReferenceKeepsItsAttributes() {
        var attributes = ImageAttributes()
        attributes.width = "50%"
        attributes.alignment = .center

        let document = Doc.document(
            .paragraph([Doc.image(source: "neutrino-drive:file-1", attributes: attributes)])
        )
        let rebuilt = DocumentBuilder.document(from: Doc.projection(of: document))
        let found = rebuilt.children.first?.children.first

        XCTAssertEqual(found?.attribute("src")?.stringValue, "neutrino-drive:file-1")
        XCTAssertEqual(ImageAttributes(proseMirror: found?.attrs).alignment, .center)
        XCTAssertEqual(ImageAttributes(proseMirror: found?.attrs).width, "50%")
    }
}
