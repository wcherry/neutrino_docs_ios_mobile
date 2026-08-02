import Foundation
import Combine
import Sodium
import os.log

// MARK: - DocSyncing

/// The slice of `DocContentService` the sync engine needs. Exists so the drain loop — and in
/// particular its conflict check — can be exercised without real HTTP.
@MainActor
protocol DocSyncing: AnyObject {
    func fetchServerModifiedAt(for item: DocItem) async throws -> Date?
    func saveContent(_ text: String, for item: DocItem, dek: Bytes) async throws -> Date
}

extension DocContentService: DocSyncing {}

// MARK: - DocMutating

/// The slice of `DocsDriveService` the sync engine needs to replay queued metadata changes.
@MainActor
protocol DocMutating: AnyObject {
    func sendTrash(itemID: String, isFolder: Bool) async throws
    func sendMove(itemID: String, isFolder: Bool, targetFolderID: String?) async throws
    @discardableResult
    func sendRename(itemID: String, newName: String, isFolder: Bool) async throws -> Date
}

extension DocsDriveService: DocMutating {}

// MARK: - SyncEngine

/// Drains the offline queue whenever the device has connectivity.
///
/// The single rule governing the whole feature: **a queued edit is only uploaded if the server is
/// still on the version the edit was written against.** If the server has moved ahead, the document
/// is flagged as a conflict and left for the user to resolve — a queued edit never silently
/// clobbers a remote one.
///
/// Two queues drain per pass, edits first and then metadata mutations. That order matters: a
/// document that is about to be trashed should still have its last edit uploaded, so the version
/// history has it, rather than being written to a file that has already gone.
@MainActor
final class SyncEngine: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case offline
        case syncing(remaining: Int)
        case failed(String)

        /// Copy for the sync status row.
        var message: String {
            switch self {
            case .idle:                  return "Up to date"
            case .offline:               return "Offline"
            case .syncing(let remaining): return remaining == 1 ? "Syncing 1 item…" : "Syncing \(remaining) items…"
            case .failed(let reason):    return "Sync failed: \(reason)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSyncedAt: Date?

    // MARK: - Dependencies

    private let store: OfflineStore
    private let monitor: NetworkMonitor
    private let content: any DocSyncing
    private weak var drive: (any DocMutating)?
    private let settings: AppSettings?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "SyncEngine")

    /// At most one drain runs at a time; every entry point funnels through this task.
    private var inFlight: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(store: OfflineStore,
         monitor: NetworkMonitor,
         content: any DocSyncing,
         drive: (any DocMutating)? = nil,
         settings: AppSettings? = nil) {
        self.store = store
        self.monitor = monitor
        self.content = content
        self.drive = drive
        self.settings = settings
    }

    /// Wires the drive service in after construction, since it and the engine are built together at
    /// app launch and each needs the other.
    func attach(drive: any DocMutating) {
        self.drive = drive
    }

    // MARK: - Lifecycle

    /// Begins observing connectivity; drains the queue whenever the device comes back online.
    /// This is Phase 1's "Auto-sync".
    func start() {
        guard cancellables.isEmpty else { return }
        state = canTransfer ? .idle : .offline
        monitor.$isOnline
            .removeDuplicates()
            .sink { isOnline in
                // `@Published` fires from the main actor, but hop explicitly so this stays correct
                // under stricter concurrency checking.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if isOnline {
                        self.logger.debug("connectivity restored — draining queue")
                        if self.isAutoSyncEnabled { self.requestSync() }
                    } else {
                        self.inFlight?.cancel()
                        self.state = .offline
                    }
                }
            }
            .store(in: &cancellables)
        if canTransfer, isAutoSyncEnabled { requestSync() }
    }

    /// Fire-and-forget drain, safe to call from a SwiftUI action. A no-op while a drain is already
    /// running.
    func requestSync() {
        _ = drainTask()
    }

    /// Awaitable drain, for pull-to-refresh, the Sync Now button, and tests. If a drain is already
    /// running this awaits that one rather than starting a second.
    ///
    /// This is Phase 1's "Manual sync", and it deliberately ignores the auto-sync setting: the user
    /// asking for a sync is not the same as the app deciding to.
    func syncNow() async {
        await drainTask().value
    }

    // MARK: - Settings

    private var isAutoSyncEnabled: Bool { settings?.autoSyncEnabled ?? true }

    /// Whether the current path is one we may transfer over, honouring the cellular preference.
    private var canTransfer: Bool {
        monitor.shouldSync(allowCellular: settings?.syncOnCellular ?? true)
    }

    // MARK: - Drain

    private func drainTask() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        // Created and stored without an intervening suspension point, so the body cannot start
        // before `inFlight` is set — the re-entrancy guard has no window.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            self.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func drain() async {
        guard canTransfer else {
            state = .offline
            return
        }

        let editQueue = drainableEdits()
        let mutationQueue = store.drainableMutations()

        guard !editQueue.isEmpty || !mutationQueue.isEmpty else {
            state = .idle
            lastSyncedAt = Date()
            return
        }

        var remaining = editQueue.count + mutationQueue.count
        logger.debug("drain: \(editQueue.count) edit(s), \(mutationQueue.count) mutation(s)")
        state = .syncing(remaining: remaining)
        var lastFailure: String?

        for doc in editQueue {
            if Task.isCancelled { break }
            if let failure = await uploadEdit(for: doc) { lastFailure = failure }
            remaining -= 1
            state = .syncing(remaining: remaining)
        }

        for mutation in mutationQueue {
            if Task.isCancelled { break }
            if let failure = await replay(mutation) { lastFailure = failure }
            remaining -= 1
            state = .syncing(remaining: remaining)
        }

        if !canTransfer || Task.isCancelled {
            // Connectivity dropped mid-drain; whatever is left stays queued.
            state = canTransfer ? .idle : .offline
        } else if let lastFailure {
            state = .failed(lastFailure)
        } else {
            state = .idle
            lastSyncedAt = Date()
        }
    }

    /// Documents with an edit that is out of its backoff window and not already conflicted, oldest
    /// edit first.
    private func drainableEdits(now: Date = Date()) -> [OfflineDoc] {
        store.documents
            .filter { doc in
                guard let edit = doc.pendingEdit else { return false }
                guard doc.conflict == nil else { return false }
                return now >= edit.nextAttemptAt
            }
            .sorted { ($0.pendingEdit?.editedAt ?? .distantPast) < ($1.pendingEdit?.editedAt ?? .distantPast) }
    }

    /// Uploads one queued edit. Returns a failure message, or nil on success or a skip.
    ///
    /// The conflict check is the whole point: compare the server's current `updatedAt` against the
    /// version this edit was based on, and treat "server is newer" as a conflict rather than an
    /// upload.
    private func uploadEdit(for doc: OfflineDoc) async -> String? {
        // Re-read: an earlier iteration, or the editor, may have changed this document.
        guard let current = store.document(id: doc.id),
              let edit = current.pendingEdit,
              current.conflict == nil else {
            return nil
        }

        do {
            let item = current.asDocItem
            let serverModifiedAt = try await content.fetchServerModifiedAt(for: item)
            if let serverModifiedAt, serverModifiedAt > edit.baseServerModifiedAt {
                logger.error("drain: conflict on id=\(doc.id, privacy: .public)")
                try store.markConflict(id: doc.id, serverModifiedAt: serverModifiedAt)
                return nil
            }
            let (text, dek) = try store.readPlaintext(id: doc.id)
            let updatedAt = try await content.saveContent(text, for: item, dek: dek)
            try store.clearPendingEdit(id: doc.id, serverModifiedAt: updatedAt)
            logger.debug("drain: uploaded id=\(doc.id, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("drain: id=\(doc.id, privacy: .public) failed: \(error, privacy: .public)")
            try? store.recordFailure(id: doc.id, error: message)
            return message
        }
    }

    /// Replays one queued metadata mutation. Returns a failure message, or nil on success.
    private func replay(_ mutation: PendingMutation) async -> String? {
        guard let drive else {
            // Nothing to replay against — leave it queued rather than dropping the user's intent.
            return nil
        }
        do {
            switch mutation.kind {
            case .delete(let isFolder):
                try await drive.sendTrash(itemID: mutation.itemID, isFolder: isFolder)
            case .move(let isFolder, let target):
                try await drive.sendMove(itemID: mutation.itemID, isFolder: isFolder, targetFolderID: target)
            case .rename(let isFolder, let newName):
                try await drive.sendRename(itemID: mutation.itemID, newName: newName, isFolder: isFolder)
            }
            store.removeMutation(id: mutation.id)
            logger.debug("drain: replayed \(mutation.summary, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            logger.error("drain: mutation \(mutation.summary, privacy: .public) failed: \(error, privacy: .public)")
            store.recordMutationFailure(id: mutation.id, error: message)
            return message
        }
    }
}
