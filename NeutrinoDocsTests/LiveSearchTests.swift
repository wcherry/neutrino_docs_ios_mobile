import XCTest
import NeutrinoCore
@testable import NeutrinoDocs

/// The as-you-type search shared by the Search tab and the Home list's search field (issue #3).
@MainActor
final class LiveSearchTests: XCTestCase {

    private var service: SearchService!
    private var sut: LiveSearch!

    override func setUp() {
        super.setUp()
        _ = KeychainService.delete(forKey: SearchIndexStore.indexKeyKeychainKey)
        service = SearchService(store: SearchIndexStore(directory: makeTemporaryDirectory()))
        service.start()
        sut = LiveSearch()
    }

    override func tearDown() {
        sut.cancel()
        _ = KeychainService.delete(forKey: SearchIndexStore.indexKeyKeychainKey)
        sut = nil
        service = nil
        super.tearDown()
    }

    func testAnEmptyFieldIsIdle() {
        XCTAssertTrue(sut.isIdle)
        sut.query = "   "
        XCTAssertTrue(sut.isIdle, "Whitespace alone is not a search")
    }

    func testATypedQueryOrAFilterIsNotIdle() {
        sut.query = "budget"
        XCTAssertFalse(sut.isIdle)

        sut.query = ""
        sut.filters.tags = ["swift"]
        XCTAssertFalse(sut.isIdle, "A filter with no query browses, so there is something to show")
    }

    /// Local results land on the keystroke, before any debounce, so the list tracks typing.
    func testLocalResultsArriveSynchronously() {
        service.indexDocument(item: Fixture.doc(id: "d1", name: "Budget.md"),
                              document: Doc.document(Doc.paragraph("Quarterly revenue")))

        sut.query = "revenue"
        sut.run(using: service, isOnline: false)

        XCTAssertEqual(sut.results.map(\.documentID), ["d1"])
        XCTAssertFalse(sut.isSearchingDrive, "Offline, no Drive pass is started")
    }

    func testClearingTheFieldClearsTheResults() {
        service.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.paragraph("keyword")))
        sut.query = "keyword"
        sut.run(using: service, isOnline: false)
        XCTAssertFalse(sut.results.isEmpty)

        sut.query = ""
        sut.run(using: service, isOnline: true)

        XCTAssertTrue(sut.results.isEmpty)
        XCTAssertFalse(sut.isSearchingDrive, "An idle field never goes to Drive")
    }
}
