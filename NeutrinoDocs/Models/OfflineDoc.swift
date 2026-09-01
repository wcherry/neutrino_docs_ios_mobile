import Foundation

// MARK: - OfflineDoc

/// A single document that has been cached for offline use.
///
/// The catalogue of these values is persisted as `index.json` inside the offline cache directory;
/// the document's body never appears here. The body lives next to the index as `<id>.bin` (the
/// server's ciphertext, byte-for-byte) and, when the user has edited the document while offline,
/// `<id>.pending.bin` (the local edit, re-encrypted with the same DEK). Nothing in the cache is
/// ever stored as plaintext.
struct OfflineDoc: Codable, Identifiable, Hashable {

    // MARK: - Properties

    /// Drive file ID — also the base name of the document's blobs on disk.
    let id: String
    var name: String
    var parentID: String?
    var mimeType: String?
    /// base64url `crypto_box_seal` blob exactly as returned by `GET /files/{id}/key`.
    var sealedDEK: String
    /// Which identity version `sealedDEK` was sealed to.
    ///
    /// Cached alongside the blob because the cache has to be readable with no network: going back
    /// to `/files/{id}/key` for the version is the one thing an offline read cannot do. Optional,
    /// and nil for caches written before this existed — read as 1, which is what the server
    /// defaults the column to for the same rows.
    var keyVersion: Int?
    /// `updatedAt` of the server version stored in `<id>.bin`.
    var serverModifiedAt: Date
    /// `contentVersion` of that same stored version, when the server reported one.
    ///
    /// Optional, and decoded as nil for caches written before this existed — those documents
    /// simply save unguarded on their next drain, exactly as they did before, and pick up a
    /// version from the server's response afterwards.
    var serverContentVersion: Int?
    var cachedAt: Date
    /// Plaintext size, for display only.
    var sizeBytes: Int64
    var pendingEdit: PendingEdit?
    var conflict: Conflict?
    /// Why this document is in the cache. Documents pinned by the user survive eviction;
    /// documents cached automatically because they were opened, recent, or starred do not.
    var cacheReason: CacheReason = .opened

    // MARK: - Computed

    /// The cached DEK and the version that opens it, in the shape the content service takes.
    var sealedFileKey: SealedFileKey {
        SealedFileKey(sealed: sealedDEK, keyVersion: keyVersion ?? 1)
    }

    /// Rebuilds a `DocItem` so a cached document can be passed straight to `DocContentService`.
    var asDocItem: DocItem {
        DocItem(
            id: id,
            name: name,
            type: .file,
            parentID: parentID,
            size: sizeBytes,
            modifiedAt: serverModifiedAt,
            isTrashed: false,
            mimeType: mimeType ?? DocItem.documentMIME,
            contentVersion: serverContentVersion
        )
    }
}

// MARK: - CacheReason

/// Why a document is held in the offline cache.
///
/// Phase 1 asks the cache to hold "open documents, recently viewed, favorites". Recording *which*
/// of those brought a document in is what lets the cache be trimmed later without discarding
/// something the user deliberately kept — `.pinned` is the user's own choice and is never evicted
/// automatically.
enum CacheReason: String, Codable, Hashable, CaseIterable {
    /// The user explicitly chose "Make Available Offline".
    case pinned
    /// Cached because the user opened it.
    case opened
    /// Cached because it appeared in the Recents listing.
    case recent
    /// Cached because it is starred.
    case favorite

    /// Whether automatic cache maintenance may evict a document held for this reason.
    var isEvictable: Bool { self != .pinned }

    var displayName: String {
        switch self {
        case .pinned:   return "Kept offline"
        case .opened:   return "Opened"
        case .recent:   return "Recent"
        case .favorite: return "Favorite"
        }
    }
}

// MARK: - PendingEdit

/// A local body edit that has not yet reached the server.
struct PendingEdit: Codable, Hashable {
    var editedAt: Date
    /// The server version this edit was made against. If the server has moved past it by the time
    /// we try to upload, the edit is a conflict rather than a save.
    var baseServerModifiedAt: Date
    /// The same base expressed as Drive's `contentVersion`. This is what actually guards the
    /// upload: it is sent as `expectedContentVersion` so the *server* decides, atomically with the
    /// write, whether the edit is still current. `baseServerModifiedAt` remains for the pre-flight
    /// check and for pre-version caches, but it can only ever be advisory — anything can land
    /// between reading it and uploading.
    var baseContentVersion: Int?
    var attemptCount: Int
    var lastError: String?
    /// When the last upload attempt failed. The retry backoff is measured from here rather than
    /// from `editedAt`, so an edit that has been sitting in the queue for a while is still held
    /// back between attempts instead of retrying on every drain.
    var lastAttemptAt: Date?

    /// The earliest moment this edit should be retried.
    var nextAttemptAt: Date {
        (lastAttemptAt ?? editedAt).addingTimeInterval(SyncBackoff.delay(forAttempt: attemptCount))
    }
}

// MARK: - Conflict

/// Recorded when the server moved ahead of the version a pending edit was based on.
struct Conflict: Codable, Hashable {
    var detectedAt: Date
    /// The newer server version that caused the conflict.
    var serverModifiedAt: Date
    /// That version's `contentVersion`, when the server reported one. Resolving in favour of the
    /// local copy rearms the upload guard against this, so the retry overwrites the change the
    /// user just chose to discard instead of conflicting on it a second time.
    var serverContentVersion: Int?
}

// MARK: - PendingMutation

/// A metadata change made while offline, waiting to be replayed against the server.
///
/// Body edits are *not* here: they live on `OfflineDoc.pendingEdit`, because an edit is tied to the
/// cached ciphertext it produced and to the server version it was based on, neither of which a
/// delete or a move has. Keeping them apart is what lets a document carry both a queued edit and a
/// queued move without one having to encode the other.
struct PendingMutation: Codable, Identifiable, Hashable {

    // MARK: - Kind

    enum Kind: Codable, Hashable {
        /// Move the item to Trash. Phase 1's "Pending deletes".
        case delete(isFolder: Bool)
        /// Re-parent the item. `targetFolderID == nil` means the root of the drive.
        case move(isFolder: Bool, targetFolderID: String?)
        /// Rename the item.
        case rename(isFolder: Bool, newName: String)

        var isFolder: Bool {
            switch self {
            case .delete(let isFolder),
                 .move(let isFolder, _),
                 .rename(let isFolder, _):
                return isFolder
            }
        }
    }

    // MARK: - Properties

    let id: UUID
    /// The Drive item the mutation applies to.
    let itemID: String
    let kind: Kind
    let queuedAt: Date
    var attemptCount: Int
    var lastError: String?
    var lastAttemptAt: Date?

    // MARK: - Init

    init(id: UUID = UUID(), itemID: String, kind: Kind, queuedAt: Date = Date(),
         attemptCount: Int = 0, lastError: String? = nil, lastAttemptAt: Date? = nil) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.queuedAt = queuedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
    }

    // MARK: - Computed

    /// The earliest moment this mutation should be retried — same backoff curve as a pending edit.
    var nextAttemptAt: Date {
        (lastAttemptAt ?? queuedAt).addingTimeInterval(SyncBackoff.delay(forAttempt: attemptCount))
    }

    /// Short description for the Offline tab's queue listing.
    var summary: String {
        switch kind {
        case .delete:                     return "Delete"
        case .move(_, let target):        return target == nil ? "Move to Drive root" : "Move"
        case .rename(_, let newName):     return "Rename to \(newName)"
        }
    }

    /// Whether this mutation makes an earlier queued one pointless.
    ///
    /// A delete supersedes any earlier move or rename of the same item — replaying "rename then
    /// delete" is two round trips for one outcome, and the rename can fail on its own and strand
    /// the queue. Two moves or two renames likewise collapse to the last one, since each is a
    /// whole-value assignment rather than an increment.
    func supersedes(_ other: PendingMutation) -> Bool {
        guard other.itemID == itemID else { return false }
        switch (kind, other.kind) {
        case (.delete, _):                  return true
        case (.move, .move):                return true
        case (.rename, .rename):            return true
        default:                            return false
        }
    }
}

// MARK: - SyncBackoff

/// Exponential backoff for the retry queue. Pure and testable: no clock, no I/O.
enum SyncBackoff {

    /// Longest a failing item is held back between attempts.
    static let maximumDelay: TimeInterval = 300

    /// 0 attempts -> 0s, then 5s, 15s, 45s, 135s, … capped at 300s.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // 5 * 3^(attempt - 1), computed in floating point so a large attemptCount cannot overflow
        // before the cap is applied.
        let raw = 5 * pow(3.0, Double(attempt - 1))
        return min(raw, maximumDelay)
    }
}
