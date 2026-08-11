import Foundation
import os.log

// MARK: - DocsDriveError

enum DocsDriveError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    case notFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        case .notFound:               return "That document is no longer available."
        }
    }
}

// MARK: - DocsDriveService

/// Browses and organizes the Markdown documents stored in Neutrino Drive.
///
/// Reuses Drive's existing folder / file / trash APIs — Docs has no backend of its own. Every
/// listing passes `type=doc`, so the server returns only Drive's Markdown MIME type; folders come
/// back unfiltered because a folder may hold documents whatever else is in it.
///
/// There is no whole-drive `type=` listing — `type` always scopes to one folder (or the
/// `/starred`, `/recent`, `/trash`, `/shared-with-me` views, which support it directly). A user's
/// root folder has no id of its own; `currentUserId()` reads it from the access token's `sub`
/// claim, mirroring `GET /api/v1/auth/me`.
///
/// Mutations are optimistic: the local model changes first and is rolled back if the server
/// refuses. While the device is offline they are queued instead (`OfflineStore.enqueue`), which is
/// what Phase 1 means by "Queue: pending deletes, pending moves".
@MainActor
final class DocsDriveService: ObservableObject {

    // MARK: - Published State

    /// The user's own folders and documents (hierarchical). Also backs the move picker.
    @Published private(set) var allItems: [DocItem] = []
    /// `GET /api/v1/drive/recent`, newest first.
    @Published private(set) var recentItems: [DocItem] = []
    /// `GET /api/v1/drive/starred`, most recently starred first.
    @Published private(set) var starredItems: [DocItem] = []
    /// `GET /api/v1/drive/shared-with-me` — documents owned by other people.
    @Published private(set) var sharedItems: [DocItem] = []
    /// `GET /api/v1/drive/trash`.
    @Published private(set) var trashItems: [DocItem] = []

    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    /// Set once at app launch so the service can refresh tokens before requests.
    weak var authService: AuthService?

    /// Metadata-only writes (rename, star) bump the server's `updatedAt` without changing a
    /// document's content, which `SyncEngine` would otherwise read as somebody else having edited
    /// it — see `OfflineStore.rebasePendingEdit`. Also holds the pending-mutation queue.
    weak var offlineStore: OfflineStore?

    /// Supplies the encrypt/decrypt round trip that Duplicate needs, since Drive has no
    /// server-side copy endpoint.
    weak var contentService: DocContentService?

    /// When offline, mutations are queued rather than attempted.
    weak var networkMonitor: NetworkMonitor?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "DocsDriveService")

    private let session: URLSession

    private var baseURL: String { AuthService.baseURL }

    private static let decoder: JSONDecoder = {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                            category: "DocsDriveService")
        return DriveDate.makeDecoder(convertFromSnakeCase: true) { raw in
            logger.error("date decode failed: unexpected value=\(raw, privacy: .public)")
        }
    }()

    private var isOnline: Bool { networkMonitor?.isOnline ?? true }

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    #if DEBUG
    /// Seeds state for unit tests, bypassing the network entirely.
    convenience init(home: [DocItem] = [], recents: [DocItem] = [], starred: [DocItem] = [],
                     shared: [DocItem] = [], trash: [DocItem] = [],
                     session: URLSession = .shared) {
        self.init(session: session)
        self.allItems = home
        self.recentItems = recents
        self.starredItems = starred
        self.sharedItems = shared
        self.trashItems = trash
    }
    #endif

    // MARK: - Queries

    /// The items to show for a section. Only Home is folder-scoped; see
    /// `DocsSection.supportsFolderNavigation`.
    func items(in section: DocsSection, parentID: String? = nil) -> [DocItem] {
        switch section {
        case .home:      return allItems.filter { $0.parentID == parentID }
        case .recent:    return recentItems
        case .favorites: return starredItems
        case .shared:    return sharedItems
        case .trash:     return trashItems
        }
    }

    /// Looks an item up wherever it currently lives. A document reached from Recent, Favorites, or
    /// Shared was never part of a folder listing, so `allItems` alone would not find it.
    func item(id: String) -> DocItem? {
        allItems.first { $0.id == id }
            ?? recentItems.first { $0.id == id }
            ?? starredItems.first { $0.id == id }
            ?? sharedItems.first { $0.id == id }
            ?? trashItems.first { $0.id == id }
    }

    /// The chain of folders from the root down to `folderID`, for the browser's breadcrumb.
    func breadcrumb(to folderID: String?) -> [DocItem] {
        var chain: [DocItem] = []
        var current = folderID
        // Bounded by the number of known items: a parent cycle in bad server data would otherwise
        // spin here forever.
        var guardCount = allItems.count + 1
        while let id = current, guardCount > 0 {
            guardCount -= 1
            guard let folder = allItems.first(where: { $0.id == id }) else { break }
            chain.insert(folder, at: 0)
            current = folder.parentID
        }
        return chain
    }

    // MARK: - Single Item

    /// Fetches one document's metadata straight from the server.
    ///
    /// ``item(id:)`` reads the listings this session happens to have loaded, which is enough while
    /// the user is browsing. A Universal Link is not: it names a document that may sit in a folder
    /// nobody has opened, or one shared by another account, so there is no listing to read it out
    /// of.
    ///
    /// Throws ``DocsDriveError/notFound`` for a file that is not a Neutrino document — the app link
    /// vocabulary is per-app, so an `/open/doc/…` link pointing at a spreadsheet is a malformed
    /// link rather than something to render badly.
    func fetchItem(id: String) async throws -> DocItem {
        let file: APIFileResponse = try await get("/api/v1/drive/files/\(id)/metadata")
        guard NeutrinoAppLink.kind(forMIME: file.mimeType) == .doc else {
            logger.error("fetchItem: \(id, privacy: .public) is \(file.mimeType, privacy: .public), not a document")
            throw DocsDriveError.notFound
        }
        return DocItem(file: file)
    }

    // MARK: - Loading

    /// Loads one section. `parentID` applies to Home only.
    func load(_ section: DocsSection, parentID: String? = nil) async {
        logger.debug("load: \(section.rawValue, privacy: .public) parent=\(parentID ?? "root", privacy: .public)")
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            switch section {
            case .home:
                let response: APIFolderContentsResponse
                if let parentID {
                    response = try await get("/api/v1/drive/folders/\(parentID)?type=doc")
                } else {
                    guard let rootId = currentUserId() else { throw DocsDriveError.notAuthenticated }
                    response = try await get(
                        "/api/v1/drive/folders/\(rootId)?limit=200&offset=0&orderBy=createdAt&direction=desc&type=doc")
                }
                let folders = response.folders.map { DocItem(folder: $0) }
                let files = response.files.map { DocItem(file: $0) }
                // Replace this parent's cached items so a refresh cannot duplicate rows.
                allItems.removeAll { $0.parentID == parentID }
                allItems.append(contentsOf: folders)
                allItems.append(contentsOf: files)

            case .recent:
                // `limit` counts documents, not files of every type, because the server applies
                // `type` before the limit.
                let response: APIFolderContentsResponse = try await get("/api/v1/drive/recent?type=doc&limit=50")
                recentItems = response.files.map { DocItem(file: $0) }

            case .favorites:
                let response: APIFolderContentsResponse = try await get("/api/v1/drive/starred?type=doc")
                let folders = response.folders.map { DocItem(folder: $0) }
                let files = response.files.map { DocItem(file: $0) }
                starredItems = folders + files

            case .shared:
                let response: APISharedWithMeResponse = try await get("/api/v1/drive/shared-with-me?type=doc")
                let folders = response.folders.map { DocItem(sharedFolder: $0) }
                let files = response.files.map { DocItem(sharedFile: $0) }
                sharedItems = folders + files

            case .trash:
                let response: APITrashContentsResponse = try await get("/api/v1/drive/trash?type=doc")
                let folders = response.folders.map { DocItem(trashFolder: $0) }
                let files = response.files.map { DocItem(trashFile: $0) }
                trashItems = folders + files
            }
            logger.debug("load \(section.rawValue, privacy: .public) succeeded")
        } catch {
            logger.error("load \(section.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Create

    func createFolder(name: String, parentID: String?) {
        let placeholder = DocItem(id: UUID().uuidString, name: name, type: .folder,
                                  parentID: parentID, size: nil, modifiedAt: Date(),
                                  isTrashed: false, mimeType: nil)
        allItems.append(placeholder)
        Task {
            do {
                let created: APIFolderResponse = try await post(
                    "/api/v1/drive/folders",
                    body: APICreateFolderRequest(name: name, parentId: parentID)
                )
                // Swap the placeholder for the server-assigned identity.
                if let idx = allItems.firstIndex(where: { $0.id == placeholder.id }) {
                    allItems[idx] = DocItem(folder: created)
                }
                logger.debug("createFolder succeeded: id=\(created.id, privacy: .public)")
            } catch {
                logger.error("createFolder failed: \(error, privacy: .public)")
                allItems.removeAll { $0.id == placeholder.id }
                self.error = error.localizedDescription
            }
        }
    }

    /// Creates an empty document. Needs the network: a new file has no id to queue work against.
    func createDocument(name: String, parentID: String?) async throws -> DocItem {
        guard let contentService else { throw DocsDriveError.notFound }
        let item = try await contentService.createDocument(name: normalizedName(name), parentID: parentID)
        allItems.append(item)
        return item
    }

    /// Duplicates a document.
    ///
    /// Drive has no server-side copy endpoint, so this is a client-side round trip: the source is
    /// downloaded and decrypted, and the copy is uploaded as a brand-new file under a **fresh
    /// DEK**. Reusing the source's key would mean the two files could never have their access
    /// revoked independently.
    @discardableResult
    func duplicate(itemID: String) async throws -> DocItem {
        guard let source = item(id: itemID), source.type == .file else {
            throw DocsDriveError.notFound
        }
        guard let contentService else { throw DocsDriveError.notFound }
        logger.debug("duplicate: id=\(itemID, privacy: .public)")

        // The whole body is copied, layout metadata included — a duplicate that lost the original's
        // page setup would not be a duplicate.
        let (body, _) = try await contentService.loadContent(for: source)
        let copy = try await contentService.createDocument(
            name: source.duplicateName,
            parentID: source.parentID,
            body: body
        )
        allItems.append(copy)
        logger.debug("duplicate succeeded: id=\(copy.id, privacy: .public)")
        return copy
    }

    // MARK: - Rename

    func rename(itemID: String, to newName: String) {
        guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        let previousName = allItems[idx].name
        let previousModifiedAt = allItems[idx].modifiedAt
        let isFolder = allItems[idx].type == .folder
        let finalName = isFolder ? newName : normalizedName(newName)

        allItems[idx].name = finalName
        allItems[idx].modifiedAt = Date()
        applyNameEverywhere(itemID: itemID, name: finalName)

        guard isOnline else {
            offlineStore?.enqueue(PendingMutation(
                itemID: itemID, kind: .rename(isFolder: isFolder, newName: finalName)
            ))
            logger.debug("rename queued offline: id=\(itemID, privacy: .public)")
            return
        }

        Task {
            do {
                let updatedAt = try await sendRename(itemID: itemID, newName: finalName, isFolder: isFolder)
                // A rename bumps `updated_at` without touching content — keep the offline cache's
                // idea of the server version in step so it isn't mistaken for a remote edit.
                offlineStore?.rebasePendingEdit(id: itemID,
                                                previousModifiedAt: previousModifiedAt,
                                                serverModifiedAt: updatedAt)
                logger.debug("rename succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("rename failed: \(error, privacy: .public)")
                applyNameEverywhere(itemID: itemID, name: previousName)
                self.error = error.localizedDescription
            }
        }
    }

    /// Performs the rename request. Used directly by the sync engine when draining the queue.
    @discardableResult
    func sendRename(itemID: String, newName: String, isFolder: Bool) async throws -> Date {
        if isFolder {
            let folder: APIFolderResponse = try await patch(
                "/api/v1/drive/folders/\(itemID)",
                body: APIUpdateFolderRequest(name: newName, isStarred: nil)
            )
            return folder.updatedAt
        }
        let file: APIFileResponse = try await patch(
            "/api/v1/drive/files/\(itemID)",
            body: APIUpdateFileRequest(name: newName, isStarred: nil)
        )
        return file.updatedAt
    }

    // MARK: - Star (Favorites)

    /// Stars or unstars an item — the Favorites model shared with the web app, which stores the
    /// flag on the Drive row itself rather than in a list of its own.
    func setStarred(itemID: String, isStarred: Bool) {
        guard var item = item(id: itemID) else { return }
        let previousModifiedAt = item.modifiedAt
        item.isStarred = isStarred
        applyStarred(item)

        guard isOnline else {
            // Starring is not in Phase 1's queue list ("pending saves, deletes, moves") and has no
            // safe offline semantics — the flag lives on a row the server may have changed — so an
            // offline star is reverted rather than silently dropped or wrongly queued.
            var reverted = item
            reverted.isStarred = !isStarred
            applyStarred(reverted)
            error = "Favorites need a connection."
            return
        }

        Task {
            do {
                let updatedAt: Date
                if item.type == .folder {
                    let folder: APIFolderResponse = try await patch(
                        "/api/v1/drive/folders/\(itemID)",
                        body: APIUpdateFolderRequest(name: nil, isStarred: isStarred)
                    )
                    updatedAt = folder.updatedAt
                } else {
                    let file: APIFileResponse = try await patch(
                        "/api/v1/drive/files/\(itemID)",
                        body: APIUpdateFileRequest(name: nil, isStarred: isStarred)
                    )
                    updatedAt = file.updatedAt
                }
                offlineStore?.rebasePendingEdit(id: itemID,
                                                previousModifiedAt: previousModifiedAt,
                                                serverModifiedAt: updatedAt)
            } catch {
                logger.error("setStarred failed: \(error, privacy: .public)")
                var reverted = item
                reverted.isStarred = !isStarred
                applyStarred(reverted)
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Delete

    /// Moves the item to Trash, or permanently deletes it when it is already there.
    func delete(itemID: String) {
        if let idx = trashItems.firstIndex(where: { $0.id == itemID }) {
            permanentlyDelete(at: idx)
        } else if let idx = allItems.firstIndex(where: { $0.id == itemID }) {
            trash(at: idx)
        }
    }

    private func trash(at index: Int) {
        let item = allItems.remove(at: index)
        var trashed = item
        trashed.isTrashed = true
        trashed.modifiedAt = Date()
        trashItems.append(trashed)
        // Trashed items are excluded from both server-side views; drop them here too rather than
        // leave a Favorites or Recent row that opens a deleted document.
        starredItems.removeAll { $0.id == item.id }
        recentItems.removeAll { $0.id == item.id }

        guard isOnline else {
            offlineStore?.enqueue(PendingMutation(
                itemID: item.id, kind: .delete(isFolder: item.type == .folder)
            ))
            logger.debug("delete queued offline: id=\(item.id, privacy: .public)")
            return
        }

        Task {
            do {
                try await sendTrash(itemID: item.id, isFolder: item.type == .folder)
                logger.debug("delete succeeded: id=\(item.id, privacy: .public)")
            } catch {
                logger.error("delete failed: \(error, privacy: .public)")
                trashItems.removeAll { $0.id == item.id }
                allItems.append(item)
                if item.isStarred { applyStarred(item) }
                self.error = error.localizedDescription
            }
        }
    }

    /// Sends the trash request. Used directly by the sync engine when draining the queue.
    func sendTrash(itemID: String, isFolder: Bool) async throws {
        let body = isFolder
            ? APIBulkTrashRequest(fileIds: [], folderIds: [itemID])
            : APIBulkTrashRequest(fileIds: [itemID], folderIds: [])
        let _: APIBulkResult = try await post("/api/v1/drive/bulk/trash", body: body)
    }

    private func permanentlyDelete(at index: Int) {
        let item = trashItems.remove(at: index)
        Task {
            do {
                let path = item.type == .folder
                    ? "/api/v1/drive/trash/folders/\(item.id)"
                    : "/api/v1/drive/trash/files/\(item.id)"
                try await deleteVoid(path)
                logger.debug("permanent delete succeeded: id=\(item.id, privacy: .public)")
            } catch {
                logger.error("permanent delete failed: \(error, privacy: .public)")
                trashItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Move

    func move(itemID: String, to newParentID: String?) {
        guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
        // Moving a folder into its own subtree would detach it from the drive entirely.
        guard !isDescendant(potentialChildID: newParentID, ofFolderID: itemID) else { return }

        let previousParent = allItems[idx].parentID
        allItems[idx].parentID = newParentID
        let item = allItems[idx]

        guard isOnline else {
            offlineStore?.enqueue(PendingMutation(
                itemID: itemID,
                kind: .move(isFolder: item.type == .folder, targetFolderID: newParentID)
            ))
            offlineStore?.updateParent(id: itemID, parentID: newParentID)
            logger.debug("move queued offline: id=\(itemID, privacy: .public)")
            return
        }

        Task {
            do {
                try await sendMove(itemID: itemID, isFolder: item.type == .folder, targetFolderID: newParentID)
                offlineStore?.updateParent(id: itemID, parentID: newParentID)
                logger.debug("move succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("move failed: \(error, privacy: .public)")
                if let i = allItems.firstIndex(where: { $0.id == itemID }) {
                    allItems[i].parentID = previousParent
                }
                self.error = error.localizedDescription
            }
        }
    }

    /// Sends the move request. Used directly by the sync engine when draining the queue.
    func sendMove(itemID: String, isFolder: Bool, targetFolderID: String?) async throws {
        let body = isFolder
            ? APIBulkMoveRequest(fileIds: [], folderIds: [itemID], targetFolderId: targetFolderID)
            : APIBulkMoveRequest(fileIds: [itemID], folderIds: [], targetFolderId: targetFolderID)
        let _: APIBulkResult = try await post("/api/v1/drive/bulk/move", body: body)
    }

    // MARK: - Restore / Empty trash

    func restore(itemID: String) {
        guard let idx = trashItems.firstIndex(where: { $0.id == itemID }) else { return }
        var item = trashItems.remove(at: idx)
        item.isTrashed = false
        allItems.append(item)
        if item.isStarred { applyStarred(item) }

        Task {
            do {
                let path = item.type == .folder
                    ? "/api/v1/drive/trash/folders/\(itemID)/restore"
                    : "/api/v1/drive/trash/files/\(itemID)/restore"
                try await postVoid(path)
                logger.debug("restore succeeded: id=\(itemID, privacy: .public)")
            } catch {
                logger.error("restore failed: \(error, privacy: .public)")
                allItems.removeAll { $0.id == itemID }
                starredItems.removeAll { $0.id == itemID }
                trashItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        let snapshot = trashItems
        trashItems = []
        Task {
            do {
                let _: APIBulkResult = try await deleteRequest("/api/v1/drive/trash")
                logger.debug("emptyTrash succeeded")
            } catch {
                logger.error("emptyTrash failed: \(error, privacy: .public)")
                trashItems = snapshot
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Editor callbacks

    /// Called after a successful save so the browser's size and date stay in step without a refetch.
    func documentWasSaved(itemID: String, size: Int64, modifiedAt: Date) {
        for collection in [\DocsDriveService.allItems, \DocsDriveService.recentItems,
                           \DocsDriveService.starredItems, \DocsDriveService.sharedItems] {
            for idx in self[keyPath: collection].indices where self[keyPath: collection][idx].id == itemID {
                self[keyPath: collection][idx].size = size
                self[keyPath: collection][idx].modifiedAt = modifiedAt
            }
        }
    }

    // MARK: - Search support

    /// Fetches one folder's contents without touching the browser's published state.
    ///
    /// Phase 5's index crawl walks the whole drive, and doing that through `load(_:parentID:)` would
    /// repoint the Home listing at whatever folder the crawl happened to be visiting.
    func fetchContents(inFolder folderID: String?) async throws -> (folders: [DocItem], files: [DocItem]) {
        let response: APIFolderContentsResponse
        if let folderID {
            response = try await get("/api/v1/drive/folders/\(folderID)?type=doc")
        } else {
            guard let rootId = currentUserId() else { throw DocsDriveError.notAuthenticated }
            response = try await get(
                "/api/v1/drive/folders/\(rootId)?limit=200&offset=0&orderBy=createdAt&direction=desc&type=doc")
        }
        return (response.folders.map { DocItem(folder: $0) }, response.files.map { DocItem(file: $0) })
    }

    /// Documents shared with this account, fetched without disturbing the Shared tab.
    func fetchSharedDocuments() async throws -> [DocItem] {
        let response: APISharedWithMeResponse = try await get("/api/v1/drive/shared-with-me?type=doc")
        return response.files.map { DocItem(sharedFile: $0) }
    }

    /// Drive's own search — Phase 5, "Global Search: Across Drive".
    ///
    /// This reaches documents the local index has never read, but it can only match **names**. The
    /// server's full-text table is populated from a `content-index` endpoint that takes plaintext,
    /// and this app does not call it: uploading decrypted document text so the server can search it
    /// would give up the end-to-end encryption the rest of the app is built around. Body text is
    /// searched locally instead, against the index.
    func searchServer(query: String,
                      sharedOnly: Bool = false,
                      after: Date? = nil,
                      before: Date? = nil,
                      limit: Int = 50) async throws -> [DocItem] {
        var components = URLComponents(string: "/api/v1/drive/search")
        var queryItems = [URLQueryItem(name: "q", value: query),
                          URLQueryItem(name: "fileType", value: "doc"),
                          URLQueryItem(name: "limit", value: String(limit))]
        if sharedOnly { queryItems.append(URLQueryItem(name: "sharedOnly", value: "true")) }
        if let after { queryItems.append(URLQueryItem(name: "after", value: Self.iso8601.string(from: after))) }
        if let before { queryItems.append(URLQueryItem(name: "before", value: Self.iso8601.string(from: before))) }
        components?.queryItems = queryItems

        guard let path = components?.string else { return [] }
        let response: APISearchResponse = try await get(path)
        return response.items
            .filter { $0.mimeType == DocItem.markdownMIME }
            .map { hit in
                // The endpoint answers across owned and shared documents together and its DTO
                // carries the owner's id, not the caller's, so ownership is decided from what is
                // already known locally. A `sharedOnly` search settles it outright.
                let isShared = sharedOnly || item(id: hit.id)?.isShared == true
                return DocItem(searchResult: hit, isShared: isShared)
            }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Ancestry

    /// Whether `potentialChildID` is `folderID` itself or sits somewhere beneath it.
    func isDescendant(potentialChildID: String?, ofFolderID folderID: String) -> Bool {
        var current = potentialChildID
        var guardCount = allItems.count + 1
        while let id = current, guardCount > 0 {
            guardCount -= 1
            if id == folderID { return true }
            current = allItems.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    // MARK: - Local model helpers

    /// Writes a star flag through every collection holding the item, and adds it to (or drops it
    /// from) Favorites so that list stays correct without a refetch.
    private func applyStarred(_ item: DocItem) {
        for idx in allItems.indices where allItems[idx].id == item.id {
            allItems[idx].isStarred = item.isStarred
        }
        for idx in recentItems.indices where recentItems[idx].id == item.id {
            recentItems[idx].isStarred = item.isStarred
        }
        if item.isStarred {
            if let idx = starredItems.firstIndex(where: { $0.id == item.id }) {
                starredItems[idx] = item
            } else {
                // Most recently starred first, matching the server's `starred_at DESC` ordering.
                starredItems.insert(item, at: 0)
            }
        } else {
            starredItems.removeAll { $0.id == item.id }
        }
    }

    private func applyNameEverywhere(itemID: String, name: String) {
        for collection in [\DocsDriveService.allItems, \DocsDriveService.recentItems,
                           \DocsDriveService.starredItems, \DocsDriveService.trashItems] {
            for idx in self[keyPath: collection].indices where self[keyPath: collection][idx].id == itemID {
                self[keyPath: collection][idx].name = name
            }
        }
        offlineStore?.updateName(id: itemID, name: name)
    }

    /// The signed-in user's id, read from the access token's `sub` claim rather than an extra
    /// round trip to `/api/v1/auth/me` — a user's root folder id *is* their user id (see
    /// `GET /api/v1/drive/folders/{id}`), so this is enough to address the drive root. Not a
    /// verification of the token — the server still does that on every request.
    private func currentUserId() -> String? {
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: data) else { return nil }
        return claims.sub
    }

    /// Documents are stored with a `.md` extension so the web app and Drive both recognise them.
    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let lowercased = base.lowercased()
        if lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown") { return base }
        return base + ".md"
    }

    // MARK: - HTTP

    private func makeRequest(method: String, path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw DocsDriveError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try makeRequest(method: "GET", path: path))
    }

    @discardableResult
    private func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        try await perform(try makeRequest(method: "POST", path: path, body: body))
    }

    private func postVoid(_ path: String) async throws {
        try await performVoid(try makeRequest(method: "POST", path: path))
    }

    @discardableResult
    private func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await perform(try makeRequest(method: "PATCH", path: path, body: body))
    }

    @discardableResult
    private func deleteRequest<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try makeRequest(method: "DELETE", path: path))
    }

    private func deleteVoid(_ path: String) async throws {
        try await performVoid(try makeRequest(method: "DELETE", path: path))
    }

    /// Refreshes the token, injects it, executes the request, and decodes the response.
    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, http) = try await execute(req)
        guard (200...299).contains(http.statusCode) else {
            throw DocsDriveError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw DocsDriveError.decodingError(underlying: error)
        }
    }

    /// Same as ``perform(_:)`` but for endpoints that return no body.
    private func performVoid(_ req: URLRequest) async throws {
        let (_, http) = try await execute(req)
        guard (200...299).contains(http.statusCode) else {
            throw DocsDriveError.serverError(statusCode: http.statusCode)
        }
    }

    private func execute(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw DocsDriveError.notAuthenticated
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("--> \(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw DocsDriveError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DocsDriveError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(req.url?.path ?? "?", privacy: .public)")
        return (data, http)
    }
}

// MARK: - DocItem convenience initialisers

private extension DocItem {
    init(folder: APIFolderResponse) {
        self.init(id: folder.id, name: folder.name, type: .folder, parentID: folder.parentId,
                  size: nil, modifiedAt: folder.updatedAt, isTrashed: false, mimeType: nil,
                  isStarred: folder.isStarred)
    }

    init(file: APIFileResponse) {
        self.init(id: file.id, name: file.name, type: .file, parentID: file.folderId,
                  size: file.sizeBytes, modifiedAt: file.updatedAt, isTrashed: false,
                  mimeType: file.mimeType, isStarred: file.isStarred)
    }

    /// A folder somebody else owns. `parentID` is deliberately dropped: it names a folder in the
    /// owner's drive, which this account cannot list, and keeping it would make the item look like
    /// a child of a folder that isn't there.
    ///
    /// The star flag is dropped too. `is_starred` is a single column on the row, so it is the
    /// *owner's* star; showing it would put a Favorites badge on somebody else's document that this
    /// account never set and cannot clear.
    init(sharedFolder: APIFolderResponse) {
        self.init(id: sharedFolder.id, name: sharedFolder.name, type: .folder, parentID: nil,
                  size: nil, modifiedAt: sharedFolder.updatedAt, isTrashed: false, mimeType: nil,
                  isStarred: false, isShared: true)
    }

    /// A document somebody else owns. `parentID` is kept — it is the owner's folder id, which this
    /// account cannot list but which `/files/{id}/info` and the content endpoints do not need.
    init(sharedFile: APIFileResponse) {
        self.init(id: sharedFile.id, name: sharedFile.name, type: .file, parentID: sharedFile.folderId,
                  size: sharedFile.sizeBytes, modifiedAt: sharedFile.updatedAt, isTrashed: false,
                  mimeType: sharedFile.mimeType, isStarred: false, isShared: true)
    }

    /// A search hit. The endpoint answers across everything the account can reach, so `userId` is
    /// what says whether the document is the caller's own or one shared with them; the caller's id
    /// is supplied by `DocsDriveService` since the DTO does not carry it.
    init(searchResult: APISearchItem, isShared: Bool) {
        self.init(id: searchResult.id, name: searchResult.name, type: .file, parentID: nil,
                  size: searchResult.sizeBytes, modifiedAt: searchResult.updatedAt,
                  isTrashed: false, mimeType: searchResult.mimeType, isStarred: false,
                  isShared: isShared)
    }

    init(trashFolder: APITrashFolderItem) {
        self.init(id: trashFolder.id, name: trashFolder.name, type: .folder, parentID: nil,
                  size: nil, modifiedAt: trashFolder.deletedAt, isTrashed: true, mimeType: nil)
    }

    init(trashFile: APITrashFileItem) {
        self.init(id: trashFile.id, name: trashFile.name, type: .file, parentID: nil,
                  size: trashFile.sizeBytes, modifiedAt: trashFile.deletedAt, isTrashed: true,
                  mimeType: trashFile.mimeType)
    }
}

// MARK: - API Models

private struct APIFolderContentsResponse: Decodable {
    let files: [APIFileResponse]
    let folders: [APIFolderResponse]
}

/// The subset of a JWT's claims `currentUserId()` needs.
private struct JWTClaims: Decodable {
    let sub: String
}

/// `GET /api/v1/drive/shared-with-me` — the same shapes as a folder listing, but flat and owned by
/// other people.
private struct APISharedWithMeResponse: Decodable {
    let files: [APIFileResponse]
    let folders: [APIFolderResponse]
}

private struct APIFolderResponse: Decodable {
    let id: String
    let name: String
    let parentId: String?
    let updatedAt: Date
    let isStarred: Bool    /// Drive's optimistic-concurrency counter. Optional so a server that predates the field
    /// still decodes; a nil version just means the next save goes unguarded.
    let contentVersion: Int?
}

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
    let isStarred: Bool
}

/// `GET /api/v1/drive/search`. `snippet` is ignored — it is only ever populated from the
/// server-side content index, which this app deliberately never writes to.
private struct APISearchResponse: Decodable {
    let items: [APISearchItem]
    let total: Int
}

private struct APISearchItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let updatedAt: Date
    let userId: String
}

private struct APITrashContentsResponse: Decodable {
    let files: [APITrashFileItem]
    let folders: [APITrashFolderItem]
}

private struct APITrashFileItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let deletedAt: Date
}

private struct APITrashFolderItem: Decodable {
    let id: String
    let name: String
    let deletedAt: Date
}

private struct APICreateFolderRequest: Encodable {
    let name: String
    let parentId: String?
}

private struct APIUpdateFolderRequest: Encodable {
    let name: String?
    let isStarred: Bool?
}

private struct APIUpdateFileRequest: Encodable {
    let name: String?
    let isStarred: Bool?
}

private struct APIBulkTrashRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
}

private struct APIBulkMoveRequest: Encodable {
    let fileIds: [String]
    let folderIds: [String]
    let targetFolderId: String?
}

private struct APIBulkResult: Decodable {
    let affected: Int
}
