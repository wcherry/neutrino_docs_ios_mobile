import CoreTransferable
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import NeutrinoDocs

/// Phase 3 — Attachments: inserting a picture from Photos, from Files, from a link, or from Drive.
///
/// The sheet itself is SwiftUI, but everything that decides what ends up *in the document* is a
/// pure function, and that is what these cover: how large an image is allowed to get, and the node
/// it becomes.
final class InsertImageTests: XCTestCase {

    // MARK: - Helpers

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Scaling (the format documents used to be written in)

    /// An inlined picture went inside the document body, which was re-encrypted and re-uploaded on
    /// every autosave, so it was downscaled first. Nothing writes that format now — a picture is a
    /// Drive file and is stored as it came — but documents holding one are still read.
    func testALargePhotoIsScaledDownToTheLimit() {
        let scaled = EditorImage.scaledSize(for: CGSize(width: 4032, height: 3024))

        XCTAssertEqual(max(scaled.width, scaled.height), EditorImage.maximumDimension)
        XCTAssertEqual(scaled.width / scaled.height,
                       4032.0 / 3024.0,
                       accuracy: 0.01,
                       "The shape of the picture is not the app's to change")
    }

    func testAPortraitPhotoIsMeasuredOnItsLongEdge() {
        let scaled = EditorImage.scaledSize(for: CGSize(width: 3024, height: 4032))
        XCTAssertEqual(scaled.height, EditorImage.maximumDimension)
        XCTAssertLessThan(scaled.width, scaled.height)
    }

    /// Re-encoding something already small only costs it quality.
    func testASmallImageIsLeftAtItsOwnSize() {
        let size = CGSize(width: 320, height: 200)
        XCTAssertEqual(EditorImage.scaledSize(for: size), size)
    }

    func testDownscalingProducesAnImageOfTheScaledSize() {
        let scaled = EditorImage.downscaled(image(width: 3000, height: 1500))

        XCTAssertEqual(scaled.size.width, EditorImage.maximumDimension)
        XCTAssertEqual(scaled.size.height, EditorImage.maximumDimension / 2)
    }

    // MARK: - Encoding

    func testAnImageBecomesADataURIADocumentCanHold() throws {
        let uri = try EditorImage.dataURI(from: image(width: 400, height: 300))

        XCTAssertTrue(uri.hasPrefix("data:image/jpeg;base64,"))
        let base64 = String(uri.dropFirst("data:image/jpeg;base64,".count))
        XCTAssertNotNil(Data(base64Encoded: base64), "The payload has to decode")
    }

    /// The inlined result rode inside the document body, so one still enormous after resizing was
    /// refused rather than quietly slowing every save for the life of the document.
    func testAnImageIsKeptWellUnderTheSizeCeiling() throws {
        let uri = try EditorImage.dataURI(from: image(width: 4032, height: 3024))
        let base64 = String(uri.dropFirst("data:image/jpeg;base64,".count))
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))

        XCTAssertLessThan(bytes.count, EditorImage.maximumEncodedBytes)
    }

    func testSomethingThatIsNotAnImageIsRejected() {
        XCTAssertThrowsError(try EditorImage.dataURI(from: Data("not a picture".utf8)))
    }

    // MARK: - The name a picked photo is stored under

    /// Every photo used to arrive in Drive as `Image.jpg`. The name was not lost — it was never
    /// asked for: the sheet requested `Data` from the picker, and data has no name. Taking the item
    /// as a file is what exposes the one the library uses, which is the picker's `suggestedName`
    /// (`IMG_0042.HEIC`) written into the temporary file it hands over.
    func testAPickedPhotoCarriesTheLibrarysFileName() async throws {
        let photo = try await picked(named: "IMG_0042.jpeg")

        XCTAssertEqual(photo.name, "IMG_0042.jpeg")
        XCTAssertFalse(photo.data.isEmpty, "the bytes are read before the temporary file goes away")
        XCTAssertEqual(EditorImage.fileName(from: photo.name, extension: "jpeg"), "IMG_0042.jpeg")
    }

    /// A camera roll is full of pictures taken seconds apart, so two of them must not arrive as the
    /// same file — which is exactly what the old generic name did.
    func testTwoPhotosDoNotArriveUnderTheSameName() async throws {
        let first = try await picked(named: "IMG_0042.jpeg")
        let second = try await picked(named: "IMG_0043.jpeg")

        XCTAssertNotEqual(EditorImage.fileName(from: first.name, extension: "jpeg"),
                          EditorImage.fileName(from: second.name, extension: "jpeg"))
    }

    /// A photo from the camera is HEIC and is stored as JPEG, so only the stem survives: the name
    /// has to describe the bytes that were actually uploaded.
    func testATranscodedPhotoKeepsItsStemAndGainsTheStoredExtension() async throws {
        let photo = try await picked(named: "IMG_0042.HEIC")

        XCTAssertEqual(EditorImage.fileName(from: photo.name, extension: "jpg"), "IMG_0042.jpg")
    }

    /// An item the picker offers without a name of its own is still a picture worth inserting: it
    /// falls back to whatever name came with it rather than failing the insert.
    func testAPhotoWithNoNameOfItsOwnStillInserts() async throws {
        let bytes = try XCTUnwrap(image(width: 40, height: 20).jpegData(compressionQuality: 0.9))
        let provider = NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.jpeg.identifier)

        let photo: PickedPhoto = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PickedPhoto.self) { continuation.resume(with: $0) }
        }

        XCTAssertEqual(photo.data, bytes)
        // Whatever the system called it, the stored name describes the stored bytes.
        XCTAssertTrue(EditorImage.fileName(from: photo.name, extension: "jpeg").hasSuffix(".jpeg"))
    }

    /// A picked photo as the picker delivers it: bytes in a temporary file, named the way
    /// `PHPickerViewController` names one — `suggestedName` is where that name lives.
    private func picked(named name: String) async throws -> PickedPhoto {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try XCTUnwrap(image(width: 40, height: 20).jpegData(compressionQuality: 0.9)).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
        provider.suggestedName = name

        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PickedPhoto.self) { continuation.resume(with: $0) }
        }
    }

    // MARK: - What lands in the document

    /// An inserted picture is a complete `image` node, not a placeholder waiting to be filled in.
    @MainActor
    func testAnInsertedImageIsCompleteRatherThanAPlaceholder() {
        let node = EditorImageSelection.node(source: "https://example.com/cat.png", alt: "A cat",
                                             title: nil, attributes: .none)

        XCTAssertEqual(node.type, DocumentNodeType.image)
        XCTAssertEqual(node.attribute("src")?.stringValue, "https://example.com/cat.png")
        XCTAssertEqual(node.attribute("alt")?.stringValue, "A cat")
    }

    /// A description is text on the node, so there is no syntax in it to break — whatever the
    /// author calls a picture arrives exactly as they typed it.
    @MainActor
    func testADescriptionIsCarriedVerbatim() {
        let node = EditorImageSelection.node(source: "u", alt: "a [weird] name",
                                             title: nil, attributes: .none)

        XCTAssertEqual(node.attribute("alt")?.stringValue, "a [weird] name")
    }

    /// A `data:` URI is hundreds of thousands of characters and has to survive byte for byte, or
    /// the picture will not decode when the document is reopened.
    @MainActor
    func testADataURISurvivesInsertionIntact() {
        let uri = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
        let document = Doc.document(.paragraph([Doc.image(source: uri, alt: "Photo")]))

        let rebuilt = DocumentBuilder.document(from: Doc.projection(of: document))

        XCTAssertEqual(rebuilt.children.first?.children.first?.attribute("src")?.stringValue, uri)
    }

    // MARK: - Decoding what was stored

    func testADataURIDecodesBackIntoAPicture() throws {
        let uri = try EditorImage.dataURI(from: image(width: 120, height: 80))

        let decoded = EditorImageStore.decodeDataURI(uri)

        XCTAssertNotNil(decoded, "What the picker stores has to be what the editor can draw")
        XCTAssertEqual(decoded?.size.width, 120)
        XCTAssertEqual(decoded?.size.height, 80)
    }

    func testNonsenseInADataURIDecodesToNothingRatherThanTrapping() {
        XCTAssertNil(EditorImageStore.decodeDataURI("data:image/jpeg;base64,not-base64!!"))
        XCTAssertNil(EditorImageStore.decodeDataURI("https://example.com/cat.png"))
    }

    /// An inserted image is an ordinary `image` node, so everything downstream — the projection,
    /// the stored envelope, the web app — already knows what it is.
    @MainActor
    func testAnInsertedImageRoundTripsThroughTheStoredFormat() {
        let document = Doc.document(
            .paragraph([Doc.image(source: "https://example.com/cat.png", alt: "A cat")])
        )

        let reloaded = NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(DocumentBody(doc: document), title: "Notes")
        )

        XCTAssertEqual(reloaded.doc, document)
    }

    // MARK: - Showing it again after a reload

    /// The bug this fixes: a picture inserted from Drive looked right, and came back squashed after
    /// the document was reopened.
    ///
    /// Layout asks how tall an image line should be *before* anything is drawn, and it asks the
    /// store. A `data:` URI has its bytes in hand, so there is nothing to wait for — but the store
    /// used to decode it and still answer "not yet" to the caller that triggered the decode. Layout
    /// therefore sized the line for a placeholder, drawing (a moment later, on the now-warm cache)
    /// found the real picture and squeezed it into that placeholder's height, and nothing asked for
    /// another pass because a synchronous decode has no arrival to announce. Editing a character
    /// forced the re-layout that hid it, which is why only a freshly opened document showed it.
    @MainActor
    func testADataURIIsAvailableOnTheFirstAskRatherThanTheSecond() throws {
        let uri = try EditorImage.dataURI(from: image(width: 400, height: 200))
        let store = EditorImageStore()

        let first = store.image(for: uri)

        XCTAssertNotNil(first, "Nothing is being waited for — the bytes are in the URI")
        XCTAssertEqual(first?.size, store.image(for: uri)?.size,
                       "And the second ask agrees with the first")
    }

    /// What the wrong answer above actually cost: a 2:1 picture in a 300pt column is 150pt tall, and
    /// the placeholder it was being given instead is not.
    @MainActor
    func testAnImageLineIsGivenThePicturesHeightOnAColdEditor() throws {
        let uri = try EditorImage.dataURI(from: image(width: 400, height: 200))
        let store = EditorImageStore()
        let attachment = DocumentImageAttachment(source: uri, attributes: .none, store: store)

        let height = attachment.renderedSize(availableWidth: 300).height

        XCTAssertEqual(height, 150, accuracy: 1,
                       "Aspect-fit to the column, not the height of a placeholder")
    }

    /// A picture too tall for the cap is still capped — the reload fix must not let a portrait photo
    /// take the whole screen.
    @MainActor
    func testATallPictureIsStillCappedOnAColdEditor() throws {
        let uri = try EditorImage.dataURI(from: image(width: 200, height: 900))
        let store = EditorImageStore()
        let attachment = DocumentImageAttachment(source: uri, attributes: .none, store: store)

        XCTAssertEqual(attachment.renderedSize(availableWidth: 300).height,
                       DocumentImageAttachment.maximumHeight)
    }

    /// Something that will never load has to keep answering "not yet" rather than being retried on
    /// every layout pass — layout runs on every keystroke.
    @MainActor
    func testAnUnreadableSourceIsRememberedAsFailed() {
        let store = EditorImageStore()

        XCTAssertNil(store.image(for: "data:image/jpeg;base64,not-base64!!"))
        XCTAssertTrue(store.hasFailed("data:image/jpeg;base64,not-base64!!"))
    }

    /// The other half of a reload: a Drive picture is stored as a `data:` URI inside the document
    /// body, so it has to survive the trip through the stored envelope and still be recognised as a
    /// picture on the way back — an image whose source came home mangled would draw as a broken
    /// frame however good the sizing was.
    @MainActor
    func testADriveImageIsStillAPictureAfterAStoredRoundTrip() throws {
        let uri = try EditorImage.dataURI(from: image(width: 400, height: 300))
        let document = Doc.document(Doc.heading(1, "Notes"),
                                    .paragraph([Doc.image(source: uri, alt: "Sunset.jpg")]),
                                    Doc.paragraph("After."))

        let reloaded = NeutrinoDocumentCodec.decode(
            NeutrinoDocumentCodec.encode(DocumentBody(doc: document), title: "Notes")
        ).doc

        XCTAssertEqual(reloaded.children.map(\.type), document.children.map(\.type))
        let picture = reloaded.children[1].children.first
        XCTAssertEqual(picture?.type, DocumentNodeType.image)
        // The picture's bytes are stored in the package, so what comes back is the same data URI —
        // byte for byte, or it will not decode.
        XCTAssertEqual(picture?.attribute("src")?.stringValue, uri)
        XCTAssertEqual(picture?.attribute("alt")?.stringValue, "Sunset.jpg")
    }
}
