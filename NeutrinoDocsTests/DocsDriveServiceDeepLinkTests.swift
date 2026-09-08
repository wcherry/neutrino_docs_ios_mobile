import XCTest
@testable import NeutrinoDocs

/// Tests for `DocsDriveService.fetchItem(id:)` — the lookup a Universal Link needs, which cannot
/// read from a listing because the linked document may be in a folder nobody has opened.
@MainActor
final class DocsDriveServiceDeepLinkTests: XCTestCase {

    private var sut: DocsDriveService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        sut = DocsDriveService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Endpoint

    func testFetchItemAsksTheMetadataEndpoint() async throws {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", name: "Spec.md"))

        _ = try await sut.fetchItem(id: "d1")

        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/drive/files/d1/metadata")
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "GET")
    }

    func testFetchItemMapsTheResponseToADocument() async throws {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", name: "Spec.md",
                                                       folderId: "f1", sizeBytes: 512))

        let item = try await sut.fetchItem(id: "d1")

        XCTAssertEqual(item.id, "d1")
        XCTAssertEqual(item.name, "Spec.md")
        XCTAssertEqual(item.type, .file)
        XCTAssertEqual(item.parentID, "f1")
        XCTAssertEqual(item.size, 512)
    }

    /// A link naming a document nobody has browsed to is the whole reason this method exists, so it
    /// must not consult — or need — the in-memory listings.
    func testFetchItemWorksWithoutTheDocumentBeingInAnyListing() async throws {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "unlisted"))

        XCTAssertNil(sut.item(id: "unlisted"))
        let item = try await sut.fetchItem(id: "unlisted")

        XCTAssertEqual(item.id, "unlisted")
    }

    // MARK: - Wrong format

    /// `/open/doc/<id>` promises a Neutrino document. Pointed at a spreadsheet it is a malformed
    /// link, and rendering those bytes as a document would show the user garbage rather than an error.
    func testFetchItemRejectsAFileThatIsNotADocument() async {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "s1", name: "Budget.xlsx",
                                                       mimeType: "application/x-neutrino-sheet"))

        do {
            _ = try await sut.fetchItem(id: "s1")
            XCTFail("expected a non-document to be refused")
        } catch let error as DocsDriveError {
            guard case .notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        } catch {
            XCTFail("expected DocsDriveError, got \(error)")
        }
    }

    func testFetchItemRejectsANoteBelongingToTheNotesApp() async {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "n1", name: "Meeting.md",
                                                       mimeType: "text/markdown"))

        do {
            _ = try await sut.fetchItem(id: "n1")
            XCTFail("expected a note to be refused")
        } catch {
            // Expected.
        }
    }

    // MARK: - Failures

    func testFetchItemPropagatesAServerError() async {
        MockURLProtocol.respond(json: "{}", statusCode: 404)

        do {
            _ = try await sut.fetchItem(id: "missing")
            XCTFail("expected the 404 to surface")
        } catch let error as DocsDriveError {
            guard case .serverError(let code) = error else {
                return XCTFail("expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("expected DocsDriveError, got \(error)")
        }
    }
}
