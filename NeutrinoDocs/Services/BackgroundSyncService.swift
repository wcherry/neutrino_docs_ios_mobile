import Foundation
import BackgroundTasks
import os.log

// MARK: - BackgroundSyncService

/// Phase 1 — Synchronization: "Background upload", "Background download".
///
/// Registers a `BGProcessingTask` that drains the offline queue while the app is not in the
/// foreground, and refreshes the cached copies of documents the user reads offline.
///
/// ## Why processing rather than refresh
///
/// `BGAppRefreshTask` is capped at around 30 seconds, which is not enough to upload a backlog of
/// documents over a slow link. `BGProcessingTask` gets minutes, and can be told it needs network —
/// which this work does, unconditionally.
///
/// ## What iOS actually promises
///
/// Nothing about *when*. The system decides, based on how the user uses the app, battery, and
/// thermal state; on a device that has never been unplugged overnight the task may not run for
/// days. Background sync is therefore an optimization on top of foreground sync, never the thing
/// correctness depends on — every path that matters also drains on launch and on foreground.
@MainActor
final class BackgroundSyncService {

    // MARK: - Identifiers

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist. A mismatch is not a runtime
    /// error — the registration simply never fires — so the two are kept textually identical.
    static let taskIdentifier = "com.neutrino.docs.sync"

    /// Earliest the system may run the task after scheduling. A lower bound, not a schedule.
    static let minimumInterval: TimeInterval = 15 * 60

    // MARK: - Dependencies

    private let syncEngine: SyncEngine
    private let store: OfflineStore
    private let settings: AppSettings

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "BackgroundSyncService")

    private var isRegistered = false

    // MARK: - Init

    init(syncEngine: SyncEngine, store: OfflineStore, settings: AppSettings) {
        self.syncEngine = syncEngine
        self.store = store
        self.settings = settings
    }

    // MARK: - Registration

    /// Registers the task handler. Must be called before the app finishes launching — the system
    /// raises an exception for a registration that arrives later.
    func register() {
        guard FeatureFlags.backgroundSync, !isRegistered else { return }
        isRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            // The scheduler calls back on a background queue; the whole sync stack is main-actor.
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.handle(processingTask)
            }
        }
        logger.debug("registered background task")
    }

    /// Asks the system to run the task again. Called after every foreground sync so there is always
    /// one pending — a submitted request is consumed when it runs, not repeated.
    func schedule() {
        guard FeatureFlags.backgroundSync, settings.autoSyncEnabled else { return }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        // Uploading a handful of encrypted Markdown documents is cheap; demanding external power
        // would mean the queue rarely drains on a phone that is never plugged in overnight.
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("scheduled background sync")
        } catch {
            // Submission fails on the simulator and whenever the app is not permitted to schedule.
            // Neither is worth surfacing: foreground sync still covers correctness.
            logger.debug("background sync not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels any pending request — used when the user turns auto-sync off.
    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        logger.debug("cancelled pending background sync")
    }

    // MARK: - Execution

    /// Runs one background pass: drain the queue (upload), then refresh cached copies (download).
    ///
    /// The next request is scheduled *first*. If the drain overruns and the system kills the task,
    /// the chain must already have its next link, or background sync stops for good after a single
    /// bad run.
    private func handle(_ task: BGProcessingTask) async {
        schedule()

        let work = Task { @MainActor in
            await syncEngine.syncNow()
            await refreshCachedDocuments()
        }

        task.expirationHandler = {
            // Fires on a background queue; the cancel itself is safe from anywhere.
            work.cancel()
        }

        await work.value
        let success = !Task.isCancelled
        logger.debug("background sync finished (success=\(success, privacy: .public))")
        task.setTaskCompleted(success: success)
    }

    /// Background download: re-fetches the cached copy of any document whose local base version is
    /// behind the server's, so an offline reader opens current text.
    ///
    /// Documents with unsynced local work are skipped — replacing the base version under a pending
    /// edit is exactly the situation conflict detection exists to catch, and doing it here would
    /// resolve that conflict silently in the server's favour.
    func refreshCachedDocuments() async {
        guard let content = store.contentService else { return }

        for doc in store.documents where doc.pendingEdit == nil && doc.conflict == nil {
            if Task.isCancelled { return }
            do {
                guard let serverModifiedAt = try await content.fetchServerModifiedAt(for: doc.asDocItem),
                      serverModifiedAt > doc.serverModifiedAt else {
                    continue
                }
                try await store.download(doc.asDocItem, reason: doc.cacheReason)
                logger.debug("background refresh: updated id=\(doc.id, privacy: .public)")
            } catch {
                // One unreachable document must not stop the rest of the pass.
                logger.error("background refresh failed for id=\(doc.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
