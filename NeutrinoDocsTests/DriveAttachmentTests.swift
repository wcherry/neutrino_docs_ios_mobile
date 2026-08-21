import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
import Sodium
@testable import NeutrinoDocs

/// Getting a picture into Drive and back out again.
///
/// A document stores only `neutrino-drive:<fileId>`, so a picture is a Drive file like any other:
/// uploaded into the account's Attachments folder under a fresh key of its own, and downloaded and
/// decrypted whenever it has to be drawn. The crypto here is real — a real X25519 pair in the
/// Keychain, real secretstream, real `crypto_box_seal` — because a picture this app writes has to
/// be one the web app can open, and faking the envelope would assert nothing about that.
@MainActor
final class DriveAttachmentTests: XCTestCase {

    private var sut: DocContentService!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        sut = DocContentService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Routes by path so a test can describe a whole conversation rather than a single reply.
    private func route(_ table: [(match: String, status: Int, body: Data)]) {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            for entry in table where path.contains(entry.match) || query.contains(entry.match) {
                return (Self.response(request, entry.status), entry.body)
            }
            return (Self.response(request, 404), Data())
        }
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Attachments folder

    func testTheAttachmentsFolderIsFoundInTheDriveRoot() async throws {
        route([
            (match: "/drive/folders/\(TestTokens.userId)", status: 200,
             body: json(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#)),
        ])

        let id = try await sut.attachmentsFolderID()

        XCTAssertEqual(id, "f-1")
        // Addressed by the user's own id: the Drive root has no folder row of its own.
        XCTAssertTrue(MockURLProtocol.requests.contains {
            $0.url?.path == "/api/v1/drive/folders/\(TestTokens.userId)"
        })
    }

    /// The backend seeds the folder at registration, but accounts that predate that have none —
    /// and the name has to match however the other clients cased it.
    func testTheFolderIsMatchedWithoutRegardToCase() async throws {
        route([
            (match: "/drive/folders/\(TestTokens.userId)", status: 200,
             body: json(#"{"folders":[{"id":"f-2","name":"attachments"}],"files":[]}"#)),
        ])

        let id = try await sut.attachmentsFolderID()
        XCTAssertEqual(id, "f-2")
    }

    func testTheFolderIsCreatedWhenTheAccountHasNone() async throws {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/api/v1/drive/folders" {
                return (Self.response(request, 200), Data(#"{"id":"new-1","name":"Attachments"}"#.utf8))
            }
            return (Self.response(request, 200), Data(#"{"folders":[],"files":[]}"#.utf8))
        }

        let id = try await sut.attachmentsFolderID()

        XCTAssertEqual(id, "new-1")
        let create = MockURLProtocol.requests.first { $0.httpMethod == "POST" }
        XCTAssertEqual(create?.url?.path, "/api/v1/drive/folders")
    }

    /// Inserting ten pictures must not list the Drive root ten times.
    func testTheFolderIsLookedUpOnce() async throws {
        route([
            (match: "/drive/folders/\(TestTokens.userId)", status: 200,
             body: json(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#)),
        ])

        _ = try await sut.attachmentsFolderID()
        _ = try await sut.attachmentsFolderID()
        _ = try await sut.attachmentsFolderID()

        XCTAssertEqual(MockURLProtocol.requests.filter {
            $0.url?.path == "/api/v1/drive/folders/\(TestTokens.userId)"
        }.count, 1)
    }

    /// A failure must not be remembered: an upload that failed while the device was offline has to
    /// be able to succeed on the next try.
    func testAFailedLookupIsRetried() async {
        route([(match: "/drive/folders", status: 500, body: Data())])
        _ = try? await sut.attachmentsFolderID()

        route([
            (match: "/drive/folders/\(TestTokens.userId)", status: 200,
             body: json(#"{"folders":[{"id":"f-9","name":"Attachments"}],"files":[]}"#)),
        ])
        let id = try? await sut.attachmentsFolderID()

        XCTAssertEqual(id, "f-9")
    }

    // MARK: - Upload

    func testUploadingAPictureStoresItEncryptedAndReturnsItsFileID() async throws {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") {
                return (Self.response(request, 200), Data(#"""
                {"id":"img-7","name":"Photo.jpg","folderId":"f-1","sizeBytes":12,
                 "mimeType":"image/jpeg","updatedAt":"2026-08-14T00:00:00Z"}
                """#.utf8))
            }
            if path.hasSuffix("/key") { return (Self.response(request, 200), Data()) }
            return (Self.response(request, 200),
                    Data(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#.utf8))
        }

        let bytes = Data("pretend this is a JPEG".utf8)
        let id = try await sut.uploadAttachment(bytes, name: "Photo.jpg", mimeType: "image/jpeg")

        XCTAssertEqual(id, "img-7")

        // Into Attachments, and never in the clear.
        let upload = MockURLProtocol.requests.firstIndex { $0.url?.path.hasSuffix("/upload") == true }
        let body = try XCTUnwrap(upload.map { MockURLProtocol.bodies[$0] })
        XCTAssertTrue(body.contains(Data("f-1".utf8)), "uploaded into the Attachments folder")
        XCTAssertFalse(body.contains(bytes), "the picture's bytes must not be on the wire")

        // A key ref is stored, or nothing could ever read it back.
        XCTAssertTrue(MockURLProtocol.requests.contains {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/v1/drive/files/img-7/key"
        })
    }

    // MARK: - Resolving

    func testResolvingAReferenceDownloadsAndDecryptsThePicture() async throws {
        let picture = Data("the original pixels".utf8)
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let ciphertext = try sut.encrypt(bytes: Array(picture), dek: dek, xcss: xcss)
        let sealed = try sut.sealDEK(dek)

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/key") {
                return (Self.response(request, 200),
                        Data(#"{"encryptedFileKey":"\#(sealed)"}"#.utf8))
            }
            return (Self.response(request, 200), ciphertext)
        }

        let resolved = try await sut.attachmentData(forFileID: "img-7")

        XCTAssertEqual(resolved, picture)
    }

    /// A file with no key ref for this caller is stored in the clear — an image from before E2EE,
    /// or one uploaded by something that never sealed a key. The download is already the picture,
    /// which is the allowance the web app's resolver makes too.
    func testAFileWithNoKeyIsReadAsPlaintext() async throws {
        let picture = Data("unencrypted pixels".utf8)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/key") == true {
                return (Self.response(request, 404), Data())
            }
            return (Self.response(request, 200), picture)
        }

        let resolved = try await sut.attachmentData(forFileID: "img-8")

        XCTAssertEqual(resolved, picture)
    }

    func testAServerErrorFetchingTheKeyIsNotMistakenForPlaintext() async {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/key") == true {
                return (Self.response(request, 500), Data())
            }
            return (Self.response(request, 200), Data("ciphertext".utf8))
        }

        do {
            _ = try await sut.attachmentData(forFileID: "img-9")
            XCTFail("a 500 is a failure, not a file stored in the clear")
        } catch {
            // Expected.
        }
    }

    // MARK: - Round trip

    /// The whole point, end to end: what is uploaded is what comes back.
    func testAPictureSurvivesUploadAndResolution() async throws {
        let picture = Data((0..<2048).map { UInt8($0 % 251) })
        var stored: Data?
        var sealedKey: String?

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") {
                // The multipart body carries the ciphertext; pull it back out by finding the part
                // after the last header break.
                let body = MockURLProtocol.bodies.last ?? Data()
                stored = body
                return (Self.response(request, 200), Data(#"""
                {"id":"img-1","name":"Photo.jpg","folderId":"f-1","sizeBytes":1,
                 "mimeType":"image/jpeg","updatedAt":"2026-08-14T00:00:00Z"}
                """#.utf8))
            }
            if path.hasSuffix("/key"), request.httpMethod == "PUT" {
                let body = MockURLProtocol.bodies.last ?? Data()
                sealedKey = (try? JSONDecoder().decode([String: String].self, from: body))?["encryptedFileKey"]
                return (Self.response(request, 200), Data())
            }
            return (Self.response(request, 200),
                    Data(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#.utf8))
        }

        _ = try await sut.uploadAttachment(picture, name: "Photo.jpg", mimeType: "image/jpeg")

        let multipart = try XCTUnwrap(stored)
        let key = try XCTUnwrap(sealedKey)
        let ciphertext = try XCTUnwrap(Self.filePart(of: multipart))

        // Now play it back the way resolution would.
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/key") == true {
                return (Self.response(request, 200), Data(#"{"encryptedFileKey":"\#(key)"}"#.utf8))
            }
            return (Self.response(request, 200), ciphertext)
        }

        let resolved = try await sut.attachmentData(forFileID: "img-1")
        XCTAssertEqual(resolved, picture)
    }

    // MARK: - The preview Drive shows

    /// A picture uploaded from here has to appear as a picture in the Drive grid and in the web
    /// app's image picker. The server cannot make that preview — it is handed ciphertext and has no
    /// key — so an upload that carries no `thumbnail_b64` is a file with a blank icon forever.
    func testAnUploadedPictureCarriesAPreviewForTheDriveGrid() async throws {
        routeUpload()

        _ = try await sut.uploadAttachment(Self.picture(width: 1600, height: 1200),
                                           name: "Photo.png", mimeType: "image/png")

        let field = try XCTUnwrap(Self.field("thumbnail_b64", of: try Self.uploadBody()),
                                  "the upload carried no preview")
        let thumbnail = try XCTUnwrap(Data(base64Encoded: field), "the preview is not base64")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        // JPEG because the server records the type as `image/jpeg` whatever is sent, so anything
        // else would be stored under a lie.
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)

        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(max(width, height), Int(EditorImage.thumbnailMaximumPixels),
                       "the same 512 the web app's generateThumbnail uses")
        XCTAssertEqual(Double(width) / Double(height), 4.0 / 3.0, accuracy: 0.01,
                       "a preview that is not the picture's shape is a stretched picture")
    }

    /// Ordering is load-bearing, not cosmetic: the server reads the multipart stream in order and
    /// returns as soon as it has consumed the file, so a field written after the bytes is one it
    /// never sees. Sent after, this feature silently does nothing.
    func testThePreviewIsSentBeforeTheBytesTheServerStopsReadingAt() async throws {
        routeUpload()

        _ = try await sut.uploadAttachment(Self.picture(width: 40, height: 40),
                                           name: "Photo.png", mimeType: "image/png")

        let body = try Self.uploadBody()
        let preview = try XCTUnwrap(body.range(of: Data(#"name="thumbnail_b64""#.utf8)))
        let file = try XCTUnwrap(body.range(of: Data(#"name="file""#.utf8)))
        XCTAssertLessThan(preview.lowerBound, file.lowerBound)
    }

    /// A preview is a nicety and the picture is the point. Bytes ImageIO cannot thumbnail — an
    /// exotic format, a truncated download — must still reach Drive, without the field.
    func testAPictureWhosePreviewCannotBeMadeIsStillUploaded() async throws {
        routeUpload()

        let id = try await sut.uploadAttachment(Data("not an image".utf8),
                                                name: "Photo.jpg", mimeType: "image/jpeg")

        XCTAssertEqual(id, "img-7")
        XCTAssertNil(Self.field("thumbnail_b64", of: try Self.uploadBody()),
                     "an empty preview field would be stored as a broken thumbnail")
    }

    /// A picture already smaller than the preview size is not blown up to it: the web app scales by
    /// `min(512 / longest, 1)`, and an upscaled thumbnail is bytes spent on nothing.
    func testASmallPictureIsNotEnlargedIntoItsPreview() throws {
        let original = Self.picture(width: 64, height: 32)

        let field = try XCTUnwrap(EditorImage.thumbnailBase64(from: original))
        let thumbnail = try XCTUnwrap(Data(base64Encoded: field))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 32)
    }

    // MARK: - Preview helpers

    /// A PNG of the given size, so a real decoder has something real to work on.
    private static func picture(width: CGFloat, height: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }.pngData()!
    }

    /// The Attachments lookup and the key ref succeed; the upload returns a created file.
    private func routeUpload() {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") {
                return (Self.response(request, 200), Data(#"""
                {"id":"img-7","name":"Photo.png","folderId":"f-1","sizeBytes":12,
                 "mimeType":"image/png","updatedAt":"2026-08-14T00:00:00Z"}
                """#.utf8))
            }
            if path.hasSuffix("/key") { return (Self.response(request, 200), Data()) }
            return (Self.response(request, 200),
                    Data(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#.utf8))
        }
    }

    /// The multipart body of the request that carried the bytes.
    private static func uploadBody() throws -> Data {
        let index = try XCTUnwrap(
            MockURLProtocol.requests.firstIndex { $0.url?.path.hasSuffix("/upload") == true },
            "nothing was uploaded")
        return MockURLProtocol.bodies[index]
    }

    /// The value of a scalar field in a multipart body. Searched as bytes rather than as text: the
    /// body also holds ciphertext, which is not a string in any encoding.
    private static func field(_ name: String, of body: Data) -> String? {
        guard let header = body.range(of: Data("name=\"\(name)\"\r\n\r\n".utf8)) else { return nil }
        let rest = body[header.upperBound...]
        guard let end = rest.range(of: Data("\r\n--".utf8)) else { return nil }
        return String(data: Data(rest[..<end.lowerBound]), encoding: .utf8)
    }

    /// The bytes of the `file` part of a multipart body — everything after the last blank line of
    /// its headers, up to the closing boundary.
    private static func filePart(of body: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = body.range(of: separator, options: .backwards) else { return nil }
        let rest = body[headerEnd.upperBound...]
        guard let boundary = rest.range(of: Data("\r\n--".utf8)) else { return Data(rest) }
        return Data(rest[..<boundary.lowerBound])
    }
}


// MARK: - Progress, cancellation, retry

/// What the Insert button shows and what it can recover from.
///
/// A picture is stored at its original resolution, so an upload is megabytes over whatever
/// connection the phone has. That makes three things load-bearing: the wait has to be measurable,
/// stoppable, and — when it fails — resumable without making somebody find the same photograph
/// again.
@MainActor
final class AttachmentUploadProgressTests: XCTestCase {

    private var sut: DocContentService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        sut = DocContentService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The Attachments lookup and the key ref succeed; only the request carrying the bytes is
    /// under the test's control.
    private func routeUpload(_ upload: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/upload") { return try upload(request) }
            if path.hasSuffix("/key") { return (Self.response(request, 200), Data()) }
            return (Self.response(request, 200),
                    Data(#"{"folders":[{"id":"f-1","name":"Attachments"}],"files":[]}"#.utf8))
        }
    }

    private static let created = Data(#"""
    {"id":"img-1","name":"P.jpg","folderId":"f-1","sizeBytes":9,
     "mimeType":"image/jpeg","updatedAt":"2026-08-14T00:00:00Z"}
    """#.utf8)

    // MARK: - Progress

    /// `URLSession` reports bytes on its own queue and can report a chunked body's total as -1.
    /// Both are handled here rather than in the view, so this is where they are asserted — a mocked
    /// transfer never reaches this code, because a custom `URLProtocol` drains the body itself.
    func testProgressIsReportedAsAFractionOnTheMainActor() async {
        var seen: [Double] = []
        let reporter = UploadProgressReporter { seen.append($0) }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.test")!)

        reporter.urlSession(.shared, task: task, didSendBodyData: 512,
                            totalBytesSent: 512, totalBytesExpectedToSend: 2048)
        reporter.urlSession(.shared, task: task, didSendBodyData: 1536,
                            totalBytesSent: 2048, totalBytesExpectedToSend: 2048)
        await Task.yield()

        XCTAssertEqual(seen, [0.25, 1.0])
    }

    func testAnUnknownBodySizeReportsNothingRatherThanANonsenseFraction() async {
        var seen: [Double] = []
        let reporter = UploadProgressReporter { seen.append($0) }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.test")!)

        reporter.urlSession(.shared, task: task, didSendBodyData: 100,
                            totalBytesSent: 100, totalBytesExpectedToSend: -1)
        await Task.yield()

        XCTAssertEqual(seen, [])
    }

    func testProgressIsClampedToARange() async {
        var seen: [Double] = []
        let reporter = UploadProgressReporter { seen.append($0) }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.test")!)

        // A retried body can report more sent than expected.
        reporter.urlSession(.shared, task: task, didSendBodyData: 4096,
                            totalBytesSent: 4096, totalBytesExpectedToSend: 2048)
        await Task.yield()

        XCTAssertEqual(seen, [1.0], "a progress bar cannot go past its end")
    }

    /// Attaching a progress callback must not change what the upload does.
    func testAnUploadWithProgressAttachedStillSucceeds() async throws {
        routeUpload { (Self.response($0, 200), Self.created) }

        let id = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg",
                                                mimeType: "image/jpeg",
                                                onProgress: { _ in })

        XCTAssertEqual(id, "img-1")
    }

    // MARK: - Cancellation

    /// Stopping an upload has to be distinguishable from an upload that broke: one is the user's
    /// decision and says nothing, the other is an error worth showing.
    func testACancelledTransferSurfacesAsCancellationRatherThanAFailure() async {
        routeUpload { _ in throw URLError(.cancelled) }

        do {
            _ = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg",
                                               mimeType: "image/jpeg")
            XCTFail("expected the upload to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testAnOrdinaryNetworkFailureIsNotReportedAsCancellation() async {
        routeUpload { _ in throw URLError(.timedOut) }

        do {
            _ = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg",
                                               mimeType: "image/jpeg")
            XCTFail("expected the upload to throw")
        } catch is CancellationError {
            XCTFail("a timeout is not the user cancelling")
        } catch {
            // Expected.
        }
    }

    // MARK: - Retry

    /// The sheet keeps the staged picture when an upload fails, so Insert becomes Try Again. That
    /// only helps if the retry actually goes through — nothing may be left wedged by the failure.
    func testAFailedUploadSucceedsOnASecondAttempt() async throws {
        var attempts = 0
        routeUpload { request in
            attempts += 1
            if attempts == 1 { return (Self.response(request, 500), Data()) }
            return (Self.response(request, 200), Self.created)
        }

        do {
            _ = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg",
                                               mimeType: "image/jpeg")
            XCTFail("the first attempt was supposed to fail")
        } catch {
            // Expected.
        }

        let id = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg",
                                                mimeType: "image/jpeg")

        XCTAssertEqual(id, "img-1")
        XCTAssertEqual(attempts, 2)
    }

    /// The Attachments folder is memoised, and a retry must not re-list the Drive root — nor lose
    /// the folder because an unrelated upload failed.
    func testARetryReusesTheAttachmentsFolderItAlreadyFound() async throws {
        var attempts = 0
        routeUpload { request in
            attempts += 1
            if attempts == 1 { return (Self.response(request, 500), Data()) }
            return (Self.response(request, 200), Self.created)
        }

        _ = try? await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg", mimeType: "image/jpeg")
        _ = try await sut.uploadAttachment(Data("bytes".utf8), name: "P.jpg", mimeType: "image/jpeg")

        let listings = MockURLProtocol.requests.filter {
            $0.url?.path == "/api/v1/drive/folders/\(TestTokens.userId)"
        }
        XCTAssertEqual(listings.count, 1)
    }
}
