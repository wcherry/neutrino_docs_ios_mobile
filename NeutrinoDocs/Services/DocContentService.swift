import Foundation
import Sodium
import os.log

// MARK: - DocContentError

enum DocContentError: LocalizedError {
    case noEncryptionKey
    case encryptionFailed
    case decryptionFailed
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    /// The server refused the write because the document moved on since this device read it.
    /// `current` is the version the server holds now, when it could be recovered from the response.
    case contentVersionConflict(current: Int?)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:        return "No encryption key found. Import your key before opening or creating documents."
        case .encryptionFailed:       return "Failed to encrypt the document."
        case .decryptionFailed:       return "Failed to decrypt the document."
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        case .contentVersionConflict:
            return "This document changed on another device since it was opened. Reload to get the latest version, or keep your copy."
        }
    }
}

// MARK: - DocContentService

/// Encrypts, uploads, downloads, and decrypts the body of a document.
///
/// Mirrors the E2EE protocol used by Neutrino Drive's upload / download / autosave endpoints
/// exactly — XChaCha20-Poly1305 secretstream for the content, `crypto_box_seal` for the per-file
/// key — so a document created here is readable by the web app and vice versa. `DocsDriveService`
/// handles metadata (name, folder, trash); this service handles the encrypted body.
///
/// ## The body is a document tree
///
/// What a Neutrino Doc stores is the web editor's ProseMirror JSON, which is why every method here
/// that deals in whole documents speaks `DocumentBody` rather than `String`: the editor holds that
/// same tree, and `NeutrinoDocumentCodec` enters and leaves the stored envelope at exactly two
/// points — just after decrypting and just before encrypting. The lower-level
/// ``encrypt(text:dek:xcss:)`` and
/// ``decrypt(data:dek:)`` stay untranslated, because the offline cache and version history need to
/// move stored bytes around without reinterpreting them.
///
/// ## What is never logged
///
/// No method here logs a DEK, a sealed DEK, plaintext, or a ciphertext fingerprint. Document IDs
/// and byte counts are the most this will say about a document, because `os.log` messages persist
/// in the system log store and a key written there outlives the process that leaked it.
@MainActor
final class DocContentService: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch so the service can refresh tokens before requests.
    weak var authService: AuthService?

    // MARK: - Private

    private static let sodium = Sodium()

    /// The secretstream header is 24 bytes and prefixes every ciphertext this app writes.
    private static let secretStreamHeaderSize = 24

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "DocContentService")

    private let session: URLSession

    private var baseURL: String { AuthService.baseURL }

    private static let decoder: JSONDecoder = DriveDate.makeDecoder(convertFromSnakeCase: true)

    // MARK: - Init

    /// - Parameter session: injected in tests as a `MockURLProtocol`-backed session.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Create

    /// Creates a new, empty document in Drive and returns the resulting item.
    func createDocument(name: String, parentID: String?) async throws -> DocItem {
        try await create(name: name, parentID: parentID).item
    }

    /// Creates a document that already has content — used by Duplicate, and by any caller that has
    /// a body in hand.
    ///
    /// A fresh DEK is generated: a copy is a new file, and sharing a key between two files would
    /// mean revoking access to one revoked access to both.
    func createDocument(name: String, parentID: String?, body: DocumentBody) async throws -> DocItem {
        let (item, dek) = try await create(name: name, parentID: parentID)
        guard !body.blocks.isEmpty else { return item }
        // The DEK is carried over from `create` rather than re-fetched: the key was generated on
        // this device moments ago, and going back to `/files/{id}/key` for it would be a round trip
        // to be told something we already know.
        let saved = try await saveContent(body, for: item, dek: dek,
                                          expectedContentVersion: item.contentVersion)
        var populated = item
        populated.modifiedAt = saved.updatedAt
        populated.contentVersion = saved.contentVersion
        populated.size = Int64(NeutrinoDocumentCodec.encode(body).utf8.count)
        return populated
    }

    /// The shared create path. Returns the DEK alongside the item so a caller that immediately
    /// writes content does not have to fetch and unseal a key it just generated.
    private func create(name: String, parentID: String?) async throws -> (item: DocItem, dek: Bytes) {
        logger.debug("createDocument: parentID=\(parentID ?? "root", privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let dek: Bytes = xcss.key()
        // An empty document is still a ProseMirror document — the same one the backend seeds a file
        // with — so a file this app creates opens in the web editor without a repair pass.
        let encryptedContent = try encrypt(text: NeutrinoDocumentCodec.encode(.empty),
                                           dek: dek, xcss: xcss)
        let encryptedMetadata = try encryptMetadata(name: name, mimeType: DocItem.documentMIME,
                                                    dek: dek, xcss: xcss)
        let sealedFileKey = try sealDEK(dek)

        let form = buildUploadBody(
            encryptedData: encryptedContent, fileName: name, mimeType: DocItem.documentMIME,
            parentFolderID: parentID, encryptedMetadata: encryptedMetadata
        )

        var request = try makeRequest(method: "POST", path: "/api/v1/drive/files/upload", token: token)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response)

        let created: APIFileResponse
        do {
            created = try Self.decoder.decode(APIFileResponse.self, from: data)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }

        // The key is stored in a second call: the upload endpoint takes the ciphertext, not the
        // sealed DEK. A document whose key ref failed to store is unreadable, so this is allowed
        // to throw rather than being fire-and-forget.
        try await storeFileKey(fileID: created.id, encryptedFileKey: sealedFileKey, token: token)
        logger.debug("createDocument succeeded: id=\(created.id, privacy: .public)")

        var item = DocItem(
            id: created.id, name: created.name, type: .file, parentID: created.folderId,
            size: created.sizeBytes, modifiedAt: created.updatedAt, isTrashed: false,
            mimeType: created.mimeType
        )
        item.contentVersion = created.contentVersion
        return (item, dek)
    }

    // MARK: - Load

    /// Downloads and decrypts a document's content.
    ///
    /// Returns the body together with the DEK, which the caller should hold for the editing session
    /// so subsequent autosaves need neither a re-fetch nor a re-unseal. The body's `layout` must be
    /// held for the same reason: it is the only copy of the document's web-only page setup, and
    /// saving without it would reset that setup server-side.
    func loadContent(for item: DocItem) async throws -> (body: DocumentBody, dek: Bytes) {
        logger.debug("loadContent: id=\(item.id, privacy: .public)")
        let token = try await authorizedToken()

        let sealedFileKey = try await fetchSealedDEK(fileID: item.id, token: token)
        let dek = try unsealDEK(sealedFileKey)
        let encryptedData = try await fetchEncryptedContent(fileID: item.id, token: token)
        let stored = try decrypt(data: encryptedData, dek: dek)
        let body = NeutrinoDocumentCodec.decode(stored)

        logger.debug("loadContent succeeded: id=\(item.id, privacy: .public) (\(stored.utf8.count) stored bytes)")
        return (body, dek)
    }

    // MARK: - Save

    /// The outcome of a successful save: the server's own view of the document afterwards.
    struct SaveResult {
        let updatedAt: Date
        /// The version the document is now at. Hold it and send it back on the next save.
        let contentVersion: Int?
    }

    /// Encrypts `body` with the document's existing DEK and PUTs it to the autosave endpoint.
    /// Returns the server's new `updatedAt` and `contentVersion` so the caller can reflect both
    /// without a second request.
    ///
    /// `expectedContentVersion` is the version this edit was written against. Passing it makes the
    /// server reject the write outright — as `DocContentError.contentVersionConflict` — if anything
    /// landed in between, which is the only way to close the gap between checking and writing.
    /// Passing nil saves unconditionally, which is right for a document this device just created
    /// and for any server that does not report versions.
    ///
    /// Note that autosave deliberately does *not* snapshot a version server-side; only the initial
    /// upload and an explicit save do (see `VersionHistoryService`).
    @discardableResult
    func saveContent(_ body: DocumentBody, for item: DocItem, dek: Bytes,
                     expectedContentVersion: Int? = nil) async throws -> SaveResult {
        logger.debug("saveContent: id=\(item.id, privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let encryptedContent = try encrypt(text: NeutrinoDocumentCodec.encode(body),
                                           dek: dek, xcss: xcss)

        // The autosave endpoint expects the same multipart "file" part as create — sending raw
        // bytes as application/octet-stream trips actix-multipart's ContentTypeIncompatible check.
        // No encrypted_metadata or folder_id here; those only apply on create.
        let form = buildUploadBody(
            encryptedData: encryptedContent, fileName: item.name,
            mimeType: item.mimeType ?? DocItem.documentMIME,
            parentFolderID: nil, encryptedMetadata: nil
        )

        var path = "/api/v1/drive/files/\(item.id)/autosave"
        if let expectedContentVersion {
            path += "?expectedContentVersion=\(expectedContentVersion)"
        }
        var request = try makeRequest(method: "PUT", path: path, token: token)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response, data: data)
        do {
            let updated = try Self.decoder.decode(APIFileResponse.self, from: data)
            logger.debug("saveContent succeeded: id=\(item.id, privacy: .public)")
            return SaveResult(updatedAt: updated.updatedAt, contentVersion: updated.contentVersion)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Offline support

    /// Downloads a document's still-encrypted body together with its sealed DEK, without
    /// decrypting. Used by `OfflineStore` so the cache-at-rest blob is byte-identical to the
    /// server's.
    func downloadEncrypted(for item: DocItem) async throws -> (ciphertext: Data, sealedDEK: String) {
        let token = try await authorizedToken()
        let sealedDEK = try await fetchSealedDEK(fileID: item.id, token: token)
        let ciphertext = try await fetchEncryptedContent(fileID: item.id, token: token)
        logger.debug("downloadEncrypted: id=\(item.id, privacy: .public) (\(ciphertext.count) encrypted bytes)")
        return (ciphertext, sealedDEK)
    }

    /// The server's current `updatedAt` for a document, used for conflict detection.
    ///
    /// Returns nil when the document is no longer reachable server-side — deleted, trashed, or
    /// access revoked — which `SyncEngine` reads as "nothing to compare against".
    func fetchServerModifiedAt(for item: DocItem) async throws -> Date? {
        let info = try await fileInfo(for: item.id)
        // A trashed file still has metadata but is no longer somewhere an edit can land.
        guard let info, info.isLive else { return nil }
        return info.updatedAt
    }

    // MARK: - File info

    /// Metadata for one document, including the caller's role on it.
    ///
    /// This is the only Drive endpoint that answers for a file the caller can *access* rather than
    /// one they own, which is what makes shared documents work. Returns nil when the file is gone
    /// (404) or not shared with this account (403) — both mean "not mine to read" rather than an
    /// error worth surfacing.
    func fileInfo(for fileID: String) async throws -> DocFileInfo? {
        let token = try await authorizedToken()
        let request = try makeRequest(method: "GET",
                                      path: "/api/v1/drive/files/\(fileID)/info",
                                      token: token)

        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 403 {
            logger.debug("fileInfo: id=\(fileID, privacy: .public) unavailable (\(http.statusCode))")
            return nil
        }
        try Self.checkStatus(response)
        do {
            return try DocFileInfo.decoder.decode(DocFileInfo.self, from: data)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Crypto (internal, for unit testing)

    /// Encrypts `text` as `[24-byte header][ciphertext]` using an XChaCha20-Poly1305 secretstream.
    func encrypt(text: String, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> Data {
        try encrypt(bytes: Array(text.utf8), dek: dek, xcss: xcss)
    }

    /// The same, starting from bytes.
    ///
    /// Documents are text and pictures are not; both are sealed by the same secret stream, so only
    /// the first step differs — the mirror of ``decrypt(data:dek:)`` and ``decryptToBytes(data:dek:)``.
    func encrypt(bytes: Bytes, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> Data {
        guard let stream = xcss.initPush(secretKey: dek) else { throw DocContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: bytes, tag: .FINAL) else {
            throw DocContentError.encryptionFailed
        }
        return Data(header + cipher)
    }

    /// Reverses ``encrypt(text:dek:xcss:)``.
    func decrypt(data: Data, dek: Bytes) throws -> String {
        guard let text = String(bytes: try decryptToBytes(data: data, dek: dek), encoding: .utf8) else {
            logger.error("decrypt: plaintext is not valid UTF-8")
            throw DocContentError.decryptionFailed
        }
        return text
    }

    /// The same, stopping at the bytes.
    ///
    /// Documents are text and images are not; both are sealed by the same secret stream, so only
    /// the last step differs.
    func decryptToBytes(data: Data, dek: Bytes) throws -> Bytes {
        guard data.count > Self.secretStreamHeaderSize else {
            logger.error("decrypt: data too short (\(data.count) bytes)")
            throw DocContentError.decryptionFailed
        }
        let header = Array(data.prefix(Self.secretStreamHeaderSize))
        let ciphertext = Array(data.dropFirst(Self.secretStreamHeaderSize))
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        guard let pull = xcss.initPull(secretKey: dek, header: header) else {
            logger.error("decrypt: initPull failed — wrong key length or corrupt header")
            throw DocContentError.decryptionFailed
        }
        guard let (plaintext, _) = pull.pull(cipherText: ciphertext) else {
            logger.error("decrypt: authentication failed — wrong DEK or corrupted content")
            throw DocContentError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Attachments

    /// The folder inserted pictures are uploaded into.
    ///
    /// The backend creates it at registration (`ATTACHMENTS_FOLDER_NAME` in `src/auth/api.rs`) and
    /// both clients get-or-create it for accounts that predate that. The web app's
    /// `ATTACHMENTS_FOLDER_NAME` is the same string, and all three have to stay in step: a document
    /// written on one client would otherwise put its pictures somewhere the others never look.
    static let attachmentsFolderName = "Attachments"

    /// The resolved — or in-flight — Attachments lookup.
    ///
    /// Memoised so inserting ten pictures lists the Drive root once rather than ten times. A
    /// failure is deliberately never kept: an upload that failed because the device was offline has
    /// to be able to succeed on the next try.
    private var attachmentsFolder: Task<String, Error>?

    /// The Attachments folder's id, creating the folder if this account has none.
    func attachmentsFolderID() async throws -> String {
        let lookup: Task<String, Error>
        if let attachmentsFolder {
            lookup = attachmentsFolder
        } else {
            lookup = Task { try await self.findOrCreateAttachmentsFolder() }
            attachmentsFolder = lookup
        }

        do {
            return try await lookup.value
        } catch {
            attachmentsFolder = nil
            throw error
        }
    }

    private func findOrCreateAttachmentsFolder() async throws -> String {
        // The Drive root has no folder row of its own; it is addressed by the user's own id.
        guard let rootID = AccessToken.currentUserID() else { throw DocContentError.notAuthenticated }
        let token = try await authorizedToken()

        let request = try makeRequest(method: "GET",
                                      path: "/api/v1/drive/folders/\(rootID)",
                                      token: token)
        let (data, response) = try await data(for: request)
        try Self.checkStatus(response)

        let contents: APIFolderContents
        do {
            contents = try Self.decoder.decode(APIFolderContents.self, from: data)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }

        if let existing = contents.folders.first(where: {
            $0.name.caseInsensitiveCompare(Self.attachmentsFolderName) == .orderedSame
        }) {
            logger.debug("attachmentsFolder: found \(existing.id, privacy: .public)")
            return existing.id
        }

        let created = try await createAttachmentsFolder(token: token)
        logger.debug("attachmentsFolder: created \(created, privacy: .public)")
        return created
    }

    private func createAttachmentsFolder(token: String) async throws -> String {
        var request = try makeRequest(method: "POST", path: "/api/v1/drive/folders", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No parent: a folder created with none lands in the caller's root, which is where both the
        // backend's registration hook and the web app put it.
        request.httpBody = try JSONEncoder().encode(["name": Self.attachmentsFolderName])

        let (data, response) = try await data(for: request)
        try Self.checkStatus(response)
        do {
            return try Self.decoder.decode(APIFolderResponse.self, from: data).id
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    /// Uploads a picture into Attachments and returns the Drive file id a document should reference.
    ///
    /// Encrypted with a fresh DEK of its own, like any other file this app creates — a picture is a
    /// Drive file and is protected as one, rather than inheriting the key of the document that
    /// happens to show it. That also means a picture can be shown by two documents without either
    /// one's key granting access to the other.
    ///
    /// A small preview goes up with it — see ``EditorImage/thumbnailBase64(from:)``. It is generated
    /// here rather than being asked for, because a caller that forgets one produces a file that
    /// looks fine in this app and appears as a blank icon everywhere a Drive listing is shown.
    ///
    /// - Parameter onProgress: fraction of the bytes sent, from 0 to 1, reported on the main actor
    ///   as the transfer runs. Pictures are stored at their original resolution, so this is several
    ///   megabytes over whatever connection the phone has and is not something to spin blankly
    ///   through. Only the body transfer is measured; the key ref that follows it is one small
    ///   request, so progress reaching 1 means "sent", not quite "done".
    ///
    /// Cancelling the surrounding `Task` cancels the transfer: `URLSession`'s async methods
    /// propagate cancellation to the underlying task, and a partially uploaded file is one the
    /// server never records, since the record is created by the request that carries the bytes.
    func uploadAttachment(_ imageData: Data, name: String, mimeType: String,
                          onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        let folderID = try await attachmentsFolderID()
        let token = try await authorizedToken()
        logger.debug("uploadAttachment: \(imageData.count) bytes into \(folderID, privacy: .public)")

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let dek: Bytes = xcss.key()
        let encryptedContent = try encrypt(bytes: Array(imageData), dek: dek, xcss: xcss)
        let encryptedMetadata = try encryptMetadata(name: name, mimeType: mimeType,
                                                    dek: dek, xcss: xcss)
        let sealedFileKey = try sealDEK(dek)

        // Made here because it cannot be made anywhere else: the server is sent ciphertext and has
        // no key, so a picture uploaded without a preview has none in the Drive grid or in either
        // client's image picker. Derived from the same bytes that are being stored, so the preview
        // and the picture cannot disagree.
        let thumbnail = EditorImage.thumbnailBase64(from: imageData)
        if thumbnail == nil {
            logger.debug("uploadAttachment: no preview could be made for \(name, privacy: .public)")
        }

        let form = buildUploadBody(encryptedData: encryptedContent, fileName: name,
                                   mimeType: mimeType, parentFolderID: folderID,
                                   encryptedMetadata: encryptedMetadata,
                                   thumbnailBase64: thumbnail)

        var request = try makeRequest(method: "POST", path: "/api/v1/drive/files/upload", token: token)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(request, body: form.finalized(),
                                                onProgress: onProgress)
        try Self.checkStatus(response)

        let created: APIFileResponse
        do {
            created = try Self.decoder.decode(APIFileResponse.self, from: data)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }

        // As on document create: the upload endpoint takes ciphertext, not the sealed key, so the
        // key ref is a second call — and a picture whose key never stored is one nothing can read.
        try await storeFileKey(fileID: created.id, encryptedFileKey: sealedFileKey, token: token)
        logger.debug("uploadAttachment succeeded: id=\(created.id, privacy: .public)")
        return created.id
    }

    /// Downloads and decrypts the picture a `neutrino-drive:` reference names.
    ///
    /// Starts from an id alone, which is all a document stores. The bytes have to come back to the
    /// device: a Drive file is end-to-end encrypted, so its download URL serves ciphertext that no
    /// image view — here or on the web — could render.
    func attachmentData(forFileID fileID: String) async throws -> Data {
        let token = try await authorizedToken()
        let ciphertext = try await fetchEncryptedContent(fileID: fileID, token: token)

        // No key ref for this caller means the file is not encrypted to them — an image uploaded
        // before E2EE, or by something that never sealed a key — and the download is already the
        // picture. The web app's resolver makes the same allowance.
        guard let sealedDEK = try await fetchSealedDEKIfPresent(fileID: fileID, token: token) else {
            logger.debug("attachmentData: id=\(fileID, privacy: .public) has no key ref, using bytes as they are")
            return ciphertext
        }

        let dek = try unsealDEK(sealedDEK)
        return Data(try decryptToBytes(data: ciphertext, dek: dek))
    }

    /// Encrypts `{ name, mimeType }` with the DEK, matching the web app's `encryptMetadata()`.
    func encryptMetadata(name: String, mimeType: String, dek: Bytes,
                         xcss: SecretStream.XChaCha20Poly1305) throws -> String {
        let dict: [String: String] = ["name": name, "mimeType": mimeType]
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            throw DocContentError.encryptionFailed
        }
        guard let stream = xcss.initPush(secretKey: dek) else { throw DocContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(json), tag: .FINAL),
              let b64 = Self.sodium.utils.bin2base64(header + cipher, variant: .URLSAFE_NO_PADDING) else {
            throw DocContentError.encryptionFailed
        }
        return b64
    }

    /// Seals `dek` to the caller's stored Curve25519 public key (`crypto_box_seal`).
    func sealDEK(_ dek: Bytes) throws -> String {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString) else {
            throw DocContentError.noEncryptionKey
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: Array(pubKeyData)),
              let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw DocContentError.encryptionFailed
        }
        return b64
    }

    /// Reverses ``sealDEK(_:)`` using the caller's stored private key (`crypto_box_seal_open`).
    func unsealDEK(_ sealedBase64: String) throws -> Bytes {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString),
              let privKeyString = KeychainService.load(forKey: KeyImportService.privateKeyKeychainKey),
              let privKeyData = Data(base64URLEncoded: privKeyString) else {
            logger.error("unsealDEK: no stored key pair, or the stored key is not valid Base64URL")
            throw DocContentError.noEncryptionKey
        }
        guard let sealedBytes = Self.sodium.utils.base642bin(sealedBase64, variant: .URLSAFE_NO_PADDING) else {
            logger.error("unsealDEK: sealed key is not valid Base64URL")
            throw DocContentError.decryptionFailed
        }
        guard let dek: Bytes = Self.sodium.box.open(
            anonymousCipherText: sealedBytes,
            recipientPublicKey: Array(pubKeyData),
            recipientSecretKey: Array(privKeyData)
        ) else {
            logger.error("unsealDEK: seal was not made to this device's public key")
            throw DocContentError.decryptionFailed
        }
        return dek
    }

    // MARK: - HTTP

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw DocContentError.notAuthenticated
        }
        return token
    }

    private func makeRequest(method: String, path: String, token: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw DocContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DocContentError.networkError(underlying: error)
        }
    }

    private func upload(_ request: URLRequest, body: Data,
                        onProgress: (@MainActor (Double) -> Void)? = nil) async throws
    -> (Data, URLResponse) {
        do {
            guard let onProgress else {
                return try await session.upload(for: request, from: body)
            }
            let reporter = UploadProgressReporter(onProgress)
            return try await session.upload(for: request, from: body, delegate: reporter)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // `URLSession` reports a cancelled task this way rather than as `CancellationError`.
            // Kept distinguishable so callers can tell "the user stopped it" from "it failed".
            throw CancellationError()
        } catch {
            throw DocContentError.networkError(underlying: error)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        try checkStatus(response, data: nil)
    }

    /// `data` is the response body, when the caller has it. A 409 is only reported as a version
    /// conflict when the body says so — Drive uses 409 for other things too (a file whose content
    /// is missing from storage, for one), and treating those as "your edit is stale" would tell the
    /// user to reload over a fault reloading cannot fix.
    private static func checkStatus(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DocContentError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 409, let data, isContentVersionConflict(data) {
                throw DocContentError.contentVersionConflict(current: currentVersion(fromErrorBody: data))
            }
            throw DocContentError.serverError(statusCode: http.statusCode)
        }
    }

    /// Drive wraps errors as `{"error": {"code", "message"}}`.
    private static func isContentVersionConflict(_ data: Data) -> Bool {
        struct Envelope: Decodable { struct Body: Decodable { let code: String }; let error: Body }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return false }
        return envelope.error.code == "CONTENT_VERSION_CONFLICT"
    }

    /// The server states the version it holds in the conflict message. Recovering it saves a round
    /// trip when resolving, but it is a nicety — every caller tolerates nil.
    private static func currentVersion(fromErrorBody data: Data) -> Int? {
        struct Envelope: Decodable { struct Body: Decodable { let message: String }; let error: Body }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        guard let range = envelope.error.message.range(of: "found ") else { return nil }
        let digits = envelope.error.message[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func fetchSealedDEK(fileID: String, token: String) async throws -> String {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)/key", token: token)
        let (data, response) = try await data(for: request)
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(APIKeyResponse.self, from: data).encryptedFileKey
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    /// The sealed DEK for a file, or nil when the server has none stored for this caller.
    ///
    /// `GET /files/{id}/key` answers 404 for that case (`get_file_key` in
    /// `src/drive/encryption/api.rs`), which is a fact about the file rather than a failure.
    private func fetchSealedDEKIfPresent(fileID: String, token: String) async throws -> String? {
        let request = try makeRequest(method: "GET",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(APIKeyResponse.self, from: data).encryptedFileKey
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    private func fetchEncryptedContent(fileID: String, token: String) async throws -> Data {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)", token: token)
        let (data, response) = try await data(for: request)
        try Self.checkStatus(response)
        return data
    }

    private func storeFileKey(fileID: String, encryptedFileKey: String, token: String) async throws {
        var request = try makeRequest(method: "PUT",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["encryptedFileKey": encryptedFileKey])
        let (_, response) = try await data(for: request)
        try Self.checkStatus(response)
    }

    /// - Parameter thumbnailBase64: the preview to store with the file, if there is one. It has to
    ///   be written **before** the `file` part: the server reads the multipart stream in order and
    ///   stops at the file, so a field that follows the bytes is one it never sees.
    private func buildUploadBody(encryptedData: Data, fileName: String, mimeType: String,
                                 parentFolderID: String?, encryptedMetadata: String?,
                                 thumbnailBase64: String? = nil) -> MultipartFormBody {
        var form = MultipartFormBody()
        form.appendField(name: "encrypted_metadata", value: encryptedMetadata)
        form.appendField(name: "folder_id", value: parentFolderID)
        form.appendField(name: "thumbnail_b64", value: thumbnailBase64)
        form.appendFile(name: "file", fileName: fileName, mimeType: mimeType, data: encryptedData)
        return form
    }
}

// MARK: - API Response Models

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date    /// Drive's optimistic-concurrency counter. Optional so a server that predates the field
    /// still decodes; a nil version just means the next save goes unguarded.
    let contentVersion: Int?
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
}

// MARK: - UploadProgressReporter

/// Forwards `URLSession`'s byte counts to the main actor.
///
/// A per-task delegate rather than a session-wide one, so it lives exactly as long as the request
/// it reports on and two concurrent uploads cannot report each other's progress. `URLSession` calls
/// this on its own queue, which is why every report hops actors before it reaches the UI.
///
/// Internal rather than private so its arithmetic can be asserted directly: a custom `URLProtocol`
/// drains the request body itself, so no mocked transfer ever calls `didSendBodyData` and there is
/// no other way to reach this from a test.
final class UploadProgressReporter: NSObject, URLSessionTaskDelegate {

    private let report: @MainActor (Double) -> Void

    init(_ report: @escaping @MainActor (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // A chunked body reports -1 for the expected total, which is not a fraction of anything.
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        let report = report
        Task { @MainActor in report(fraction) }
    }
}

// MARK: - API Response Models

/// `GET /api/v1/drive/folders/{id}` — only the folders are read, to find Attachments.
private struct APIFolderContents: Decodable {
    let folders: [APIFolderResponse]
}

private struct APIFolderResponse: Decodable {
    let id: String
    let name: String
}

// MARK: - Data + Base64URL

extension Data {
    /// Decodes a Base64URL string (no padding), which is how Drive returns sealed keys.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}
