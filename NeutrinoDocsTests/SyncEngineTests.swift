import XCTest
import Sodium
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Sync**.
///
/// The rule the whole feature rests on: a queued edit is uploaded only if the server is still on
/// the version that edit was written against. Most of what follows is that rule under different
/// conditions, plus the metadata queue Phase 1 adds alongside it.
@MainActor
final class SyncEngineTests: XCTestCase {

    private var store: OfflineStore!
    private var monitor: NetworkMonitor!
    private var content: FakeContentSyncer!
    private var drive: FakeDriveMutator!
    private var sut: SyncEngine!
    private var realContent: DocContentService!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        realContent = DocContentService(session: MockURLProtocol.makeSession())
        store = OfflineStore(directory: makeTemporaryDirectory())
        store.contentService = realContent
        monitor = NetworkMonitor(autoStart: false)
        content = FakeContentSyncer()
        drive = FakeDriveMutator()
        sut = SyncEngine(store: store, monitor: monitor, content: content, drive: drive)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Draining edits

    func testDrainUploadsAQueuedEditAndClearsIt() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("edited offline"), id: "d1", dek: dek)
        content.serverModifiedAt = store.document(id: "d1")!.serverModifiedAt
        content.saveResult = Date(timeIntervalSince1970: 1_800_000_000)

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["edited offline"])
        XCTAssertNil(store.document(id: "d1")?.pendingEdit)
        XCTAssertEqual(store.document(id: "d1")?.serverModifiedAt,
                       Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNotNil(sut.lastSyncedAt)
    }

    func testDrainWithNothingQueuedIsANoOp() async {
        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty)
        XCTAssertEqual(sut.state, .idle)
    }

    func testDrainDoesNothingWhileOffline() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("edited"), id: "d1", dek: dek)
        monitor.setOnlineForTesting(false)

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty)
        XCTAssertEqual(sut.state, .offline)
        XCTAssertNotNil(store.document(id: "d1")?.pendingEdit, "The edit stays queued")
    }

    func testEditsAreUploadedOldestFirst() async throws {
        let dek1 = try await cacheDocument(id: "d1", text: "one")
        let dek2 = try await cacheDocument(id: "d2", text: "two")
        try store.writePendingEdit(DocumentBody.text("older"), id: "d2", dek: dek2)
        try await Task.sleep(nanoseconds: 10_000_000)
        try store.writePendingEdit(DocumentBody.text("newer"), id: "d1", dek: dek1)
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["older", "newer"])
    }

    // MARK: - Conflict detection

    /// The central rule: a server that has moved ahead means conflict, not upload.
    func testServerAheadOfTheEditsBaseIsAConflictRatherThanAnUpload() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        let base = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.serverModifiedAt = base.addingTimeInterval(60)

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty, "Somebody else's work must not be clobbered")
        XCTAssertNotNil(store.document(id: "d1")?.conflict)
        XCTAssertNotNil(store.document(id: "d1")?.pendingEdit, "The local edit is kept for the user")
    }

    func testServerAtTheSameVersionUploadsNormally() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["mine"])
        XCTAssertNil(store.document(id: "d1")?.conflict)
    }

    /// A document that is gone server-side has nothing to compare against; the upload proceeds and
    /// the server decides.
    func testMissingServerVersionDoesNotBlockTheUpload() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["mine"])
    }

    /// The case the local timestamp check structurally cannot catch: the pre-flight comparison
    /// passes, and another device lands an edit before this upload completes. Only the server can
    /// see that, and only because the guard rode along with the write.
    func testServerRejectingAStaleWriteIsAConflictNotAFailedUpload() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        // The pre-flight sees nothing wrong — the server looks like it is still on our base.
        content.serverModifiedAt = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.rejectSaveWithConflict = 9

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty, "A rejected write must not count as saved")
        XCTAssertNotNil(store.document(id: "d1")?.conflict,
                        "The rejection is a conflict for the user to resolve")
        XCTAssertNotNil(store.document(id: "d1")?.pendingEdit, "The local edit is kept")
        XCTAssertEqual(store.document(id: "d1")?.conflict?.serverContentVersion, 9,
                       "The version the server holds is recorded for the resolver")
    }

    /// A rejected write is not a transport failure, so it must not burn a retry attempt: retrying
    /// would only replay the same losing write.
    func testARejectedWriteIsNotRecordedAsARetryableFailure() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.rejectSaveWithConflict = 4

        await sut.syncNow()

        XCTAssertEqual(store.document(id: "d1")?.pendingEdit?.attemptCount, 0)
        XCTAssertNil(store.document(id: "d1")?.pendingEdit?.lastError)
    }

    /// The guard is only worth anything if it actually reaches the server. A cached document
    /// carrying a version must send it as `expectedContentVersion`.
    func testTheEditsBaseVersionIsSentAsTheGuard() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original", contentVersion: 12)
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.serverContentVersion = 12
        content.savedContentVersion = 13

        await sut.syncNow()

        XCTAssertEqual(content.sentExpectedVersions, [12])
        XCTAssertEqual(store.document(id: "d1")?.serverContentVersion, 13,
                       "The cache advances to the version the save produced")
    }

    /// A cache written before versions were tracked has no base version. It must still upload —
    /// unguarded, exactly as it did before — rather than refusing to sync.
    func testADocumentCachedWithoutAVersionStillUploadsUnguarded() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt

        await sut.syncNow()

        XCTAssertEqual(content.sentExpectedVersions, [nil])
        XCTAssertEqual(content.savedTexts, ["mine"])
    }

    func testAlreadyConflictedDocumentsAreSkipped() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        try store.markConflict(id: "d1", serverModifiedAt: Date().addingTimeInterval(60))
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty, "A conflict waits for the user, not for a retry")
    }

    func testResolvingKeepingLocalLetsTheNextDrainUpload() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        let base = store.document(id: "d1")!.pendingEdit!.baseServerModifiedAt
        content.serverModifiedAt = base.addingTimeInterval(60)
        await sut.syncNow()
        XCTAssertNotNil(store.document(id: "d1")?.conflict)

        try store.resolveKeepingLocal(id: "d1")
        content.saveResult = Date()
        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["mine"])
        XCTAssertNil(store.document(id: "d1")?.pendingEdit)
    }

    // MARK: - Failure handling

    func testAFailedUploadIsRecordedAndTheEditKept() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = nil
        content.saveError = URLError(.timedOut)

        await sut.syncNow()

        XCTAssertNotNil(store.document(id: "d1")?.pendingEdit)
        XCTAssertEqual(store.document(id: "d1")?.pendingEdit?.attemptCount, 1)
        guard case .failed = sut.state else {
            return XCTFail("Expected a failed state, got \(sut.state)")
        }
    }

    func testOneFailingDocumentDoesNotStopTheOthers() async throws {
        let dek1 = try await cacheDocument(id: "d1", text: "one")
        let dek2 = try await cacheDocument(id: "d2", text: "two")
        try store.writePendingEdit(DocumentBody.text("first"), id: "d1", dek: dek1)
        try await Task.sleep(nanoseconds: 10_000_000)
        try store.writePendingEdit(DocumentBody.text("second"), id: "d2", dek: dek2)
        content.serverModifiedAt = nil
        content.failFirstSaveOnly = true
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["second"], "The second document still uploaded")
        XCTAssertNotNil(store.document(id: "d1")?.pendingEdit)
        XCTAssertNil(store.document(id: "d2")?.pendingEdit)
    }

    func testAnEditInsideItsBackoffWindowIsSkipped() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        try store.recordFailure(id: "d1", error: "boom")
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty)
    }

    // MARK: - Mutation queue

    func testQueuedDeleteIsReplayed() async {
        store.enqueue(PendingMutation(itemID: "d1", kind: .delete(isFolder: false)))

        await sut.syncNow()

        XCTAssertEqual(drive.trashed.map(\.itemID), ["d1"])
        XCTAssertTrue(store.pendingMutations.isEmpty)
    }

    func testQueuedMoveIsReplayed() async {
        store.enqueue(PendingMutation(itemID: "d1", kind: .move(isFolder: false, targetFolderID: "f1")))

        await sut.syncNow()

        XCTAssertEqual(drive.moved.first?.itemID, "d1")
        XCTAssertEqual(drive.moved.first?.target, "f1")
        XCTAssertTrue(store.pendingMutations.isEmpty)
    }

    func testQueuedRenameIsReplayed() async {
        store.enqueue(PendingMutation(itemID: "d1", kind: .rename(isFolder: false, newName: "New.md")))

        await sut.syncNow()

        XCTAssertEqual(drive.renamed.first?.newName, "New.md")
        XCTAssertTrue(store.pendingMutations.isEmpty)
    }

    func testMutationsReplayInTheOrderTheyWereQueued() async {
        store.enqueue(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f1"),
                                      queuedAt: Date(timeIntervalSince1970: 100)))
        store.enqueue(PendingMutation(itemID: "b", kind: .delete(isFolder: false),
                                      queuedAt: Date(timeIntervalSince1970: 200)))

        await sut.syncNow()

        XCTAssertEqual(drive.callOrder, ["move:a", "trash:b"])
    }

    func testAFailedMutationIsKeptAndBackedOff() async {
        store.enqueue(PendingMutation(itemID: "d1", kind: .delete(isFolder: false)))
        drive.error = URLError(.timedOut)

        await sut.syncNow()

        XCTAssertEqual(store.pendingMutations.count, 1)
        XCTAssertEqual(store.pendingMutations.first?.attemptCount, 1)
    }

    /// Edits go before mutations: a document about to be trashed should still have its last edit
    /// uploaded, so the version history has it.
    func testEditsAreUploadedBeforeMetadataMutations() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("final text"), id: "d1", dek: dek)
        store.enqueue(PendingMutation(itemID: "d1", kind: .delete(isFolder: false)))
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["final text"])
        XCTAssertEqual(drive.trashed.map(\.itemID), ["d1"])
    }

    // MARK: - Concurrency

    /// Two drains at once would upload the same edit twice.
    func testConcurrentSyncRequestsShareASingleDrain() async throws {
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = nil
        content.saveResult = Date()

        async let first: Void = sut.syncNow()
        async let second: Void = sut.syncNow()
        _ = await (first, second)

        XCTAssertEqual(content.savedTexts.count, 1)
    }

    // MARK: - Auto-sync settings

    func testManualSyncRunsEvenWhenAutoSyncIsOff() async throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.autoSyncEnabled = false
        sut = SyncEngine(store: store, monitor: monitor, content: content, drive: drive, settings: settings)
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["mine"],
                       "Asking for a sync is not the same as the app deciding to")
    }

    /// "Sync on cellular = off" must hold the queue back on a metered path.
    func testAnExpensivePathIsNotUsedWhenCellularSyncIsOff() async throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.syncOnCellular = false
        sut = SyncEngine(store: store, monitor: monitor, content: content, drive: drive, settings: settings)
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        monitor.setPathForTesting(isOnline: true, isExpensive: true)

        await sut.syncNow()

        XCTAssertTrue(content.savedTexts.isEmpty)
        XCTAssertEqual(sut.state, .offline)
    }

    func testAnExpensivePathIsUsedWhenCellularSyncIsOn() async throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.syncOnCellular = true
        sut = SyncEngine(store: store, monitor: monitor, content: content, drive: drive, settings: settings)
        let dek = try await cacheDocument(id: "d1", text: "original")
        try store.writePendingEdit(DocumentBody.text("mine"), id: "d1", dek: dek)
        monitor.setPathForTesting(isOnline: true, isExpensive: true)
        content.serverModifiedAt = nil
        content.saveResult = Date()

        await sut.syncNow()

        XCTAssertEqual(content.savedTexts, ["mine"])
    }

    // MARK: - State messages

    func testStateMessagesReadSensibly() {
        XCTAssertEqual(SyncEngine.State.idle.message, "Up to date")
        XCTAssertEqual(SyncEngine.State.offline.message, "Offline")
        XCTAssertEqual(SyncEngine.State.syncing(remaining: 1).message, "Syncing 1 item…")
        XCTAssertEqual(SyncEngine.State.syncing(remaining: 3).message, "Syncing 3 items…")
        XCTAssertEqual(SyncEngine.State.failed("boom").message, "Sync failed: boom")
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "SyncEngineTests-\(UUID().uuidString)")!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaults.description) }
        return defaults
    }

    /// Puts a real, decryptable document into the cache and returns its DEK.
    @discardableResult
    /// Caches a document as if it had been downloaded. `contentVersion` is what `/info` reports
    /// during the download, which is how the cache learns the version a later save is guarded with;
    /// nil serves a 404 instead, standing in for a cache written before versions existed.
    private func cacheDocument(id: String, text: String, contentVersion: Int? = nil) async throws -> Bytes {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try realContent.encrypt(text: text, dek: dek,
                                                 xcss: sodium.secretStream.xchacha20poly1305)
        let sealed = try realContent.sealDEK(dek)
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url?.path ?? ""
            if path.hasSuffix("/key") {
                return (ok, Data(#"{"encryptedFileKey":"\#(sealed.sealed)","keyVersion":\#(sealed.keyVersion)}"#.utf8))
            }
            if path.hasSuffix("/info") {
                guard let contentVersion else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                            httpVersion: nil, headerFields: nil)!, Data())
                }
                return (ok, Data(Fixture.fileJSON(id: id, contentVersion: contentVersion).utf8))
            }
            return (ok, ciphertext)
        }
        try await store.download(Fixture.doc(id: id, name: "\(id).md"))
        return dek
    }
}

// MARK: - FakeContentSyncer

/// Stands in for `DocContentService` so the drain loop's decisions — especially the conflict check
/// — can be driven directly, without staging an HTTP response for every branch.
@MainActor
private final class FakeContentSyncer: DocSyncing {

    var serverModifiedAt: Date?
    var saveResult: Date = Date()
    var saveError: Error?
    var failFirstSaveOnly = false
    /// The `contentVersion` `/info` reports, and the one a successful save returns.
    var serverContentVersion: Int?
    var savedContentVersion: Int?
    /// Set to have the next save be rejected by the "server" the way a real stale write is.
    var rejectSaveWithConflict: Int?

    private(set) var savedTexts: [String] = []
    /// Every `expectedContentVersion` the engine sent, in order — the guard is the whole point,
    /// so a test needs to see it was actually attached and not silently dropped.
    private(set) var sentExpectedVersions: [Int?] = []
    private var saveCount = 0

    func fetchServerModifiedAt(for item: DocItem) async throws -> Date? {
        serverModifiedAt
    }

    func fileInfo(for fileID: String) async throws -> DocFileInfo? {
        guard let serverModifiedAt else { return nil }
        return DocFileInfo(id: fileID, name: "doc", sizeBytes: 0, folderID: nil,
                           mimeType: DocItem.documentMIME, updatedAt: serverModifiedAt,
                           deletedAt: nil, yourRole: .owner,
                           contentVersion: serverContentVersion)
    }

    @discardableResult
    func saveContent(_ body: DocumentBody, for item: DocItem, dek: Bytes,
                     expectedContentVersion: Int?) async throws -> DocContentService.SaveResult {
        saveCount += 1
        sentExpectedVersions.append(expectedContentVersion)
        if let rejectSaveWithConflict {
            throw DocContentError.contentVersionConflict(current: rejectSaveWithConflict)
        }
        if let saveError { throw saveError }
        if failFirstSaveOnly && saveCount == 1 { throw URLError(.timedOut) }
        savedTexts.append(body.plainText)
        return DocContentService.SaveResult(updatedAt: saveResult,
                                            contentVersion: savedContentVersion)
    }
}

// MARK: - FakeDriveMutator

@MainActor
private final class FakeDriveMutator: DocMutating {

    var error: Error?

    private(set) var trashed: [(itemID: String, isFolder: Bool)] = []
    private(set) var moved: [(itemID: String, isFolder: Bool, target: String?)] = []
    private(set) var renamed: [(itemID: String, newName: String, isFolder: Bool)] = []
    private(set) var callOrder: [String] = []

    func sendTrash(itemID: String, isFolder: Bool) async throws {
        if let error { throw error }
        trashed.append((itemID, isFolder))
        callOrder.append("trash:\(itemID)")
    }

    func sendMove(itemID: String, isFolder: Bool, targetFolderID: String?) async throws {
        if let error { throw error }
        moved.append((itemID, isFolder, targetFolderID))
        callOrder.append("move:\(itemID)")
    }

    @discardableResult
    func sendRename(itemID: String, newName: String, isFolder: Bool) async throws -> Date {
        if let error { throw error }
        renamed.append((itemID, newName, isFolder))
        callOrder.append("rename:\(itemID)")
        return Date()
    }
}
