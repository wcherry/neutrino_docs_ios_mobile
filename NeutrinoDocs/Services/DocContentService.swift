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

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:        return "No encryption key found. Import your key before opening or creating documents."
        case .encryptionFailed:       return "Failed to encrypt the document."
        case .decryptionFailed:       return "Failed to decrypt the document."
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
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
/// ## The body is not Markdown
///
/// What a Neutrino Doc stores is the web editor's ProseMirror JSON, which is why every method here
/// that deals in whole documents speaks `DocumentBody` rather than `String`: the Markdown the editor
/// shows is a translation, made by `NeutrinoDocumentCodec` at exactly two points — just after
/// decrypting and just before encrypting. The lower-level ``encrypt(text:dek:xcss:)`` and
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

    /// Creates a new, empty Markdown document in Drive and returns the resulting item.
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
        guard !body.markdown.isEmpty else { return item }
        // The DEK is carried over from `create` rather than re-fetched: the key was generated on
        // this device moments ago, and going back to `/files/{id}/key` for it would be a round trip
        // to be told something we already know.
        let updatedAt = try await saveContent(body, for: item, dek: dek)
        var populated = item
        populated.modifiedAt = updatedAt
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
        let encryptedMetadata = try encryptMetadata(name: name, mimeType: DocItem.markdownMIME,
                                                    dek: dek, xcss: xcss)
        let sealedFileKey = try sealDEK(dek)

        let form = buildUploadBody(
            encryptedData: encryptedContent, fileName: name, mimeType: DocItem.markdownMIME,
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

        let item = DocItem(
            id: created.id, name: created.name, type: .file, parentID: created.folderId,
            size: created.sizeBytes, modifiedAt: created.updatedAt, isTrashed: false,
            mimeType: created.mimeType
        )
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

    /// Encrypts `body` with the document's existing DEK and PUTs it to the autosave endpoint.
    /// Returns the server's new `updatedAt` so the caller can reflect it without a second request.
    ///
    /// Note that autosave deliberately does *not* snapshot a version server-side; only the initial
    /// upload and an explicit save do (see `VersionHistoryService`).
    @discardableResult
    func saveContent(_ body: DocumentBody, for item: DocItem, dek: Bytes) async throws -> Date {
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
            mimeType: item.mimeType ?? DocItem.markdownMIME,
            parentFolderID: nil, encryptedMetadata: nil
        )

        var request = try makeRequest(method: "PUT",
                                      path: "/api/v1/drive/files/\(item.id)/autosave",
                                      token: token)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response)
        do {
            let updated = try Self.decoder.decode(APIFileResponse.self, from: data)
            logger.debug("saveContent succeeded: id=\(item.id, privacy: .public)")
            return updated.updatedAt
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
        guard let stream = xcss.initPush(secretKey: dek) else { throw DocContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(text.utf8), tag: .FINAL) else {
            throw DocContentError.encryptionFailed
        }
        return Data(header + cipher)
    }

    /// Reverses ``encrypt(text:dek:xcss:)``.
    func decrypt(data: Data, dek: Bytes) throws -> String {
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
        guard let text = String(bytes: plaintext, encoding: .utf8) else {
            logger.error("decrypt: plaintext is not valid UTF-8")
            throw DocContentError.decryptionFailed
        }
        return text
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

    private func upload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, from: body)
        } catch {
            throw DocContentError.networkError(underlying: error)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DocContentError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw DocContentError.serverError(statusCode: http.statusCode)
        }
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

    private func buildUploadBody(encryptedData: Data, fileName: String, mimeType: String,
                                 parentFolderID: String?, encryptedMetadata: String?) -> MultipartFormBody {
        var form = MultipartFormBody()
        form.appendField(name: "encrypted_metadata", value: encryptedMetadata)
        form.appendField(name: "folder_id", value: parentFolderID)
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
    let updatedAt: Date
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
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
