import Foundation
import Sodium
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoOOXML

// MARK: - DocContentError

enum DocContentError: LocalizedError {
    case noEncryptionKey
    /// This device holds an identity, but not the version this document's DEK was sealed to.
    /// Named separately from `noEncryptionKey` because it sends the user somewhere else: not
    /// "import your key" but "this account rotated and this device is missing a version".
    case missingKeyVersion(Int)
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
        case .missingKeyVersion(let version):
            return "This document needs encryption key version \(version), which this device does not have. Scanning the key code again will not help \u{2014} it carries one key. On the computer that holds your key, open Settings \u{203A} Encryption and back up your older keys, then reopen this app."
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

// MARK: - SealedFileKey

/// A document's DEK as the server holds it: the sealed blob, and which of the caller's identity
/// versions it was sealed to.
///
/// The two travel together everywhere because they are only meaningful together. Passing the blob
/// alone is what let a rotated account's older documents fail to open — the caller had no way to
/// know which key to reach for, so it always reached for the newest.
struct SealedFileKey: Equatable {
    let sealed: String
    let keyVersion: Int

    init(sealed: String, keyVersion: Int) {
        self.sealed = sealed
        self.keyVersion = keyVersion
    }

    /// A ref written before versioning carries no version. Read as 1, which is what the server
    /// defaults `file_key_refs.key_version` to for the same rows.
    fileprivate init(_ response: APIKeyResponse) {
        self.sealed = response.encryptedFileKey
        self.keyVersion = response.keyVersion ?? 1
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
/// What a Neutrino document stores is a `.docx`, which is why every method here that deals in whole
/// documents speaks `DocumentBody` rather than `Data`: the editor holds a tree, and
/// `NeutrinoDocumentCodec` enters and leaves the stored package at exactly two points — just after
/// decrypting and just before encrypting. The lower-level ``encrypt(bytes:dek:xcss:)`` and
/// ``decryptToBytes(data:dek:)`` stay untranslated, because the offline cache and version history
/// need to move stored bytes around without reinterpreting them.
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
        populated.size = Int64(saved.encoded.count)
        return populated
    }

    /// The shared create path. Returns the DEK alongside the item so a caller that immediately
    /// writes content does not have to fetch and unseal a key it just generated.
    private func create(name: String, parentID: String?) async throws -> (item: DocItem, dek: Bytes) {
        logger.debug("createDocument: parentID=\(parentID ?? "root", privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let dek: Bytes = xcss.key()
        // A new file holds a real, empty `.docx` rather than nothing at all. The web app creates
        // one with an empty body — the server has no business building a package and could only
        // write it in the clear — and its editor opens that as a blank document; a valid package is
        // strictly better, and it means a document created here downloads and opens in Word before
        // it has ever been edited.
        let encryptedContent = try encrypt(
            bytes: Array(NeutrinoDocumentCodec.encode(.empty, title: DocxCodec.strippingExtension(name))),
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
        try await storeFileKey(fileID: created.id, sealedFileKey: sealedFileKey, token: token)
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
        let dek = try unsealDEK(sealedFileKey.sealed, keyVersion: sealedFileKey.keyVersion, fileID: item.id)
        let encryptedData = try await fetchEncryptedContent(fileID: item.id, token: token)
        let stored = Data(try decryptToBytes(data: encryptedData, dek: dek))
        let body = NeutrinoDocumentCodec.decode(stored)

        logger.debug("loadContent succeeded: id=\(item.id, privacy: .public) (\(stored.count) stored bytes)")
        return (body, dek)
    }

    // MARK: - Save

    /// The outcome of a successful save: the server's own view of the document afterwards, and the
    /// bytes that produced it.
    struct SaveResult {
        let updatedAt: Date
        /// The version the document is now at. Hold it and send it back on the next save.
        let contentVersion: Int?
        /// The `.docx` that was uploaded, so a caller that has to record the document's size or
        /// refresh an offline copy does not encode the same body a second time — and cannot encode
        /// it *differently*, which would leave the cache holding bytes the server does not have.
        let encoded: Data
        /// Whether Drive holds a preview picture of the document. See ``DocPreviewer``.
        let hasPreview: Bool
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

        // The pictures the document points at have to be *in* the package: a `.docx` carries its
        // own media, and a Drive reference means nothing to Word. Resolved here rather than by the
        // caller because this is the only object that can reach Drive for them.
        let encoded = NeutrinoDocumentCodec.encode(body, title: item.displayName,
                                                   images: await imageBytes(for: body))
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let encryptedContent = try encrypt(bytes: Array(encoded), dek: dek, xcss: xcss)

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
            return SaveResult(updatedAt: updated.updatedAt, contentVersion: updated.contentVersion,
                              encoded: encoded, hasPreview: updated.coverThumbnailUrl != nil)
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Preview

    /// Stores `jpeg` as the document's Drive preview — the picture of page one the Drive grid shows.
    ///
    /// Unlike the content it is not encrypted: the server cannot draw a document it cannot read, so
    /// the preview is the one picture of it that is stored in the clear, exactly like the
    /// thumbnail an upload carries.
    func setPreview(_ jpeg: Data, for fileID: String) async throws {
        let token = try await authorizedToken()
        var request = try makeRequest(method: "PUT", path: DriveThumbnail.path(fileID: fileID), token: token)
        DriveThumbnail.prepare(&request, jpeg: jpeg)
        let (data, response) = try await data(for: request)
        try Self.checkStatus(response, data: data)
    }

    // MARK: - Image bytes

    /// Bytes for every picture in `body`, as far as they can be resolved.
    ///
    /// A picture is a Drive file of its own, encrypted to its own key, and the package has to carry
    /// the actual bytes — so writing a document with pictures means fetching and decrypting each of
    /// them. Results are memoised for the life of this service: an autosave every few seconds must
    /// not re-download a document's photographs each time.
    ///
    /// A picture that cannot be fetched — offline, or a file this account can no longer read — is
    /// simply absent from the result, and the codec writes a placeholder that keeps the image node
    /// intact. This never throws for that reason: a save that failed because one picture is
    /// unreachable would lose the user's text over a picture they can still see.
    func imageBytes(for body: DocumentBody) async -> [String: Data] {
        var out: [String: Data] = [:]
        for source in body.imageSources {
            // A `data:` URL is already the picture, and anything else is not something to fetch:
            // an `http` image belongs to a site rather than to this drive.
            guard source.hasPrefix(DocxCodec.driveReferenceScheme) else { continue }
            if let cached = imageCache[source] {
                out[source] = cached
                continue
            }
            let fileID = String(source.dropFirst(DocxCodec.driveReferenceScheme.count))
            guard let data = try? await attachmentData(forFileID: fileID) else {
                logger.debug("imageBytes: could not resolve \(fileID, privacy: .public)")
                continue
            }
            imageCache[source] = data
            out[source] = data
        }
        return out
    }

    /// The same, without the network: whatever this session has already fetched.
    ///
    /// What an offline save has to work from. The cache is warm for any picture the editor has
    /// drawn, since that is the same fetch, so the common case — editing a document you were just
    /// reading — keeps its pictures in the package.
    func cachedImageBytes(for body: DocumentBody) -> [String: Data] {
        var out: [String: Data] = [:]
        for source in body.imageSources {
            if let cached = imageCache[source] { out[source] = cached }
        }
        return out
    }

    /// Decrypted picture bytes by `src`. Bounded by what one editing session touches; cleared with
    /// the service.
    private var imageCache: [String: Data] = [:]

    // MARK: - Offline support

    /// Downloads a document's still-encrypted body together with its sealed DEK, without
    /// decrypting. Used by `OfflineStore` so the cache-at-rest blob is byte-identical to the
    /// server's.
    func downloadEncrypted(for item: DocItem) async throws -> (ciphertext: Data, sealedDEK: SealedFileKey) {
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
        try await storeFileKey(fileID: created.id, sealedFileKey: sealedFileKey, token: token)
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
        let picture: Data
        if let sealedDEK = try await fetchSealedDEKIfPresent(fileID: fileID, token: token) {
            let dek = try unsealDEK(sealedDEK.sealed, keyVersion: sealedDEK.keyVersion, fileID: fileID)
            picture = Data(try decryptToBytes(data: ciphertext, dek: dek))
        } else {
            logger.debug("attachmentData: id=\(fileID, privacy: .public) has no key ref, using bytes as they are")
            picture = ciphertext
        }

        // Kept for the writer. The editor fetches through here to draw a picture, so a document
        // being looked at already has what saving it will need — including when the connection
        // drops between the two.
        imageCache["\(DocxCodec.driveReferenceScheme)\(fileID)"] = picture
        return picture
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

    /// Seals `dek` to the caller's **active** Curve25519 public key (`crypto_box_seal`), and
    /// reports which version that was.
    ///
    /// The version travels with the sealed key because the server records it on the key ref, and
    /// a ref that names the wrong version is a document nothing can open: the web client would
    /// reach for the key the ref names, not the one it was actually sealed to.
    func sealDEK(_ dek: Bytes) throws -> SealedFileKey {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString) else {
            throw DocContentError.noEncryptionKey
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: Array(pubKeyData)),
              let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw DocContentError.encryptionFailed
        }
        return SealedFileKey(sealed: b64, keyVersion: KeyImportService.activeKeyVersion())
    }

    /// Reverses ``sealDEK(_:)``, resolving `keyVersion` against the keys this device holds.
    ///
    /// `keyVersion` defaults to 1 because key refs written before rotation existed carry no
    /// version, and the server defaults the column to 1 for exactly the same reason.
    ///
    /// A version this device lacks is reported as `missingKeyVersion` rather than as a decrypt
    /// failure. The distinction is the whole point of the versioning: the ciphertext is fine, the
    /// DEK is fine, and what is missing is one key that can still be brought across.
    ///
    /// The ref's version is tried first and every other key this device holds after it, because
    /// this app used to file its key under the vault's envelope version: on a rotated account its
    /// uploads were sealed to the active key and recorded as v1. When one opens under a different
    /// version and `fileID` is given, the ref is re-filed under the right one in the background.
    func unsealDEK(_ sealedBase64: String, keyVersion: Int = 1, fileID: String? = nil) throws -> Bytes {
        let opened: OpenedDEK
        do {
            opened = try KeyImportService.openSealedDEK(sealedBase64, keyVersion: keyVersion)
        } catch SealedDEKError.noKey {
            logger.error("unsealDEK: this device holds no encryption key")
            throw DocContentError.noEncryptionKey
        } catch SealedDEKError.missingVersion(let version) {
            logger.error("unsealDEK: no key for version \(version, privacy: .public)")
            throw DocContentError.missingKeyVersion(version)
        } catch {
            logger.error("unsealDEK: no key this device holds opens the seal (ref names v\(keyVersion, privacy: .public))")
            throw DocContentError.decryptionFailed
        }
        if opened.isMisfiled, let fileID {
            refileKey(fileID: fileID, sealed: sealedBase64, version: opened.version)
        }
        return opened.dek
    }

    /// Re-files a key ref under the version that actually opens it — same sealed bytes, new number.
    /// Best effort: the DEK is already in hand, and a failure here is retried by the next open.
    private func refileKey(fileID: String, sealed: String, version: Int) {
        logger.info("refiling \(fileID, privacy: .public)'s key under v\(version, privacy: .public)")
        Task {
            guard let token = try? await authorizedToken() else { return }
            try? await storeFileKey(fileID: fileID,
                                    sealedFileKey: SealedFileKey(sealed: sealed, keyVersion: version),
                                    token: token)
        }
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
            return try await session.data(for: request, retry: .default)
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

    private func fetchSealedDEK(fileID: String, token: String) async throws -> SealedFileKey {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)/key", token: token)
        let (data, response) = try await data(for: request)
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return SealedFileKey(try decoder.decode(APIKeyResponse.self, from: data))
        } catch {
            throw DocContentError.decodingError(underlying: error)
        }
    }

    /// The sealed DEK for a file, or nil when the server has none stored for this caller.
    ///
    /// `GET /files/{id}/key` answers 404 for that case (`get_file_key` in
    /// `src/drive/encryption/api.rs`), which is a fact about the file rather than a failure.
    private func fetchSealedDEKIfPresent(fileID: String, token: String) async throws -> SealedFileKey? {
        let request = try makeRequest(method: "GET",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return SealedFileKey(try decoder.decode(APIKeyResponse.self, from: data))
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

    private func storeFileKey(fileID: String, sealedFileKey: SealedFileKey, token: String) async throws {
        var request = try makeRequest(method: "PUT",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `keyVersion` is sent, not left to the server's default of 1. Omitting it on a rotated
        // account files a document sealed to v3 under v1, and every client — this one included —
        // then reaches for the wrong key and cannot open a document that is perfectly intact.
        request.httpBody = try JSONEncoder().encode(
            SetFileKeyBody(encryptedFileKey: sealedFileKey.sealed, keyVersion: sealedFileKey.keyVersion)
        )
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
    /// Where Drive serves the file's preview, or nil when it has none.
    let coverThumbnailUrl: String?
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
    /// Which of the caller's identity versions the DEK is sealed to. Optional so a server that
    /// predates versioning still decodes; `SealedFileKey` reads a missing value as 1, matching the
    /// column's own default.
    let keyVersion: Int?
}

/// `PUT /drive/files/{id}/key`. `keyVersion` says which entry of the caller's keyring the sealed
/// DEK belongs to, so a later read reaches for the right one.
private struct SetFileKeyBody: Encodable {
    let encryptedFileKey: String
    let keyVersion: Int
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
