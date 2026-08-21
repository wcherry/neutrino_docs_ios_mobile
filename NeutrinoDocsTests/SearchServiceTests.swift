import XCTest
import Sodium
@testable import NeutrinoDocs

/// Phase 5 — Search: the store's encryption at rest, and the service's indexing, querying and
/// saved searches.
@MainActor
final class SearchServiceTests: XCTestCase {

    private var sut: SearchService!
    private var store: SearchIndexStore!
    private var content: DocContentService!
    private var directory: URL!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        _ = KeychainService.delete(forKey: SearchIndexStore.indexKeyKeychainKey)

        directory = makeTemporaryDirectory()
        store = SearchIndexStore(directory: directory)
        content = DocContentService(session: MockURLProtocol.makeSession())
        sut = SearchService(store: store)
        sut.contentService = content
        sut.start()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        _ = KeychainService.delete(forKey: SearchIndexStore.indexKeyKeychainKey)
        sut = nil
        store = nil
        content = nil
        super.tearDown()
    }

    // MARK: - Indexing

    func testIndexingADocumentMakesItFindable() {
        sut.indexDocument(item: Fixture.doc(id: "d1", name: "Budget.md"),
                          document: Doc.document(Doc.heading(1, "Quarterly Budget"), Doc.paragraph("Revenue is up.")))

        XCTAssertEqual(sut.indexedDocumentCount, 1)
        XCTAssertEqual(sut.searchLocally("revenue").map(\.documentID), ["d1"])
        XCTAssertEqual(sut.searchLocally("quarterly").map(\.documentID), ["d1"])
    }

    func testAnEmptyQueryWithNoFiltersFindsNothing() {
        sut.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.heading(1, "Anything")))

        XCTAssertTrue(sut.searchLocally("").isEmpty,
                      "An empty search box is not a request for every document")
    }

    /// With a filter set and no query, the screen browses rather than searches.
    func testAnEmptyQueryWithAFilterBrowses() {
        sut.indexDocument(item: Fixture.doc(id: "d1"),
                          document: Doc.document(Doc.frontMatter("tags: [swift]"), Doc.paragraph("Body.")))

        var filters = SearchFilters()
        filters.tags = ["swift"]
        XCTAssertEqual(sut.searchLocally("", filters: filters).map(\.documentID), ["d1"])
    }

    func testRemovingADocumentTakesItOutOfResults() {
        sut.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.paragraph("unique keyword here")))
        sut.removeFromIndex(id: "d1")

        XCTAssertTrue(sut.searchLocally("keyword").isEmpty)
        XCTAssertEqual(sut.indexedDocumentCount, 0)
    }

    func testADocumentIsStaleWhenItHasChangedSinceItWasIndexed() {
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = Fixture.doc(id: "d1", modifiedAt: indexedAt)
        XCTAssertTrue(sut.isStale(item), "An unindexed document is always stale")

        sut.indexDocument(item: item, document: Doc.document(Doc.paragraph("text")))
        XCTAssertFalse(sut.isStale(item))

        let edited = Fixture.doc(id: "d1", modifiedAt: Date().addingTimeInterval(60))
        XCTAssertTrue(sut.isStale(edited))
    }

    func testTagsFromFrontMatterAreOfferedAsFilters() {
        sut.indexDocument(item: Fixture.doc(id: "d1"),
                          document: Doc.document(Doc.frontMatter("tags: [swift, ios]"), Doc.paragraph("Body.")))

        XCTAssertEqual(sut.allTags, ["ios", "swift"])
    }

    // MARK: - Persistence

    func testTheIndexSurvivesARestart() {
        sut.indexDocument(item: Fixture.doc(id: "d1", name: "Notes.md"), document: Doc.document(Doc.paragraph("persisted text")))
        sut.flushSave()

        let reopened = SearchService(store: SearchIndexStore(directory: directory))
        reopened.start()

        XCTAssertEqual(reopened.indexedDocumentCount, 1)
        XCTAssertEqual(reopened.searchLocally("persisted").map(\.documentID), ["d1"])
    }

    /// The index is built from decrypted documents, so it must not be readable on disk.
    func testTheStoredIndexIsNotPlaintext() throws {
        sut.indexDocument(item: Fixture.doc(id: "d1", name: "Salaries.md"),
                          document: Doc.document(Doc.paragraph("the launch code is 12345")))
        sut.flushSave()

        let onDisk = try Data(contentsOf: directory.appendingPathComponent("index.bin"))
        let asString = String(decoding: onDisk, as: UTF8.self)
        XCTAssertFalse(asString.contains("launch"))
        XCTAssertFalse(asString.contains("12345"))
        XCTAssertFalse(asString.contains("Salaries"))
    }

    /// Without the key the file is noise, which is the whole point of encrypting it.
    func testTheIndexIsUnreadableOnceItsKeyIsGone() {
        sut.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.paragraph("persisted text")))
        sut.flushSave()
        _ = KeychainService.delete(forKey: SearchIndexStore.indexKeyKeychainKey)

        let reopened = SearchService(store: SearchIndexStore(directory: directory))
        reopened.start()

        XCTAssertEqual(reopened.indexedDocumentCount, 0)
    }

    func testACorruptIndexFileIsDiscardedRatherThanFailingForever() throws {
        sut.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.paragraph("text")))
        sut.flushSave()
        try Data("not an index".utf8).write(to: directory.appendingPathComponent("index.bin"))

        let reopened = SearchService(store: SearchIndexStore(directory: directory))
        reopened.start()

        XCTAssertEqual(reopened.indexedDocumentCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("index.bin").path
        ), "An unreadable file is removed so it cannot fail the load on every launch")
    }

    // MARK: - Sign-out

    func testSigningOutDestroysTheIndexAndItsKey() {
        sut.indexDocument(item: Fixture.doc(id: "d1"), document: Doc.document(Doc.paragraph("confidential text")))
        sut.addSavedSearch(name: "Mine", query: "confidential", filters: .unfiltered)
        sut.flushSave()

        sut.signOut()

        XCTAssertEqual(sut.indexedDocumentCount, 0)
        XCTAssertTrue(sut.savedSearches.isEmpty)
        XCTAssertTrue(sut.searchLocally("confidential").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("index.bin").path
        ))
        XCTAssertNil(KeychainService.load(forKey: SearchIndexStore.indexKeyKeychainKey))
    }

    // MARK: - Saved searches

    func testASavedSearchKeepsItsQueryAndFilters() {
        var filters = SearchFilters()
        filters.ownership = .shared
        filters.tags = ["swift"]

        sut.addSavedSearch(name: "Shared Swift", query: "protocol", filters: filters)

        let saved = sut.savedSearches.first
        XCTAssertEqual(saved?.name, "Shared Swift")
        XCTAssertEqual(saved?.query, "protocol")
        XCTAssertEqual(saved?.filters.ownership, .shared)
        XCTAssertEqual(saved?.filters.tags, ["swift"])
    }

    func testAnUnnamedSavedSearchIsNamedAfterItsQuery() {
        sut.addSavedSearch(name: "   ", query: "budget", filters: .unfiltered)
        XCTAssertEqual(sut.savedSearches.first?.name, "budget")
    }

    func testSavedSearchesSurviveARestart() {
        sut.addSavedSearch(name: "Budget", query: "budget", filters: .unfiltered)

        let reopened = SearchService(store: SearchIndexStore(directory: directory))
        reopened.start()

        XCTAssertEqual(reopened.savedSearches.map(\.name), ["Budget"])
    }

    func testDeletingASavedSearchRemovesIt() {
        sut.addSavedSearch(name: "Budget", query: "budget", filters: .unfiltered)
        let id = try? XCTUnwrap(sut.savedSearches.first?.id)

        sut.deleteSavedSearch(id: id!)

        XCTAssertTrue(sut.savedSearches.isEmpty)
    }

    /// The list leads with what the user actually uses.
    func testRunningASavedSearchMovesItToTheFront() {
        sut.addSavedSearch(name: "First", query: "a query", filters: .unfiltered)
        sut.addSavedSearch(name: "Second", query: "another query", filters: .unfiltered)
        XCTAssertEqual(sut.savedSearches.map(\.name), ["Second", "First"])

        let first = sut.savedSearches.first { $0.name == "First" }!
        sut.markUsed(savedSearchID: first.id)

        XCTAssertEqual(sut.savedSearches.map(\.name), ["First", "Second"])
    }

    func testASavedSearchSummaryDescribesItsFilters() {
        var filters = SearchFilters()
        filters.ownership = .shared
        filters.tags = ["swift"]
        let saved = SavedSearch(name: "x", query: "budget", filters: filters)

        XCTAssertTrue(saved.summary.contains("\"budget\""))
        XCTAssertTrue(saved.summary.contains("Shared with me"))
        XCTAssertTrue(saved.summary.contains("#swift"))
    }

    // MARK: - Saved searches at rest

    func testSavedSearchesAreNotStoredAsPlaintext() throws {
        sut.addSavedSearch(name: "Medication", query: "prescription", filters: .unfiltered)

        let onDisk = try Data(contentsOf: directory.appendingPathComponent("searches.bin"))
        let asString = String(decoding: onDisk, as: UTF8.self)
        XCTAssertFalse(asString.contains("prescription"))
        XCTAssertFalse(asString.contains("Medication"))
    }
}
