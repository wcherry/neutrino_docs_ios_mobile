import Foundation
import Sodium
import os.log

// MARK: - OfflineStoreError

enum OfflineStoreError: LocalizedError {
    case notCached
    case hasPendingEdit
    case noEncryptionKey
    case decryptionFailed
    case ioFailure(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notCached:          return "That document isn't available offline."
        case .hasPendingEdit:     return "That document has unsynced changes. Sync it before removing the offline copy."
        case .noEncryptionKey:    return "No encryption key found. Import your key before using offline documents."
        case .decryptionFailed:   return "Failed to decrypt the offline copy of the document."
        case .ioFailure(let err): return "Offline storage error: \(err.localizedDescription)"
        }
    }
}

// MARK: - OfflineStore

/// The on-disk cache of documents available offline, plus the queue of mutations waiting to reach
/// the server.
///
/// Layout, rooted at Application Support/OfflineDocs (or an injected directory in tests):
///
///     index.json          the catalogue, [OfflineDoc]
///     queue.json          the mutation queue, [PendingMutation]
///     <id>.bin            server ciphertext of the cached base version
///     <id>.pending.bin    ciphertext of the local pending edit, same DEK
///
/// The cache stores the server's ciphertext verbatim and re-encrypts local edits with the very same
/// per-file DEK, so cache-at-rest security is identical to the wire protocol and reading anything
/// back still requires the Curve25519 key pair in the Keychain. **No plaintext is ever written to
/// disk.** All crypto and networking is delegated to `DocContentService`; this type invents none of
/// its own.
@MainActor
final class OfflineStore: ObservableObject {

    // MARK: - Published State

    /// The catalogue, sorted by name, case-insensitive.
    @Published private(set) var documents: [OfflineDoc] = []

    /// Metadata changes (delete, move, rename) waiting to be replayed, oldest first.
    @Published private(set) var pendingMutations: [PendingMutation] = []

    // MARK: - Dependencies

    /// Set once at app launch — the store delegates all crypto and networking to it.
    weak var contentService: DocContentService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "OfflineStore")

    /// Root of the cache. Injected in tests; defaults to Application Support/OfflineDocs.
    private let directory: URL

    private static let indexFileName = "index.json"
    private static let queueFileName = "queue.json"

    /// Dates round-trip exactly with the default (`.deferredToDate`) strategy, which matters
    /// because `serverModifiedAt` values are compared for conflict detection.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Init

    /// - Parameter directory: `nil` uses Application Support/OfflineDocs. Tests pass a temp directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        prepareDirectory()
        loadIndex()
        loadQueue()
    }

    // MARK: - Queries

    func document(id: String) -> OfflineDoc? {
        documents.first { $0.id == id }
    }

    func isAvailableOffline(_ itemID: String) -> Bool {
        document(id: itemID) != nil
    }

    /// Documents with an unsynced body edit.
    var pendingEditCount: Int {
        documents.reduce(into: 0) { $0 += ($1.pendingEdit == nil ? 0 : 1) }
    }

    var conflictCount: Int {
        documents.reduce(into: 0) { $0 += ($1.conflict == nil ? 0 : 1) }
    }

    /// Everything waiting to reach the server — body edits plus queued mutations. This is the
    /// number the Offline tab badges.
    var totalPendingCount: Int {
        pendingEditCount + pendingMutations.count
    }

    /// Total size of the cached ciphertext blobs actually present on disk.
    var totalBytesOnDisk: Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(into: Int64(0)) { total, name in
            guard name.hasSuffix(".bin") else { return }
            let path = directory.appendingPathComponent(name).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber
            total += size?.int64Value ?? 0
        }
    }

    // MARK: - Download / Remove

    /// Fetches the sealed DEK and encrypted body for `item` and persists both, replacing any
    /// previously cached base version.
    ///
    /// A pending edit for the same document is preserved untouched — its `baseServerModifiedAt`
    /// still points at the version it was written against, so the sync engine will still detect
    /// the conflict.
    func download(_ item: DocItem, reason: CacheReason = .pinned) async throws {
        guard let content = contentService else {
            logger.error("download: contentService not set")
            throw OfflineStoreError.noEncryptionKey
        }

        let ciphertext: Data
        let sealedDEK: String
        do {
            (ciphertext, sealedDEK) = try await content.downloadEncrypted(for: item)
        } catch {
            logger.error("download failed: id=\(item.id, privacy: .public) \(error, privacy: .public)")
            throw OfflineStoreError.ioFailure(underlying: error)
        }

        // Decrypt once, in memory only — both to verify the blob is readable with this device's key
        // pair before it is cached, and to record the plaintext size for display.
        let dek = try unseal(sealedDEK, using: content)
        let plaintext = try decrypt(ciphertext, dek: dek, using: content)

        // Prefer the server's authoritative timestamp; fall back to the listing's if the lookup is
        // unavailable, since a slightly stale base date only makes conflict detection more
        // conservative.
        var serverModifiedAt = item.modifiedAt
        if let fresh = try? await content.fetchServerModifiedAt(for: item) {
            serverModifiedAt = fresh
        }

        try write(ciphertext, to: baseURL(for: item.id))

        var doc = document(id: item.id) ?? OfflineDoc(
            id: item.id, name: item.name, parentID: item.parentID, mimeType: item.mimeType,
            sealedDEK: sealedDEK, serverModifiedAt: serverModifiedAt, cachedAt: Date(),
            sizeBytes: Int64(plaintext.utf8.count), pendingEdit: nil, conflict: nil,
            cacheReason: reason
        )
        doc.name = item.name
        doc.parentID = item.parentID
        doc.mimeType = item.mimeType ?? doc.mimeType
        doc.sealedDEK = sealedDEK
        doc.serverModifiedAt = serverModifiedAt
        doc.cachedAt = Date()
        // A document the user has explicitly pinned never gets downgraded to an automatic reason by
        // a later background refresh — that would make it evictable behind their back.
        if doc.cacheReason != .pinned { doc.cacheReason = reason }
        if doc.pendingEdit == nil { doc.sizeBytes = Int64(plaintext.utf8.count) }
        try upsert(doc)
        logger.debug("download succeeded: id=\(item.id, privacy: .public) (\(ciphertext.count) bytes)")
    }

    /// Removes a document from the cache. Refuses to discard unsynced work.
    func remove(id: String) throws {
        guard let doc = document(id: id) else { throw OfflineStoreError.notCached }
        guard doc.pendingEdit == nil else {
            logger.error("remove refused: id=\(id, privacy: .public) has a pending edit")
            throw OfflineStoreError.hasPendingEdit
        }
        deleteBlobs(for: id)
        documents.removeAll { $0.id == id }
        try saveIndex()
        logger.debug("remove: id=\(id, privacy: .public)")
    }

    /// Removes every cached document, skipping any that still has unsynced changes.
    func removeAll() throws {
        let removable = documents.filter { $0.pendingEdit == nil }
        for doc in removable { deleteBlobs(for: doc.id) }
        let removableIDs = Set(removable.map(\.id))
        documents.removeAll { removableIDs.contains($0.id) }
        try saveIndex()
        logger.debug("removeAll: removed \(removable.count), kept \(self.documents.count) with pending edits")
    }

    /// Drops automatically-cached documents, keeping pinned ones and anything unsynced.
    ///
    /// This is what makes "cache recently viewed / favorites" safe to leave on: the automatic
    /// entries are disposable by construction, so the cache can be trimmed without ever consulting
    /// the user about a document they chose to keep.
    func evictAutomaticEntries() throws {
        let evictable = documents.filter { $0.cacheReason.isEvictable && $0.pendingEdit == nil }
        for doc in evictable { deleteBlobs(for: doc.id) }
        let ids = Set(evictable.map(\.id))
        documents.removeAll { ids.contains($0.id) }
        try saveIndex()
        logger.debug("evictAutomaticEntries: removed \(evictable.count)")
    }

    // MARK: - Plaintext access

    /// Decrypts the document for reading or editing. A pending edit wins over the cached base
    /// version.
    ///
    /// Returns the DEK alongside the body so the editing session can re-encrypt without unsealing
    /// again — the same contract as `DocContentService.loadContent(for:)`. The cached blob holds the
    /// stored ProseMirror JSON byte-for-byte, so it is decoded here exactly as a downloaded body is.
    func readPlaintext(id: String) throws -> (body: DocumentBody, dek: Bytes) {
        guard let doc = document(id: id) else { throw OfflineStoreError.notCached }
        guard let content = contentService else { throw OfflineStoreError.noEncryptionKey }

        let dek = try unseal(doc.sealedDEK, using: content)

        // Fall back to the base version if the pending blob went missing (interrupted write, manual
        // cache surgery): better a stale read than a hard failure.
        var url = baseURL(for: id)
        if doc.pendingEdit != nil, FileManager.default.fileExists(atPath: pendingURL(for: id).path) {
            url = pendingURL(for: id)
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("readPlaintext: blob missing for id=\(id, privacy: .public)")
            throw OfflineStoreError.notCached
        }
        let stored = try decrypt(data, dek: dek, using: content)
        return (NeutrinoDocumentCodec.decode(stored), dek)
    }

    /// Encrypts `body` with the document's own DEK and stores it as the pending edit. Only
    /// ciphertext ever reaches disk.
    ///
    /// The edit is stored in the wire format, so the sync engine can upload
    /// the blob later without needing the layout metadata that produced it — which it would not
    /// have after an app restart.
    ///
    /// An existing pending edit keeps its `baseServerModifiedAt`, so a chain of offline edits is
    /// still measured against the version they started from.
    func writePendingEdit(_ body: DocumentBody, id: String, dek: Bytes) throws {
        guard var doc = document(id: id) else { throw OfflineStoreError.notCached }
        guard let content = contentService else { throw OfflineStoreError.noEncryptionKey }

        let stored = NeutrinoDocumentCodec.encode(body)
        let ciphertext: Data
        do {
            ciphertext = try content.encrypt(text: stored, dek: dek,
                                             xcss: Self.sodium.secretStream.xchacha20poly1305)
        } catch {
            logger.error("writePendingEdit: encrypt failed id=\(id, privacy: .public)")
            throw OfflineStoreError.decryptionFailed
        }
        try write(ciphertext, to: pendingURL(for: id))

        doc.pendingEdit = PendingEdit(
            editedAt: Date(),
            baseServerModifiedAt: doc.pendingEdit?.baseServerModifiedAt ?? doc.serverModifiedAt,
            attemptCount: 0,
            lastError: nil,
            lastAttemptAt: nil
        )
        doc.sizeBytes = Int64(stored.utf8.count)
        try upsert(doc)
        logger.debug("writePendingEdit: id=\(id, privacy: .public) (\(stored.utf8.count) stored bytes)")
    }

    // MARK: - Sync-engine callbacks

    /// Replaces the cached base version with a newer server ciphertext. Pending edits and conflicts
    /// are left alone; the caller decides what happens to them.
    func acceptServerVersion(_ ciphertext: Data, id: String, serverModifiedAt: Date, sizeBytes: Int64) throws {
        guard var doc = document(id: id) else { throw OfflineStoreError.notCached }
        try write(ciphertext, to: baseURL(for: id))
        doc.serverModifiedAt = serverModifiedAt
        doc.sizeBytes = sizeBytes
        doc.cachedAt = Date()
        try upsert(doc)
        logger.debug("acceptServerVersion: id=\(id, privacy: .public)")
    }

    /// Refreshes the cached base version from the body this device just successfully uploaded,
    /// without going back to the network for bytes we already have.
    ///
    /// The ciphertext differs from the server's — a fresh secretstream header — but decrypts to
    /// exactly what the server now holds, under the same DEK, which is only true because the body
    /// is encoded here the same way `DocContentService` encoded it for the upload.
    func cacheLocalVersion(_ body: DocumentBody, id: String, dek: Bytes,
                           serverModifiedAt: Date) throws {
        guard document(id: id) != nil else { throw OfflineStoreError.notCached }
        guard let content = contentService else { throw OfflineStoreError.noEncryptionKey }

        let stored = NeutrinoDocumentCodec.encode(body)
        let ciphertext: Data
        do {
            ciphertext = try content.encrypt(text: stored, dek: dek,
                                             xcss: Self.sodium.secretStream.xchacha20poly1305)
        } catch {
            throw OfflineStoreError.decryptionFailed
        }
        try acceptServerVersion(ciphertext, id: id, serverModifiedAt: serverModifiedAt,
                                sizeBytes: Int64(stored.utf8.count))
    }

    /// Called after a successful upload. The pending ciphertext is promoted to the cached base
    /// version — it decrypts to exactly what the server now holds — and any conflict flag is
    /// cleared.
    func clearPendingEdit(id: String, serverModifiedAt: Date) throws {
        guard var doc = document(id: id) else { throw OfflineStoreError.notCached }
        let pending = pendingURL(for: id)
        if FileManager.default.fileExists(atPath: pending.path) {
            do {
                let data = try Data(contentsOf: pending)
                try write(data, to: baseURL(for: id))
                try? FileManager.default.removeItem(at: pending)
            } catch {
                throw OfflineStoreError.ioFailure(underlying: error)
            }
        }
        doc.pendingEdit = nil
        doc.conflict = nil
        doc.serverModifiedAt = serverModifiedAt
        doc.cachedAt = Date()
        try upsert(doc)
        logger.debug("clearPendingEdit: id=\(id, privacy: .public)")
    }

    /// Moves the document's base timestamp forward after a *metadata-only* server write — a rename
    /// or a star, both of which set `updated_at = now` without touching content.
    ///
    /// Without this, `SyncEngine` sees the server ahead of the version a pending edit was written
    /// against and flags a conflict, asking the user to choose between two copies of their own
    /// text. The rebase is skipped when the cache already knows about a version at or beyond the
    /// one the metadata write was made against, so a genuine remote content edit still conflicts.
    ///
    /// Best-effort: the metadata write has already succeeded, and the worst outcome of a failure
    /// here is the spurious conflict this exists to avoid, which the user can still resolve.
    func rebasePendingEdit(id: String, previousModifiedAt: Date, serverModifiedAt: Date) {
        guard var doc = document(id: id) else { return }
        guard serverModifiedAt > doc.serverModifiedAt else { return }
        guard doc.serverModifiedAt <= previousModifiedAt else {
            logger.debug("rebasePendingEdit skipped: id=\(id, privacy: .public) — cache already newer")
            return
        }
        doc.serverModifiedAt = serverModifiedAt
        if doc.pendingEdit != nil {
            doc.pendingEdit?.baseServerModifiedAt = serverModifiedAt
        }
        try? upsert(doc)
    }

    /// Records a failed upload attempt, pushing the document further down the backoff curve.
    func recordFailure(id: String, error: String) throws {
        guard var doc = document(id: id), doc.pendingEdit != nil else {
            throw OfflineStoreError.notCached
        }
        doc.pendingEdit?.attemptCount += 1
        doc.pendingEdit?.lastError = error
        doc.pendingEdit?.lastAttemptAt = Date()
        try upsert(doc)
        logger.error("recordFailure: id=\(id, privacy: .public) attempt=\(doc.pendingEdit?.attemptCount ?? 0)")
    }

    /// Flags the document as conflicted: the server moved past the version the pending edit was
    /// written against, so uploading would clobber somebody else's work.
    func markConflict(id: String, serverModifiedAt: Date) throws {
        guard var doc = document(id: id) else { throw OfflineStoreError.notCached }
        doc.conflict = Conflict(detectedAt: Date(), serverModifiedAt: serverModifiedAt)
        try upsert(doc)
        logger.error("markConflict: id=\(id, privacy: .public)")
    }

    // MARK: - Conflict resolution

    /// Keeps the local edit: rebases it onto the newer server version so the next drain uploads it
    /// (deliberately overwriting the remote change), resets the backoff, and clears the flag.
    func resolveKeepingLocal(id: String) throws {
        guard var doc = document(id: id), doc.pendingEdit != nil else {
            throw OfflineStoreError.notCached
        }
        if let conflict = doc.conflict, conflict.serverModifiedAt > doc.serverModifiedAt {
            doc.serverModifiedAt = conflict.serverModifiedAt
        }
        doc.pendingEdit?.baseServerModifiedAt = doc.conflict?.serverModifiedAt ?? doc.serverModifiedAt
        doc.pendingEdit?.attemptCount = 0
        doc.pendingEdit?.lastError = nil
        doc.pendingEdit?.lastAttemptAt = nil
        doc.conflict = nil
        try upsert(doc)
        logger.debug("resolveKeepingLocal: id=\(id, privacy: .public)")
    }

    /// Keeps the server's version: throws the local edit away and re-downloads.
    func resolveKeepingServer(id: String) async throws {
        guard var doc = document(id: id) else { throw OfflineStoreError.notCached }
        try? FileManager.default.removeItem(at: pendingURL(for: id))
        doc.pendingEdit = nil
        doc.conflict = nil
        try upsert(doc)
        logger.debug("resolveKeepingServer: id=\(id, privacy: .public) — re-downloading")
        try await download(doc.asDocItem, reason: doc.cacheReason)
    }

    // MARK: - Mutation queue

    /// Queues a metadata change made while offline.
    ///
    /// Superseded entries for the same item are dropped: replaying "rename then delete" is two
    /// round trips for one outcome, and the rename can fail on its own and strand the queue.
    func enqueue(_ mutation: PendingMutation) {
        pendingMutations.removeAll { mutation.supersedes($0) }
        pendingMutations.append(mutation)
        pendingMutations.sort { $0.queuedAt < $1.queuedAt }
        saveQueue()
        logger.debug("enqueue: \(mutation.summary, privacy: .public) for id=\(mutation.itemID, privacy: .public)")
    }

    /// Removes a mutation after it has been successfully replayed.
    func removeMutation(id: UUID) {
        pendingMutations.removeAll { $0.id == id }
        saveQueue()
    }

    /// Records a failed replay, pushing the mutation down the same backoff curve as an edit.
    func recordMutationFailure(id: UUID, error: String) {
        guard let idx = pendingMutations.firstIndex(where: { $0.id == id }) else { return }
        pendingMutations[idx].attemptCount += 1
        pendingMutations[idx].lastError = error
        pendingMutations[idx].lastAttemptAt = Date()
        saveQueue()
        logger.error("recordMutationFailure: attempt=\(self.pendingMutations[idx].attemptCount)")
    }

    /// Discards the whole queue. Offered in Settings for a queue wedged behind a mutation the
    /// server will never accept.
    func clearMutationQueue() {
        pendingMutations = []
        saveQueue()
    }

    /// The mutations eligible to run now, oldest first.
    func drainableMutations(now: Date = Date()) -> [PendingMutation] {
        pendingMutations
            .filter { now >= $0.nextAttemptAt }
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    // MARK: - Metadata mirroring

    /// Keeps a cached document's name in step with a rename made in the browser, so the Offline tab
    /// does not keep showing the old title.
    func updateName(id: String, name: String) {
        guard var doc = document(id: id), doc.name != name else { return }
        doc.name = name
        try? upsert(doc)
    }

    /// Same, for a move.
    func updateParent(id: String, parentID: String?) {
        guard var doc = document(id: id), doc.parentID != parentID else { return }
        doc.parentID = parentID
        try? upsert(doc)
    }

    // MARK: - Crypto helpers

    private func unseal(_ sealedDEK: String, using content: DocContentService) throws -> Bytes {
        do {
            return try content.unsealDEK(sealedDEK)
        } catch DocContentError.noEncryptionKey {
            throw OfflineStoreError.noEncryptionKey
        } catch {
            throw OfflineStoreError.decryptionFailed
        }
    }

    private func decrypt(_ data: Data, dek: Bytes, using content: DocContentService) throws -> String {
        do {
            return try content.decrypt(data: data, dek: dek)
        } catch {
            throw OfflineStoreError.decryptionFailed
        }
    }

    // MARK: - Paths

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OfflineDocs", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }
    private var queueURL: URL { directory.appendingPathComponent(Self.queueFileName) }
    private func baseURL(for id: String) -> URL { directory.appendingPathComponent("\(id).bin") }
    private func pendingURL(for id: String) -> URL { directory.appendingPathComponent("\(id).pending.bin") }

    // MARK: - Disk

    /// Creates the cache directory with data protection on and iCloud backup off. Failures are
    /// logged rather than thrown so the app still launches with an empty catalogue.
    private func prepareDirectory() {
        var url = directory
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            logger.error("prepareDirectory failed at \(self.directory.path, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            logger.error("write failed: \(url.lastPathComponent, privacy: .public)")
            throw OfflineStoreError.ioFailure(underlying: error)
        }
    }

    private func deleteBlobs(for id: String) {
        try? FileManager.default.removeItem(at: baseURL(for: id))
        try? FileManager.default.removeItem(at: pendingURL(for: id))
    }

    /// A corrupt, truncated, or absent index degrades to an empty catalogue rather than crashing.
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            documents = try Self.decoder.decode([OfflineDoc].self, from: data).sorted(by: Self.byName)
            logger.debug("loadIndex: \(self.documents.count) cached document(s)")
        } catch {
            logger.error("loadIndex: index.json unreadable, starting empty: \(error, privacy: .public)")
            documents = []
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL) else { return }
        do {
            pendingMutations = try Self.decoder.decode([PendingMutation].self, from: data)
                .sorted { $0.queuedAt < $1.queuedAt }
            logger.debug("loadQueue: \(self.pendingMutations.count) queued mutation(s)")
        } catch {
            logger.error("loadQueue: queue.json unreadable, starting empty: \(error, privacy: .public)")
            pendingMutations = []
        }
    }

    /// Rewritten atomically on every mutation so a crash mid-write cannot leave a half-index.
    private func saveIndex() throws {
        let data: Data
        do {
            data = try Self.encoder.encode(documents)
        } catch {
            throw OfflineStoreError.ioFailure(underlying: error)
        }
        try write(data, to: indexURL)
    }

    /// Best-effort: a queue that fails to persist still works for this session, and losing it is
    /// less bad than refusing the mutation the user just made.
    private func saveQueue() {
        guard let data = try? Self.encoder.encode(pendingMutations) else { return }
        try? write(data, to: queueURL)
    }

    private func upsert(_ doc: OfflineDoc) throws {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
        documents.sort(by: Self.byName)
        try saveIndex()
    }

    private static func byName(_ lhs: OfflineDoc, _ rhs: OfflineDoc) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order == .orderedSame { return lhs.id < rhs.id }
        return order == .orderedAscending
    }
}
