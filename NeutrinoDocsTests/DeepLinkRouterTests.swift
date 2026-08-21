import XCTest
@testable import NeutrinoDocs

/// Tests for inbound Universal Links: which links Docs claims, and how long it holds one that
/// arrives before there is a session to open it with.
@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: - Accepting

    func test_handle_acceptsDocLink() {
        let sut = DeepLinkRouter()

        let accepted = sut.handle(URL(string: "https://www.getneutrino.app/open/doc/0d0f7c")!)

        XCTAssertTrue(accepted)
        XCTAssertEqual(sut.pending?.fileID, "0d0f7c")
    }

    func test_handle_acceptsApexHost() {
        let sut = DeepLinkRouter()

        XCTAssertTrue(sut.handle(URL(string: "https://getneutrino.app/open/doc/f1")!))
    }

    func test_handle_carriesContentVersion() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/doc/f1?v=12")!)

        XCTAssertEqual(sut.pending?.contentVersion, 12)
    }

    // MARK: - Rejecting

    /// Notes and Docs store different formats behind similar-looking documents; opening a note here
    /// would either fail to decode or show the wrong thing.
    func test_handle_rejectsNoteLink() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://www.getneutrino.app/open/note/f1")!))
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsGenericFileLink() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://www.getneutrino.app/open/file/f1")!))
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsForeignHost() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://evil.example.com/open/doc/f1")!))
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsOrdinaryWebsiteURL() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(string: "https://www.getneutrino.app/pricing")!))
        XCTAssertNil(sut.pending)
    }

    func test_handle_rejectsFileURL() {
        let sut = DeepLinkRouter()

        XCTAssertFalse(sut.handle(URL(fileURLWithPath: "/tmp/neutrino-key.json")))
        XCTAssertNil(sut.pending)
    }

    // MARK: - Consuming

    func test_consume_returnsAndClearsPending() {
        let sut = DeepLinkRouter(pending: .init(kind: .doc, fileID: "f1"))

        XCTAssertEqual(sut.consume()?.fileID, "f1")
        XCTAssertNil(sut.pending)
    }

    /// Guards the double-open bug: SwiftUI re-evaluates a view tree freely, and a destination that
    /// survived consumption would push the same editor twice.
    func test_consume_isIdempotent() {
        let sut = DeepLinkRouter(pending: .init(kind: .doc, fileID: "f1"))

        _ = sut.consume()

        XCTAssertNil(sut.consume())
    }

    /// A link that arrives at the login screen has to survive until the user signs in — nothing but
    /// `consume()` may clear it.
    func test_pending_survivesUntilConsumed() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/doc/f1")!)

        XCTAssertNotNil(sut.pending)
        XCTAssertNotNil(sut.pending)
    }

    func test_handle_replacesAnEarlierUnconsumedLink() {
        let sut = DeepLinkRouter()

        sut.handle(URL(string: "https://www.getneutrino.app/open/doc/first")!)
        sut.handle(URL(string: "https://www.getneutrino.app/open/doc/second")!)

        XCTAssertEqual(sut.pending?.fileID, "second")
    }

    func test_clear_dropsPending() {
        let sut = DeepLinkRouter(pending: .init(kind: .doc, fileID: "f1"))

        sut.clear()

        XCTAssertNil(sut.pending)
    }
}
