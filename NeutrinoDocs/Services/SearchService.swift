import Foundation
import os.log
import NeutrinoCore

// MARK: - SearchService

/// Phase 5 — Search. Owns the local index, keeps it current, answers queries, and holds the user's
/// saved searches.
///
/// ## Why the index is local
///
/// Drive's search endpoint exists and is used here, but it can only match **file names**: the
/// server's full-text table is filled by a `content-index` endpoint that takes plaintext, and
/// calling it would mean handing the server the decrypted text of every document — giving up the
/// end-to-end encryption the rest of the app is built around. Body text, headings and tags are
/// therefore indexed on the device, from documents it has already decrypted for other reasons.
///
/// ## What ends up in the index
///
/// A document is indexed when it is opened or saved, because its plaintext is already in hand and
/// indexing costs a tokenize pass and no network at all. Everything else is reached by the crawl
/// (``indexEverything()``), which walks the drive and downloads what it has not seen. The crawl is
/// explicit rather than automatic on launch: it downloads and decrypts every document the account
/// can read, which is a real amount of network and battery to spend without being asked.
@MainActor
final class SearchService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var savedSearches: [SavedSearch] = []

    /// Number of documents in the index — what Settings shows and what tells the user whether a
    /// crawl is worth running.
    @Published private(set) var indexedDocumentCount = 0

    /// Non-nil while a crawl is running.
    @Published private(set) var crawlProgress: CrawlProgress?

    @Published var lastError: String?

    // MARK: - CrawlProgress

    struct CrawlProgress: Equatable {
        var indexed: Int
        var total: Int
        /// Documents the crawl could not read — trashed mid-crawl, access revoked, key missing.
        var failed: Int

        var fractionComplete: Double {
            total == 0 ? 1 : min(1, Double(indexed + failed) / Double(total))
        }
    }

    // MARK: - Dependencies

    weak var contentService: DocContentService?
    weak var driveService: DocsDriveService?
    weak var offlineStore: OfflineStore?
    weak var networkMonitor: NetworkMonitor?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "SearchService")

    private let store: SearchIndexStore
    private var index = SearchIndex()

    private var crawlTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// How long the index waits after a change before being written. Indexing happens on every
    /// autosave, and re-encrypting the whole index per keystroke pause would be absurd.
    private static let saveDebounce: Duration = .seconds(5)

    /// Pause between documents during a crawl, so indexing a large drive does not saturate the
    /// connection or keep the radio at full power.
    private static let crawlPause: Duration = .milliseconds(120)

    // MARK: - Init

    /// - Parameter store: injected in tests, which point it at a temp directory. The default is
    ///   built here rather than as a default argument because `SearchIndexStore` is main-actor
    ///   isolated and a default argument is evaluated in the caller's context.
    init(store: SearchIndexStore? = nil) {
        self.store = store ?? SearchIndexStore()
    }

    /// Loads the stored index and saved searches. Called once the user is signed in — before that
    /// there is no key to read them with.
    func start() {
        index = store.load()
        indexedDocumentCount = index.documentCount
        savedSearches = store.loadSavedSearches().sorted { $0.lastUsedAt > $1.lastUsedAt }
        logger.debug("start: \(self.index.documentCount) documents indexed")
    }

    // MARK: - Indexing one document

    /// Indexes a document that is already in hand.
    ///
    /// Called from the editor's load and save paths. Cheap enough to call on every autosave: it is
    /// one walk of a tree already in memory, and the write to disk is debounced.
    func indexDocument(item: DocItem, document: ProseMirrorNode, modifiedAt: Date? = nil) {
        guard FeatureFlags.search else { return }

        let content = DocumentSearchContent.extract(document: document, fileName: item.name)
        let entry = IndexedDocument(
            id: item.id,
            title: content.title,
            preview: content.preview,
            tags: content.tags,
            folderID: item.parentID,
            isShared: item.isShared,
            modifiedAt: modifiedAt ?? item.modifiedAt,
            indexedAt: Date()
        )
        index.index(entry, fields: content.indexedFields)
        index.prepareForQuerying()
        indexedDocumentCount = index.documentCount
        scheduleSave()
    }

    /// Drops a document from the index — deleted, trashed, or no longer shared with this account.
    func removeFromIndex(id: String) {
        guard index.document(id: id) != nil else { return }
        index.remove(documentID: id)
        index.prepareForQuerying()
        indexedDocumentCount = index.documentCount
        scheduleSave()
    }

    /// Whether the index's copy of a document is older than the document itself.
    func isStale(_ item: DocItem) -> Bool {
        guard let entry = index.document(id: item.id) else { return true }
        return entry.indexedAt < item.modifiedAt
    }

    // MARK: - Searching

    /// Local search — Phase 5, "Local Search". Synchronous: the index is in memory, and a query
    /// that has to await cannot update the results as the user types.
    func searchLocally(_ query: String, filters: SearchFilters = .unfiltered) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // With no query but an active filter, this is a browse rather than a search.
        guard !trimmed.isEmpty else {
            return filters.isActive ? index.browse(filters: filters) : []
        }
        return index.search(trimmed, filters: filters)
    }

    /// Global search — Phase 5, "Global Search: Across Drive".
    ///
    /// Local results first, then Drive's name search for documents the index has never read, which
    /// is what makes a document findable before the crawl has reached it. Server hits are marked
    /// so the UI can say they matched a name rather than a body.
    func searchEverywhere(_ query: String, filters: SearchFilters = .unfiltered) async -> [SearchResult] {
        let local = searchLocally(query, filters: filters)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let driveService,
              networkMonitor?.isOnline ?? true else {
            return local
        }

        do {
            let hits = try await driveService.searchServer(
                query: trimmed,
                sharedOnly: filters.ownership == .shared,
                after: filters.modifiedAfter,
                before: filters.modifiedBefore
            )
            let known = Set(local.map(\.documentID))
            let extra = hits
                .filter { !known.contains($0.id) }
                // A server hit carries no tags or folder ancestry, so only the filters it can
                // actually be judged against are applied to it.
                .filter { serverHitPassesFilters($0, filters: filters) }
                .map(Self.result(forServerHit:))

            return local + extra
        } catch {
            // A search that found local results should not fail because the network did.
            logger.error("searchEverywhere: server search failed: \(error, privacy: .public)")
            return local
        }
    }

    /// Server hits have no indexed metadata, so tag and folder filters cannot be evaluated for
    /// them. Rather than guessing, a hit is dropped when a filter it cannot answer is in force.
    private func serverHitPassesFilters(_ item: DocItem, filters: SearchFilters) -> Bool {
        if !filters.tags.isEmpty || filters.folderIDs != nil { return false }
        switch filters.ownership {
        case .any:    return true
        case .mine:   return !item.isShared
        case .shared: return item.isShared
        }
    }

    private static func result(forServerHit item: DocItem) -> SearchResult {
        SearchResult(documentID: item.id,
                     title: item.displayName,
                     preview: "Matched the document's name",
                     matchedFields: [.title],
                     score: 0,
                     modifiedAt: item.modifiedAt,
                     isShared: item.isShared)
    }

    /// Every tag in the index, for the filter picker.
    var allTags: [String] { index.allTags }

    // MARK: - Crawling

    /// Walks the whole drive and indexes anything missing or stale — Phase 5's "Indexed: Content".
    ///
    /// Documents already cached offline are read from the cache rather than downloaded again. The
    /// rest are downloaded and decrypted one at a time, with a pause between, because the point is
    /// to fill the index in the background and not to make the app unusable while it happens.
    func indexEverything() {
        guard FeatureFlags.search, crawlTask == nil else { return }

        crawlTask = Task { [weak self] in
            await self?.crawl()
            self?.crawlTask = nil
        }
    }

    func cancelCrawl() {
        crawlTask?.cancel()
        crawlTask = nil
        crawlProgress = nil
    }

    private func crawl() async {
        guard let driveService else { return }
        lastError = nil

        let documents: [DocItem]
        do {
            documents = try await collectDocuments(using: driveService)
        } catch {
            logger.error("crawl: could not list the drive: \(error, privacy: .public)")
            lastError = error.localizedDescription
            return
        }

        let outstanding = documents.filter(isStale)
        crawlProgress = CrawlProgress(indexed: 0, total: outstanding.count, failed: 0)
        logger.debug("crawl: \(outstanding.count) of \(documents.count) documents need indexing")

        // Anything the index holds that the drive no longer lists has been deleted or unshared.
        let live = Set(documents.map(\.id))
        for staleID in Array(index.documents.keys) where !live.contains(staleID) {
            index.remove(documentID: staleID)
        }

        for item in outstanding {
            if Task.isCancelled { break }
            if await indexByReading(item) {
                crawlProgress?.indexed += 1
            } else {
                crawlProgress?.failed += 1
            }
            try? await Task.sleep(for: Self.crawlPause)
        }

        index.prepareForQuerying()
        indexedDocumentCount = index.documentCount
        flushSave()
        crawlProgress = nil
        logger.debug("crawl: finished with \(self.index.documentCount) documents indexed")
    }

    /// Reads one document — from the offline cache when it is there, from the server otherwise —
    /// and indexes it. Returns false when it could not be read.
    private func indexByReading(_ item: DocItem) async -> Bool {
        if let offlineStore, offlineStore.isAvailableOffline(item.id),
           let cached = try? offlineStore.readPlaintext(id: item.id) {
            indexDocument(item: item, document: cached.body.doc)
            return true
        }
        guard let contentService else { return false }
        do {
            let loaded = try await contentService.loadContent(for: item)
            indexDocument(item: item, document: loaded.body.doc)
            return true
        } catch {
            logger.error("crawl: could not read id=\(item.id, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    /// Every document the account can reach: its own drive, walked folder by folder, plus what has
    /// been shared with it.
    private func collectDocuments(using driveService: DocsDriveService) async throws -> [DocItem] {
        var documents: [DocItem] = []
        var pending: [String?] = [nil]
        var visited = Set<String>()

        while let folderID = pending.popLast() {
            if Task.isCancelled { break }
            let contents = try await driveService.fetchContents(inFolder: folderID)
            documents += contents.files
            // `visited` guards against a parent cycle in bad server data, which would otherwise
            // walk forever.
            for folder in contents.folders where visited.insert(folder.id).inserted {
                pending.append(folder.id)
            }
        }

        documents += (try? await driveService.fetchSharedDocuments()) ?? []
        // A document can be reached twice — shared into a folder that is also listed — and indexing
        // it twice would only cost time.
        var seen = Set<String>()
        return documents.filter { $0.isEditable && seen.insert($0.id).inserted }
    }

    // MARK: - Saved searches

    func addSavedSearch(name: String, query: String, filters: SearchFilters) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let search = SavedSearch(name: trimmed.isEmpty ? query : trimmed,
                                 query: query,
                                 filters: filters)
        savedSearches.insert(search, at: 0)
        persistSavedSearches()
    }

    func deleteSavedSearch(id: UUID) {
        savedSearches.removeAll { $0.id == id }
        persistSavedSearches()
    }

    func rename(savedSearchID: UUID, to name: String) {
        guard let index = savedSearches.firstIndex(where: { $0.id == savedSearchID }) else { return }
        savedSearches[index].name = name
        persistSavedSearches()
    }

    /// Records that a saved search was run, so the list leads with what the user actually uses.
    func markUsed(savedSearchID: UUID) {
        guard let index = savedSearches.firstIndex(where: { $0.id == savedSearchID }) else { return }
        savedSearches[index].lastUsedAt = Date()
        savedSearches.sort { $0.lastUsedAt > $1.lastUsedAt }
        persistSavedSearches()
    }

    private func persistSavedSearches() {
        do {
            try store.save(savedSearches: savedSearches)
        } catch {
            logger.error("persistSavedSearches failed: \(error, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sign-out

    /// Drops the index, its key, and the saved searches. The index holds decrypted text from the
    /// signed-out account's documents, so it cannot outlive the session.
    func signOut() {
        cancelCrawl()
        saveTask?.cancel()
        saveTask = nil
        index.removeAll()
        savedSearches = []
        indexedDocumentCount = 0
        store.destroy()
        logger.debug("signOut: index cleared")
    }

    // MARK: - Persistence

    /// Coalesces index writes: a burst of indexing produces one encrypted write rather than one per
    /// document.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// Writes now, cancelling any pending debounce. Called at the end of a crawl and when the app
    /// leaves the foreground.
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try store.save(index)
        } catch {
            logger.error("save failed: \(error, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
