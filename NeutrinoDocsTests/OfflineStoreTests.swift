import XCTest
import Sodium
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Work offline**.
///
/// Covers the cache (open documents, recents, favorites), the pending-save path, and the
/// pending delete/move/rename queue.
@MainActor
final class OfflineStoreTests: XCTestCase {

    private var sut: OfflineStore!
    private var content: DocContentService!
    private var directory: URL!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        directory = makeTemporaryDirectory()
        content = DocContentService(session: MockURLProtocol.makeSession())
        sut = OfflineStore(directory: directory)
        sut.contentService = content
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        content = nil
        super.tearDown()
    }

    // MARK: - Download

    func testDownloadCachesTheDocumentAndMakesItReadable() async throws {
        let stored = NeutrinoDocumentCodec.encode(
            DocumentBody(doc: Doc.document(Doc.heading(1, "Cached"), Doc.paragraph("Body.")))
        )
        let dek = try stubDownload(text: stored)

        try await sut.download(Fixture.doc(id: "d1", name: "Cached"))

        XCTAssertTrue(sut.isAvailableOffline("d1"))
        let (body, readDEK) = try sut.readPlaintext(id: "d1")
        XCTAssertEqual(body.blocks.map(\.type), ["heading", "paragraph"])
        XCTAssertEqual(body.plainText, "Cached Body.")
        XCTAssertEqual(readDEK, dek)
    }

    /// The cached blob is the server's ciphertext byte for byte, so cache-at-rest security is
    /// identical to the wire protocol.
    func testCachedBlobIsCiphertextNotPlaintext() async throws {
        _ = try stubDownload(text: "the launch code is 12345")

        try await sut.download(Fixture.doc(id: "d1"))

        let blob = try Data(contentsOf: directory.appendingPathComponent("d1.bin"))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("launch code"))
    }

    func testDownloadRecordsTheCacheReason() async throws {
        _ = try stubDownload(text: "x")

        try await sut.download(Fixture.doc(id: "d1"), reason: .recent)

        XCTAssertEqual(sut.document(id: "d1")?.cacheReason, .recent)
    }

    /// A document the user deliberately kept must not be quietly downgraded to evictable by a
    /// later background refresh.
    func testPinnedDocumentIsNotDowngradedByAnAutomaticRefresh() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"), reason: .pinned)

        try await sut.download(Fixture.doc(id: "d1"), reason: .recent)

        XCTAssertEqual(sut.document(id: "d1")?.cacheReason, .pinned)
    }

    func testDownloadFailsWhenTheKeyCannotOpenTheBlob() async throws {
        _ = try stubDownload(text: "x")
        TestKeys.remove()
        TestKeys.install()   // a different key pair

        do {
            try await sut.download(Fixture.doc(id: "d1"))
            XCTFail("A blob this device cannot read must not be cached")
        } catch {
            XCTAssertFalse(sut.isAvailableOffline("d1"))
        }
    }

    // MARK: - Removal and eviction

    func testRemoveDeletesTheCatalogueEntryAndTheBlob() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))

        try sut.remove(id: "d1")

        XCTAssertFalse(sut.isAvailableOffline("d1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("d1.bin").path))
    }

    /// Unsynced work is not the cache's to throw away.
    func testRemoveRefusesWhenThereIsAPendingEdit() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)

        XCTAssertThrowsError(try sut.remove(id: "d1")) { error in
            guard case OfflineStoreError.hasPendingEdit = error else {
                return XCTFail("Expected hasPendingEdit, got \(error)")
            }
        }
        XCTAssertTrue(sut.isAvailableOffline("d1"))
    }

    func testRemoveAllKeepsDocumentsWithUnsyncedChanges() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        try await sut.download(Fixture.doc(id: "d2", name: "Other.md"))
        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)

        try sut.removeAll()

        XCTAssertTrue(sut.isAvailableOffline("d1"))
        XCTAssertFalse(sut.isAvailableOffline("d2"))
    }

    func testEvictAutomaticEntriesKeepsPinnedDocuments() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "pinned"), reason: .pinned)
        try await sut.download(Fixture.doc(id: "auto", name: "Auto.md"), reason: .recent)

        try sut.evictAutomaticEntries()

        XCTAssertTrue(sut.isAvailableOffline("pinned"))
        XCTAssertFalse(sut.isAvailableOffline("auto"))
    }

    // MARK: - Pending edits

    func testWritePendingEditStoresCiphertextAndIsReadBackInPreference() async throws {
        let dek = try stubDownload(text: "original")
        try await sut.download(Fixture.doc(id: "d1"))

        try sut.writePendingEdit(DocumentBody.text("edited offline"), id: "d1", dek: dek)

        XCTAssertEqual(try sut.readPlaintext(id: "d1").body.plainText, "edited offline")
        let pending = try Data(contentsOf: directory.appendingPathComponent("d1.pending.bin"))
        XCTAssertFalse(String(decoding: pending, as: UTF8.self).contains("edited offline"))
    }

    /// A chain of offline edits is still measured against the version they started from, so the
    /// conflict check does not silently reset each time the user types.
    func testChainedOfflineEditsKeepTheOriginalBaseVersion() async throws {
        let dek = try stubDownload(text: "original")
        try await sut.download(Fixture.doc(id: "d1"))
        let base = sut.document(id: "d1")!.serverModifiedAt

        try sut.writePendingEdit(DocumentBody.text("first"), id: "d1", dek: dek)
        try sut.writePendingEdit(DocumentBody.text("second"), id: "d1", dek: dek)

        XCTAssertEqual(sut.document(id: "d1")?.pendingEdit?.baseServerModifiedAt, base)
        XCTAssertEqual(try sut.readPlaintext(id: "d1").body.plainText, "second")
    }

    func testPendingCountsReflectQueuedWork() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        XCTAssertEqual(sut.totalPendingCount, 0)

        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)
        sut.enqueue(PendingMutation(itemID: "other", kind: .delete(isFolder: false)))

        XCTAssertEqual(sut.pendingEditCount, 1)
        XCTAssertEqual(sut.totalPendingCount, 2)
    }

    func testClearPendingEditPromotesTheEditToTheCachedVersion() async throws {
        let dek = try stubDownload(text: "original")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("uploaded"), id: "d1", dek: dek)
        let newServerDate = Date(timeIntervalSince1970: 1_800_000_000)

        try sut.clearPendingEdit(id: "d1", serverModifiedAt: newServerDate)

        XCTAssertNil(sut.document(id: "d1")?.pendingEdit)
        XCTAssertEqual(sut.document(id: "d1")?.serverModifiedAt, newServerDate)
        // The promoted base decrypts to what was uploaded.
        XCTAssertEqual(try sut.readPlaintext(id: "d1").body.plainText, "uploaded")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("d1.pending.bin").path))
    }

    func testRecordFailureAdvancesTheBackoff() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)

        try sut.recordFailure(id: "d1", error: "boom")

        let edit = sut.document(id: "d1")?.pendingEdit
        XCTAssertEqual(edit?.attemptCount, 1)
        XCTAssertEqual(edit?.lastError, "boom")
        XCTAssertGreaterThan(edit?.nextAttemptAt ?? .distantPast, Date())
    }

    // MARK: - Conflicts

    func testMarkConflictRecordsTheServerVersion() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        let serverDate = Date(timeIntervalSince1970: 1_800_000_000)

        try sut.markConflict(id: "d1", serverModifiedAt: serverDate)

        XCTAssertEqual(sut.conflictCount, 1)
        XCTAssertEqual(sut.document(id: "d1")?.conflict?.serverModifiedAt, serverDate)
    }

    func testResolveKeepingLocalRebasesTheEditAndClearsTheFlag() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        let serverDate = Date(timeIntervalSince1970: 1_800_000_000)
        try sut.markConflict(id: "d1", serverModifiedAt: serverDate)
        try sut.recordFailure(id: "d1", error: "boom")

        try sut.resolveKeepingLocal(id: "d1")

        let doc = sut.document(id: "d1")
        XCTAssertNil(doc?.conflict)
        XCTAssertEqual(doc?.pendingEdit?.baseServerModifiedAt, serverDate,
                       "Rebased so the next drain uploads rather than re-conflicting")
        XCTAssertEqual(doc?.pendingEdit?.attemptCount, 0, "Backoff resets on an explicit resolution")
        XCTAssertEqual(try sut.readPlaintext(id: "d1").body.plainText, "mine")
    }

    func testResolveKeepingServerDiscardsTheLocalEditAndRefetches() async throws {
        let dek = try stubDownload(text: "server version")
        try await sut.download(Fixture.doc(id: "d1"))
        try sut.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        try sut.markConflict(id: "d1", serverModifiedAt: Date(timeIntervalSince1970: 1_800_000_000))

        try await sut.resolveKeepingServer(id: "d1")

        XCTAssertNil(sut.document(id: "d1")?.pendingEdit)
        XCTAssertNil(sut.document(id: "d1")?.conflict)
        XCTAssertEqual(try sut.readPlaintext(id: "d1").body.plainText, "server version")
    }

    // MARK: - Rebase after metadata writes

    /// A rename or a star bumps `updated_at` without touching content. Without the rebase the sync
    /// engine would ask the user to choose between two copies of their own text.
    func testRebaseMovesTheBaseForwardAfterAMetadataOnlyWrite() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        let original = sut.document(id: "d1")!.serverModifiedAt
        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)
        let afterRename = original.addingTimeInterval(60)

        sut.rebasePendingEdit(id: "d1", previousModifiedAt: original, serverModifiedAt: afterRename)

        XCTAssertEqual(sut.document(id: "d1")?.serverModifiedAt, afterRename)
        XCTAssertEqual(sut.document(id: "d1")?.pendingEdit?.baseServerModifiedAt, afterRename)
    }

    /// A genuine remote content edit must still conflict.
    func testRebaseIsSkippedWhenTheCacheAlreadyKnowsSomethingNewer() async throws {
        let dek = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))
        let original = sut.document(id: "d1")!.serverModifiedAt
        try sut.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)

        // The metadata write was based on a version *older* than what the cache holds.
        sut.rebasePendingEdit(id: "d1",
                              previousModifiedAt: original.addingTimeInterval(-60),
                              serverModifiedAt: original.addingTimeInterval(30))

        XCTAssertEqual(sut.document(id: "d1")?.serverModifiedAt, original)
    }

    // MARK: - Mutation queue

    func testEnqueueStoresMutationsInOrder() {
        let first = PendingMutation(itemID: "a", kind: .delete(isFolder: false),
                                    queuedAt: Date(timeIntervalSince1970: 100))
        let second = PendingMutation(itemID: "b", kind: .move(isFolder: false, targetFolderID: "f"),
                                     queuedAt: Date(timeIntervalSince1970: 200))

        sut.enqueue(second)
        sut.enqueue(first)

        XCTAssertEqual(sut.pendingMutations.map(\.itemID), ["a", "b"])
    }

    /// Replaying "rename then delete" is two round trips for one outcome, and the rename can fail
    /// on its own and strand the queue.
    func testDeleteSupersedesAnEarlierRenameOfTheSameItem() {
        sut.enqueue(PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "New.md")))
        sut.enqueue(PendingMutation(itemID: "a", kind: .delete(isFolder: false)))

        XCTAssertEqual(sut.pendingMutations.count, 1)
        if case .delete = sut.pendingMutations.first?.kind {} else {
            XCTFail("The delete should be what survives")
        }
    }

    func testASecondMoveReplacesTheFirst() {
        sut.enqueue(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f1")))
        sut.enqueue(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f2")))

        XCTAssertEqual(sut.pendingMutations.count, 1)
        if case .move(_, let target) = sut.pendingMutations.first?.kind {
            XCTAssertEqual(target, "f2")
        } else {
            XCTFail("Expected the later move")
        }
    }

    func testMutationsForDifferentItemsDoNotSupersedeEachOther() {
        sut.enqueue(PendingMutation(itemID: "a", kind: .delete(isFolder: false)))
        sut.enqueue(PendingMutation(itemID: "b", kind: .delete(isFolder: false)))

        XCTAssertEqual(sut.pendingMutations.count, 2)
    }

    func testDrainableMutationsRespectsTheBackoffWindow() {
        var mutation = PendingMutation(itemID: "a", kind: .delete(isFolder: false))
        sut.enqueue(mutation)
        sut.recordMutationFailure(id: mutation.id, error: "boom")
        mutation = sut.pendingMutations[0]

        XCTAssertTrue(sut.drainableMutations(now: Date()).isEmpty,
                      "A just-failed mutation is inside its backoff window")
        XCTAssertEqual(sut.drainableMutations(now: Date().addingTimeInterval(60)).count, 1)
    }

    func testRemoveMutationClearsIt() {
        let mutation = PendingMutation(itemID: "a", kind: .delete(isFolder: false))
        sut.enqueue(mutation)

        sut.removeMutation(id: mutation.id)

        XCTAssertTrue(sut.pendingMutations.isEmpty)
    }

    // MARK: - Persistence

    func testCatalogueAndQueueSurviveARelaunch() async throws {
        _ = try stubDownload(text: "persisted")
        try await sut.download(Fixture.doc(id: "d1", name: "Persisted.md"))
        sut.enqueue(PendingMutation(itemID: "other", kind: .delete(isFolder: true)))

        // A fresh store over the same directory is what a relaunch looks like.
        let reopened = OfflineStore(directory: directory)
        reopened.contentService = content

        XCTAssertTrue(reopened.isAvailableOffline("d1"))
        XCTAssertEqual(reopened.documents.first?.name, "Persisted.md")
        XCTAssertEqual(reopened.pendingMutations.count, 1)
        XCTAssertEqual(try reopened.readPlaintext(id: "d1").body.plainText, "persisted")
    }

    /// A truncated index must degrade to an empty catalogue rather than crashing the app at launch.
    func testCorruptIndexDegradesToAnEmptyCatalogue() throws {
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("index.json"))

        let reopened = OfflineStore(directory: directory)

        XCTAssertTrue(reopened.documents.isEmpty)
    }

    func testCorruptQueueDegradesToAnEmptyQueue() throws {
        try Data("nonsense".utf8).write(to: directory.appendingPathComponent("queue.json"))

        let reopened = OfflineStore(directory: directory)

        XCTAssertTrue(reopened.pendingMutations.isEmpty)
    }

    func testDocumentsAreSortedByNameCaseInsensitively() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "b", name: "banana.md"))
        try await sut.download(Fixture.doc(id: "a", name: "Apple.md"))
        try await sut.download(Fixture.doc(id: "c", name: "Cherry.md"))

        XCTAssertEqual(sut.documents.map(\.name), ["Apple.md", "banana.md", "Cherry.md"])
    }

    // MARK: - Metadata mirroring

    func testUpdateNameKeepsTheCachedTitleInStep() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1", name: "Old.md"))

        sut.updateName(id: "d1", name: "New.md")

        XCTAssertEqual(sut.document(id: "d1")?.name, "New.md")
    }

    func testUpdateParentKeepsTheCachedLocationInStep() async throws {
        _ = try stubDownload(text: "x")
        try await sut.download(Fixture.doc(id: "d1"))

        sut.updateParent(id: "d1", parentID: "f9")

        XCTAssertEqual(sut.document(id: "d1")?.parentID, "f9")
    }

    // MARK: - Helpers

    /// Stubs the key + content endpoints with a real encrypted document, returning its DEK.
    @discardableResult
    private func stubDownload(text: String) throws -> Bytes {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(text: text, dek: dek,
                                             xcss: sodium.secretStream.xchacha20poly1305)
        let sealed = try content.sealDEK(dek)
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url?.path ?? ""
            if path.hasSuffix("/key") {
                return (ok, Data(#"{"encryptedFileKey":"\#(sealed)"}"#.utf8))
            }
            if path.hasSuffix("/info") {
                // `fetchServerModifiedAt` is best-effort during a download; 404 exercises the
                // fallback to the listing's timestamp.
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return (ok, ciphertext)
        }
        return dek
    }
}
