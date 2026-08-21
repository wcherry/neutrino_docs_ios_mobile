import UIKit
import XCTest
@testable import NeutrinoDocs

/// How the editor turns a stored source into a picture.
///
/// Three kinds reach it and they load differently, which is the whole of this file. A
/// `neutrino-drive:` reference — what a document written now holds — names an end-to-end encrypted
/// Drive file, so it has to be fetched and decrypted before anything can be drawn, and only the
/// signed-in session can do that. A `data:` URI carries its own bytes and answers immediately. Both
/// of the older kinds still work, because documents written before the reference format are still
/// opened and are not rewritten.
@MainActor
final class EditorImageStoreTests: XCTestCase {

    /// 20x10 actual pixels — the renderer would otherwise use the screen's scale and produce three
    /// times that, which is the difference between asserting a decoded size and asserting the
    /// simulator's.
    private func picture(_ colour: UIColor = .systemIndigo) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }.pngData()!
    }

    /// Waits for the store's background load to report back.
    private func awaitLoad(_ store: EditorImageStore, _ start: () -> Void) async {
        let arrived = expectation(description: "onLoad")
        store.onLoad = { arrived.fulfill() }
        start()
        await fulfillment(of: [arrived], timeout: 2)
    }

    // MARK: - Drive references

    func testAReferenceIsResolvedThroughTheInjectedFetch() async {
        let store = EditorImageStore()
        let bytes = picture()
        var asked: [String] = []
        store.resolveAttachment = { fileID in
            asked.append(fileID)
            return bytes
        }

        let source = DriveImageReference.source(fileID: "img-42")
        await awaitLoad(store) { _ = store.image(for: source) }

        XCTAssertEqual(asked, ["img-42"], "the file id, not the whole reference")
        XCTAssertNotNil(store.image(for: source))
        XCTAssertFalse(store.hasFailed(source))
    }

    /// Layout asks for a picture's size on every pass and drawing asks for it on every frame, so a
    /// reference resolved once must not be fetched again.
    func testAResolvedReferenceIsFetchedOnce() async {
        let store = EditorImageStore()
        let bytes = picture()
        var fetches = 0
        store.resolveAttachment = { _ in
            fetches += 1
            return bytes
        }

        let source = DriveImageReference.source(fileID: "img-1")
        await awaitLoad(store) { _ = store.image(for: source) }
        for _ in 0..<10 { _ = store.image(for: source) }

        XCTAssertEqual(fetches, 1)
    }

    /// An in-flight reference must not be started again by the next layout pass, which happens
    /// immediately and repeatedly.
    func testAReferenceIsNotFetchedAgainWhileItIsStillArriving() async {
        let store = EditorImageStore()
        let bytes = picture()
        var fetches = 0
        store.resolveAttachment = { _ in
            fetches += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return bytes
        }

        let source = DriveImageReference.source(fileID: "img-1")
        await awaitLoad(store) {
            for _ in 0..<5 { _ = store.image(for: source) }
        }

        XCTAssertEqual(fetches, 1)
    }

    func testAReferenceThatCannotBeFetchedFails() async {
        struct Denied: Error {}
        let store = EditorImageStore()
        store.resolveAttachment = { _ in throw Denied() }

        let source = DriveImageReference.source(fileID: "img-1")
        await awaitLoad(store) { _ = store.image(for: source) }

        XCTAssertNil(store.image(for: source))
        XCTAssertTrue(store.hasFailed(source), "a picture that cannot arrive draws the placeholder")
    }

    /// Bytes that arrive but are not an image are a failure like any other — there is nothing the
    /// drawing could do differently about it.
    func testBytesThatAreNotAPictureFail() async {
        let store = EditorImageStore()
        store.resolveAttachment = { _ in Data("not a picture".utf8) }

        let source = DriveImageReference.source(fileID: "img-1")
        await awaitLoad(store) { _ = store.image(for: source) }

        XCTAssertTrue(store.hasFailed(source))
    }

    /// A store with nothing to resolve through — a preview, a test, a document opened before the
    /// services were wired — must say so now rather than hold a gap open for the session.
    func testAReferenceFailsImmediatelyWithNoResolver() {
        let store = EditorImageStore()
        let source = DriveImageReference.source(fileID: "img-1")

        XCTAssertNil(store.image(for: source))
        XCTAssertTrue(store.hasFailed(source))
    }

    // MARK: - Documents written before the reference format

    func testADataURIStillDecodesOnTheFirstAsk() throws {
        let store = EditorImageStore()
        let uri = try EditorImage.dataURI(from: UIImage(data: picture())!)

        // Answered on the first call, not the next one: layout is asking how tall the line is, and
        // a "not yet" here sizes it for a placeholder that nothing would correct.
        XCTAssertNotNil(store.image(for: uri))
    }

    func testAnUnreadableSourceFails() {
        let store = EditorImageStore()
        XCTAssertNil(store.image(for: "cat.png"))
        XCTAssertTrue(store.hasFailed("cat.png"))
    }

    // MARK: - Decoding

    /// What makes storing originals affordable on a phone. Drive holds the picture at full
    /// resolution; `UIImage(data:)` would hold all of it in memory to draw a thumbnail — about
    /// 48 MB of bitmap for a 12-megapixel photograph, so a document showing five would be killed
    /// for the memory before it finished drawing.
    func testAHugePictureIsDecodedToABoundedSize() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        let data = try XCTUnwrap(renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024))
        }.jpegData(compressionQuality: 0.9))

        let decoded = try XCTUnwrap(EditorImageStore.image(from: data))

        XCTAssertEqual(max(decoded.size.width, decoded.size.height),
                       EditorImageStore.maximumDecodedPixels)
        XCTAssertEqual(decoded.size.width / decoded.size.height, 4032.0 / 3024.0, accuracy: 0.01,
                       "the shape of the picture is not the app's to change")
    }

    /// Bounded, not enlarged: a small picture is decoded at its own size.
    func testASmallPictureIsDecodedAtItsOwnSize() throws {
        let data = try XCTUnwrap(picture())

        let decoded = try XCTUnwrap(EditorImageStore.image(from: data))

        XCTAssertEqual(decoded.size, CGSize(width: 20, height: 10))
    }
}
