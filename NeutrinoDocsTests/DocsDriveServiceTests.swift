import XCTest
import Sodium
import NeutrinoCore
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Browse Drive**.
///
/// Covers each of the five sections, folder navigation, and the six operations Phase 1 lists —
/// open, create, rename, delete, move, duplicate — including what each one does when the device is
/// offline.
@MainActor
final class DocsDriveServiceTests: XCTestCase {

    private var sut: DocsDriveService!
    private var monitor: NetworkMonitor!
    private var store: OfflineStore!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        monitor = NetworkMonitor(autoStart: false)
        store = OfflineStore(directory: makeTemporaryDirectory())
        sut = DocsDriveService(session: MockURLProtocol.makeSession())
        sut.networkMonitor = monitor
        sut.offlineStore = store
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        monitor = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Browsing

    func testHomeListingLoadsFoldersAndDocuments() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1", name: "Spec.md")],
            folders: [Fixture.folderJSON(id: "f1", name: "Projects")]
        ), encoding: .utf8)!)

        await sut.load(.home)

        XCTAssertNil(sut.error)
        let items = sut.items(in: .home, parentID: nil)
        XCTAssertEqual(Set(items.map(\.id)), ["d1", "f1"])
    }

    /// `type=doc` is pinned server-side to the bespoke JSON that predates issue #127, and a
    /// document is a `.docx` — so that filter answers a drive full of documents with nothing at all.
    /// The listings ask for the `office` category instead, which the backend guarantees a `.docx`
    /// lands in, and narrow it here.
    func testHomeListingAsksForTheCategoryThatHoldsDocuments() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1", name: "Spec")], folders: []
        ), encoding: .utf8)!)

        await sut.load(.home)

        let query = MockURLProtocol.requests.first?.url?.query ?? ""
        XCTAssertTrue(query.contains("type=office"), "expected type=office, got query: \(query)")
        XCTAssertFalse(query.contains("type=doc&"), "type=doc misses every .docx")
        XCTAssertFalse(query.contains("type=document"), "type=document is a different, wrong filter")
        XCTAssertFalse(query.contains("type=note"), "type=note is the Notes app's filter")
    }

    /// Documents written by the web app and by this one are the same files, and both list.
    func testWordDocumentsAreListedWhicheverClientWroteThem() async {
        let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "phone", name: "Old.docx", mimeType: DocItem.documentMIME),
                    Fixture.fileJSON(id: "web", name: "New.docx", mimeType: docx)],
            folders: []
        ), encoding: .utf8)!)

        await sut.load(.home)

        XCTAssertEqual(Set(sut.items(in: .home).map(\.id)), ["phone", "web"])
    }

    /// `office` is coarser than "a document" — it also carries spreadsheets, decks, notes and
    /// uploaded Office files — so what comes back has to be narrowed, or Docs lists the whole
    /// office suite.
    func testTheOfficeCategoryIsNarrowedToDocuments() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "doc", name: "Spec"),
                    Fixture.fileJSON(id: "sheet", name: "Budget.xlsx",
                                     mimeType: "application/vnd.openxmlformats-officedocument"
                                             + ".spreadsheetml.sheet"),
                    Fixture.fileJSON(id: "note", name: "Jot",
                                     mimeType: "application/x-neutrino-note"),
                    Fixture.fileJSON(id: "csv", name: "Data.csv", mimeType: "text/csv")],
            folders: []
        ), encoding: .utf8)!)

        await sut.load(.home)

        XCTAssertEqual(sut.items(in: .home).map(\.id), ["doc"])
    }

    /// The MIME the app writes has to be one the listings recognise, or documents created here
    /// never come back in a listing.
    func testTheDocumentMIMEIsTheOneTheListingsRecognise() {
        XCTAssertEqual(DocItem.documentMIME,
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertTrue(DocItem.isDocument(DocItem.documentMIME))
    }

    /// Drive filters by `type` server-side on every listing this app uses, so a section that
    /// forgets the parameter shows a page cut from every file in the account — which in a drive
    /// holding a few thousand photos is a page with no documents in it at all.
    func testEverySectionAsksTheServerForOfficeFilesOnly() async {
        let sections: [(DocsSection, String?)] = [
            (.home, nil),
            (.home, "f1"),
            (.recent, nil),
            (.favorites, nil),
            (.shared, nil),
            (.trash, nil),
        ]

        for (section, parentID) in sections {
            MockURLProtocol.reset()
            MockURLProtocol.respond(json: String(data: Fixture.listing(), encoding: .utf8)!)

            await sut.load(section, parentID: parentID)

            let query = MockURLProtocol.requests.first?.url?.query ?? ""
            XCTAssertTrue(
                query.contains("type=office"),
                "\(section.rawValue) (parent=\(parentID ?? "root")) must request type=office, got: \(query)"
            )
        }
    }

    /// Folders are containers and are never filtered by `type` — hiding one would hide the
    /// documents inside it — so the server returns them and the app shows them as-is.
    func testFoldersComeBackAlongsideDocuments() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1", name: "Spec.md")],
            folders: [Fixture.folderJSON(id: "f1")]
        ), encoding: .utf8)!)

        await sut.load(.home)

        XCTAssertEqual(Set(sut.items(in: .home).map(\.id)), ["d1", "f1"])
    }

    func testFolderNavigationRequestsThatFolderAndScopesItsItems() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "child", name: "Inner.md", folderId: "f1")],
            folders: []
        ), encoding: .utf8)!)

        await sut.load(.home, parentID: "f1")

        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/drive/folders/f1")
        XCTAssertEqual(sut.items(in: .home, parentID: "f1").map(\.id), ["child"])
        XCTAssertTrue(sut.items(in: .home, parentID: nil).isEmpty)
    }

    func testRefreshingAFolderReplacesItsItemsRatherThanDuplicatingThem() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1")], folders: []
        ), encoding: .utf8)!)

        await sut.load(.home)
        await sut.load(.home)

        XCTAssertEqual(sut.items(in: .home).count, 1)
    }

    func testRecentListingUsesTheRecentView() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1")], folders: []
        ), encoding: .utf8)!)

        await sut.load(.recent)

        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/drive/recent")
        XCTAssertEqual(sut.items(in: .recent).map(\.id), ["d1"])
    }

    func testFavoritesListingUsesTheStarredView() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1", isStarred: true)], folders: []
        ), encoding: .utf8)!)

        await sut.load(.favorites)

        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/drive/starred")
        XCTAssertEqual(sut.items(in: .favorites).first?.isStarred, true)
    }

    func testSharedListingMarksItemsAsSharedAndDropsTheOwnersStar() async {
        MockURLProtocol.respond(json: String(data: Fixture.listing(
            files: [Fixture.fileJSON(id: "d1", folderId: "someone-elses", isStarred: true)],
            folders: [Fixture.folderJSON(id: "f1", parentId: "someone-elses", isStarred: true)]
        ), encoding: .utf8)!)

        await sut.load(.shared)

        let items = sut.items(in: .shared)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy(\.isShared))
        // `is_starred` is a single column, so it is the *owner's* star — showing it here would put
        // a Favorites badge on somebody else's document that this account cannot clear.
        XCTAssertTrue(items.allSatisfy { !$0.isStarred })
        // A shared folder's parent names a folder this account cannot list.
        XCTAssertNil(items.first { $0.type == .folder }?.parentID)
    }

    func testTrashListingLoadsTrashedItems() async {
        MockURLProtocol.respond(json: """
        {"files":[{"id":"d1","name":"Old.md","mimeType":"\(DocItem.documentMIME)","sizeBytes":10,
          "deletedAt":"\(Fixture.driveTimestamp(Date()))"}],"folders":[]}
        """)

        await sut.load(.trash)

        XCTAssertEqual(sut.items(in: .trash).map(\.id), ["d1"])
        XCTAssertEqual(sut.items(in: .trash).first?.isTrashed, true)
    }

    func testServerErrorSurfacesRatherThanFailingSilently() async {
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        await sut.load(.home)

        XCTAssertNotNil(sut.error)
        XCTAssertTrue(sut.items(in: .home).isEmpty)
    }

    // MARK: - Lookup and breadcrumb

    func testItemLookupFindsDocumentsReachedFromAnySection() async {
        sut = DocsDriveService(home: [Fixture.doc(id: "home-doc")],
                               recents: [Fixture.doc(id: "recent-doc")],
                               starred: [Fixture.doc(id: "starred-doc")],
                               shared: [Fixture.doc(id: "shared-doc")],
                               trash: [Fixture.doc(id: "trash-doc")])

        for id in ["home-doc", "recent-doc", "starred-doc", "shared-doc", "trash-doc"] {
            XCTAssertNotNil(sut.item(id: id), "\(id) should be findable")
        }
        XCTAssertNil(sut.item(id: "nope"))
    }

    func testBreadcrumbWalksFromRootToFolder() {
        sut = DocsDriveService(home: [
            Fixture.folder(id: "a", name: "A", parentID: nil),
            Fixture.folder(id: "b", name: "B", parentID: "a"),
            Fixture.folder(id: "c", name: "C", parentID: "b"),
        ])

        XCTAssertEqual(sut.breadcrumb(to: "c").map(\.id), ["a", "b", "c"])
        XCTAssertTrue(sut.breadcrumb(to: nil).isEmpty)
    }

    /// Bad server data could describe a parent cycle; the walk must terminate rather than hang.
    func testBreadcrumbTerminatesOnACycle() {
        sut = DocsDriveService(home: [
            Fixture.folder(id: "a", parentID: "b"),
            Fixture.folder(id: "b", parentID: "a"),
        ])

        XCTAssertLessThanOrEqual(sut.breadcrumb(to: "a").count, 3)
    }

    // MARK: - Create

    func testCreateFolderShowsAPlaceholderThenAdoptsTheServerID() async {
        MockURLProtocol.respond(json: Fixture.folderJSON(id: "server-id", name: "Projects"))

        sut.createFolder(name: "Projects", parentID: nil)
        XCTAssertEqual(sut.items(in: .home).count, 1, "placeholder should appear immediately")

        await settle()

        XCTAssertEqual(sut.items(in: .home).map(\.id), ["server-id"])
    }

    func testCreateFolderRollsBackWhenTheServerRefuses() async {
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        sut.createFolder(name: "Projects", parentID: nil)
        await settle()

        XCTAssertTrue(sut.items(in: .home).isEmpty)
        XCTAssertNotNil(sut.error)
    }

    /// A Neutrino Doc's body is the web editor's ProseMirror JSON, and Drive identifies it by its
    /// `application/x-neutrino-doc` MIME type — so a document is named with a plain title, exactly
    /// as the web app names one, and no `.md` is appended.
    func testCreateDocumentNamesTheFileWithTheDocxExtension() async throws {
        TestKeys.install()
        defer { TestKeys.remove() }

        let session = MockURLProtocol.makeSession()
        // `contentService` is a weak reference, so the test has to hold the strong one.
        let content = DocContentService(session: session)
        sut = makeSeeded(session: session)
        sut.contentService = content
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/files/upload") == true {
                return (ok, Data(Fixture.fileJSON(id: "new-1", name: "Quarterly Review.docx").utf8))
            }
            return (ok, Data("{}".utf8))
        }

        let item = try await sut.createDocument(name: "  Quarterly Review  ", parentID: nil)

        XCTAssertEqual(item.name, "Quarterly Review.docx")
        XCTAssertEqual(item.displayName, "Quarterly Review", "The title has no extension in it")
        let body = String(decoding: MockURLProtocol.bodies.first ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="Quarterly Review.docx""#),
                      "A download has to land on disk as something the system can open")
    }

    // MARK: - Rename

    func testRenameUpdatesImmediatelyAndPATCHesTheFile() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", name: "Old.docx")])
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", name: "New.docx"))

        sut.rename(itemID: "d1", to: "New")
        XCTAssertEqual(sut.item(id: "d1")?.name, "New.docx")

        await settle()

        let request = MockURLProtocol.request { $0.url?.path == "/api/v1/drive/files/d1" }
        XCTAssertEqual(request?.httpMethod, "PATCH")
    }

    func testRenameRevertsWhenTheServerRefuses() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", name: "Old.docx")])
        MockURLProtocol.respond(json: "{}", statusCode: 403)

        sut.rename(itemID: "d1", to: "New")
        await settle()

        XCTAssertEqual(sut.item(id: "d1")?.name, "Old.docx")
    }

    /// The rename sheet shows the title, so what the user typed is a title — and the file keeps the
    /// extension that makes it a Word document.
    func testRenamingADocumentKeepsTheDocxExtension() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", name: "Old.docx")])
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", name: "Renamed.docx"))

        sut.rename(itemID: "d1", to: "  Renamed  ")
        XCTAssertEqual(sut.item(id: "d1")?.name, "Renamed.docx")
        XCTAssertEqual(sut.item(id: "d1")?.displayName, "Renamed")
        await settle()
    }

    /// A folder has no extension to keep, and adding one would rename it to something absurd.
    func testRenamingAFolderAddsNothing() async {
        sut = makeSeeded(home: [Fixture.folder(id: "f1", name: "Old")])
        MockURLProtocol.respond(json: #"{"id":"f1","name":"Projects","parentId":null,"isStarred":false,"updatedAt":"2026-07-30T14:25:36.123456"}"#)

        sut.rename(itemID: "f1", to: "Projects")
        XCTAssertEqual(sut.item(id: "f1")?.name, "Projects")
        await settle()
    }

    /// Phase 1 — Offline Mode, "Queue: pending moves" (and renames alongside them).
    func testRenameWhileOfflineIsQueuedRatherThanAttempted() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", name: "Old.docx")])
        monitor.setOnlineForTesting(false)

        sut.rename(itemID: "d1", to: "New")
        await settle()

        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(store.pendingMutations.count, 1)
        XCTAssertEqual(store.pendingMutations.first?.itemID, "d1")
        if case .rename(_, let newName) = store.pendingMutations.first?.kind {
            XCTAssertEqual(newName, "New.docx", "The queued name is the one the server will get")
        } else {
            XCTFail("Expected a queued rename")
        }
        // The user still sees their change.
        XCTAssertEqual(sut.item(id: "d1")?.displayName, "New")
    }

    // MARK: - Delete

    func testDeleteMovesTheItemToTrashAndPostsBulkTrash() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")])
        MockURLProtocol.respond(json: #"{"affected":1}"#)

        sut.delete(itemID: "d1")

        XCTAssertTrue(sut.items(in: .home).isEmpty)
        XCTAssertEqual(sut.items(in: .trash).map(\.id), ["d1"])
        await settle()
        XCTAssertNotNil(MockURLProtocol.request { $0.url?.path == "/api/v1/drive/bulk/trash" })
    }

    func testDeleteRestoresTheRowWhenTheServerRefuses() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")])
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        sut.delete(itemID: "d1")
        await settle()

        XCTAssertEqual(sut.items(in: .home).map(\.id), ["d1"])
        XCTAssertTrue(sut.items(in: .trash).isEmpty)
    }

    func testDeletingAStarredDocumentAlsoRemovesItFromFavorites() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", isStarred: true)],
                         starred: [Fixture.doc(id: "d1", isStarred: true)])
        MockURLProtocol.respond(json: #"{"affected":1}"#)

        sut.delete(itemID: "d1")

        XCTAssertTrue(sut.items(in: .favorites).isEmpty,
                      "A trashed document must not leave a Favorites row that opens nothing")
        await settle()
    }

    /// Phase 1 — Offline Mode, "Queue: pending deletes".
    func testDeleteWhileOfflineIsQueued() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")])
        monitor.setOnlineForTesting(false)

        sut.delete(itemID: "d1")
        await settle()

        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(store.pendingMutations.count, 1)
        if case .delete = store.pendingMutations.first?.kind {} else {
            XCTFail("Expected a queued delete")
        }
        XCTAssertEqual(sut.items(in: .trash).map(\.id), ["d1"])
    }

    func testDeletingAnAlreadyTrashedItemDeletesItPermanently() async {
        sut = makeSeeded(trash: [Fixture.doc(id: "d1", isTrashed: true)])
        MockURLProtocol.respond(json: "{}")

        sut.delete(itemID: "d1")
        await settle()

        let request = MockURLProtocol.request { $0.url?.path.contains("/trash/files/d1") == true }
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertTrue(sut.items(in: .trash).isEmpty)
    }

    // MARK: - Move

    func testMoveReparentsAndPostsBulkMove() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1"), Fixture.folder(id: "f1")])
        MockURLProtocol.respond(json: #"{"affected":1}"#)

        sut.move(itemID: "d1", to: "f1")

        XCTAssertEqual(sut.item(id: "d1")?.parentID, "f1")
        await settle()
        XCTAssertNotNil(MockURLProtocol.request { $0.url?.path == "/api/v1/drive/bulk/move" })
    }

    /// Moving a folder inside itself would detach it, and everything under it, from the drive.
    func testMovingAFolderIntoItsOwnSubtreeIsRefused() async {
        sut = makeSeeded(home: [
            Fixture.folder(id: "parent"),
            Fixture.folder(id: "child", parentID: "parent"),
        ])

        sut.move(itemID: "parent", to: "child")
        await settle()

        XCTAssertNil(sut.item(id: "parent")?.parentID)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testMovingAFolderIntoItselfIsRefused() async {
        sut = makeSeeded(home: [Fixture.folder(id: "f1")])

        sut.move(itemID: "f1", to: "f1")
        await settle()

        XCTAssertNil(sut.item(id: "f1")?.parentID)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testMoveRevertsWhenTheServerRefuses() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", parentID: "old"), Fixture.folder(id: "f1")])
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        sut.move(itemID: "d1", to: "f1")
        await settle()

        XCTAssertEqual(sut.item(id: "d1")?.parentID, "old")
    }

    func testMoveWhileOfflineIsQueued() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1"), Fixture.folder(id: "f1")])
        monitor.setOnlineForTesting(false)

        sut.move(itemID: "d1", to: "f1")
        await settle()

        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(store.pendingMutations.count, 1)
        if case .move(_, let target) = store.pendingMutations.first?.kind {
            XCTAssertEqual(target, "f1")
        } else {
            XCTFail("Expected a queued move")
        }
    }

    // MARK: - Star (Favorites)

    func testStarringAddsToFavoritesImmediately() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")])
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", isStarred: true))

        sut.setStarred(itemID: "d1", isStarred: true)

        XCTAssertEqual(sut.items(in: .favorites).map(\.id), ["d1"])
        await settle()
    }

    func testUnstarringRemovesFromFavorites() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1", isStarred: true)],
                         starred: [Fixture.doc(id: "d1", isStarred: true)])
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", isStarred: false))

        sut.setStarred(itemID: "d1", isStarred: false)

        XCTAssertTrue(sut.items(in: .favorites).isEmpty)
        await settle()
    }

    /// Starring has no safe offline semantics — the flag lives on a row the server may have
    /// changed — so it is reverted rather than silently dropped or wrongly queued.
    func testStarringWhileOfflineIsRefusedAndReverted() async {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")])
        monitor.setOnlineForTesting(false)

        sut.setStarred(itemID: "d1", isStarred: true)
        await settle()

        XCTAssertEqual(sut.item(id: "d1")?.isStarred, false)
        XCTAssertTrue(sut.items(in: .favorites).isEmpty)
        XCTAssertTrue(store.pendingMutations.isEmpty)
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Restore

    func testRestoreMovesTheItemBackOutOfTrash() async {
        sut = makeSeeded(trash: [Fixture.doc(id: "d1", isTrashed: true)])
        MockURLProtocol.respond(json: "{}")

        sut.restore(itemID: "d1")

        XCTAssertTrue(sut.items(in: .trash).isEmpty)
        XCTAssertEqual(sut.items(in: .home).map(\.id), ["d1"])
        await settle()
    }

    // MARK: - Duplicate

    /// Drive has no server-side copy endpoint, so Duplicate is a client-side
    /// download-decrypt-re-encrypt-upload under a **fresh** DEK.
    func testDuplicateCopiesTheContentUnderACopyName() async throws {
        TestKeys.install()
        defer { TestKeys.remove() }

        let session = MockURLProtocol.makeSession()
        let content = DocContentService(session: session)
        sut = DocsDriveService(session: session)
        sut.contentService = content
        sut.networkMonitor = monitor
        let source = Fixture.doc(id: "d1", name: "Report.md")
        sut = makeSeeded(home: [source], session: session)
        sut.contentService = content

        // The source's ciphertext has to be something this device's key can actually open, so it
        // is produced with the same primitives the app uses.
        let sodium = Sodium()
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(text: "# Report\n\nBody.",
                                             dek: dek,
                                             xcss: sodium.secretStream.xchacha20poly1305)
        let sealed = try content.sealDEK(dek)

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/files/d1/key") {
                return (ok, Data(#"{"encryptedFileKey":"\#(sealed.sealed)","keyVersion":\#(sealed.keyVersion)}"#.utf8))
            }
            if path == "/api/v1/drive/files/d1" {
                return (ok, ciphertext)
            }
            if path.hasSuffix("/files/upload") {
                return (ok, Data(Fixture.fileJSON(id: "copy-1", name: "Report copy.md").utf8))
            }
            if path.hasSuffix("/key") {
                return (ok, Data("{}".utf8))
            }
            if path.hasSuffix("/autosave") {
                return (ok, Data(Fixture.fileJSON(id: "copy-1", name: "Report copy.md").utf8))
            }
            return (ok, Data("{}".utf8))
        }

        let copy = try await sut.duplicate(itemID: "d1")

        XCTAssertEqual(copy.name, "Report copy.md")
        XCTAssertNotEqual(copy.id, "d1")
        XCTAssertNotNil(sut.item(id: "copy-1"))
    }

    func testDuplicateOfAFolderIsRefused() async {
        sut = makeSeeded(home: [Fixture.folder(id: "f1")])

        do {
            _ = try await sut.duplicate(itemID: "f1")
            XCTFail("Duplicating a folder should not be offered")
        } catch {
            // Expected: Phase 1 duplicates documents, not folder trees.
        }
    }

    // MARK: - Editor callback

    func testDocumentWasSavedUpdatesEverySectionHoldingTheDocument() {
        sut = makeSeeded(home: [Fixture.doc(id: "d1")],
                         recents: [Fixture.doc(id: "d1")],
                         starred: [Fixture.doc(id: "d1")])
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)

        sut.documentWasSaved(itemID: "d1", size: 999, modifiedAt: newDate)

        for section in [DocsSection.home, .recent, .favorites] {
            let item = sut.items(in: section).first { $0.id == "d1" }
            XCTAssertEqual(item?.size, 999, "\(section.rawValue) should reflect the save")
            XCTAssertEqual(item?.modifiedAt, newDate)
        }
    }

    // MARK: - Helpers

    private func makeSeeded(home: [DocItem] = [], recents: [DocItem] = [],
                            starred: [DocItem] = [], shared: [DocItem] = [],
                            trash: [DocItem] = [],
                            session: URLSession? = nil) -> DocsDriveService {
        let service = DocsDriveService(home: home, recents: recents, starred: starred,
                                       shared: shared, trash: trash,
                                       session: session ?? MockURLProtocol.makeSession())
        service.networkMonitor = monitor
        service.offlineStore = store
        return service
    }

    /// Lets the service's fire-and-forget `Task`s finish. The mutations are optimistic and complete
    /// off the call, so a test asserting on the server round trip has to give it a turn.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
