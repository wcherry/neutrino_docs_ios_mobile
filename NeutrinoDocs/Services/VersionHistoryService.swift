import Foundation
import Sodium
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - VersionHistoryError

enum VersionHistoryError: LocalizedError {
    case notAuthenticated
    case noContentService
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .noContentService:       return "Version history is unavailable right now."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - VersionHistoryService

/// Reads and writes a document's version history through Drive's existing versioning APIs — Docs
/// adds no versioning of its own.
///
/// Every snapshot is stored as the ciphertext that was uploaded at the time, and a file's DEK never
/// rotates, so the session DEK the editor already holds decrypts every version of that document.
/// All crypto is delegated to `DocContentService`; this type owns only the HTTP.
///
/// One consequence of the server's design is worth stating plainly: **autosave does not snapshot.**
/// Only the initial upload and an explicit save create a version, so a document accumulates history
/// only when the user saves one — which is why the editor offers "Save Version…" alongside its
/// automatic saving.
@MainActor
final class VersionHistoryService: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch so the service can refresh tokens before requests.
    weak var authService: AuthService?

    /// Set once at app launch — supplies the encrypt/decrypt primitives.
    weak var contentService: DocContentService?

    // MARK: - Private

    private static let sodium = Sodium()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "VersionHistoryService")

    private let session: URLSession

    private var baseURL: String { AuthService.baseURL }

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - List

    /// All snapshots for a document, newest first (the server orders by version number descending).
    /// Phase 1 — Version History: "Previous versions", "View timestamps".
    func listVersions(fileID: String) async throws -> [DocVersion] {
        logger.debug("listVersions: id=\(fileID, privacy: .public)")
        let data = try await get("/api/v1/drive/files/\(fileID)/versions")
        do {
            let response = try DocVersion.decoder.decode(APIListVersionsResponse.self, from: data)
            return response.versions
        } catch {
            logger.error("listVersions decode failed: \(error, privacy: .public)")
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - Read a snapshot

    /// Downloads a snapshot, decrypts it with the document's DEK, and reads it into a body.
    ///
    /// A snapshot is a stored body like any other — a `.docx` — and is read exactly as the current
    /// content is.
    func versionBody(fileID: String, versionID: String, dek: Bytes) async throws -> DocumentBody {
        guard let content = contentService else { throw VersionHistoryError.noContentService }
        let ciphertext = try await get("/api/v1/drive/files/\(fileID)/versions/\(versionID)/download")
        return NeutrinoDocumentCodec.decode(Data(try content.decryptToBytes(data: ciphertext, dek: dek)))
    }

    // MARK: - Save a named version

    /// Encrypts `body` with the document's DEK and saves it as a named snapshot.
    ///
    /// The server also makes this the document's current content, so this is a save-and-snapshot
    /// rather than a snapshot-only — the same behaviour as the web app's explicit save. That is also
    /// why the body is encoded exactly as an autosave encodes it: the snapshot and the document's
    /// current content are the same bytes.
    func saveVersion(_ body: DocumentBody, for item: DocItem, dek: Bytes,
                     label: String?) async throws -> DocVersion {
        logger.debug("saveVersion: id=\(item.id, privacy: .public) labeled=\(label != nil)")
        guard let content = contentService else { throw VersionHistoryError.noContentService }

        // The document's pictures are fetched and embedded here as they are for an autosave: a
        // snapshot the user can restore has to be a whole document, not one with its images
        // replaced by placeholders.
        let stored = NeutrinoDocumentCodec.encode(body, title: item.displayName,
                                                  images: await content.imageBytes(for: body))
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let ciphertext = try content.encrypt(bytes: Array(stored), dek: dek, xcss: xcss)

        var form = MultipartFormBody()
        form.appendField(name: "label", value: label)
        form.appendFile(name: "file", fileName: item.name,
                        mimeType: item.mimeType ?? DocItem.documentMIME, data: ciphertext)

        var request = try makeRequest(method: "POST", path: "/api/v1/drive/files/\(item.id)/versions")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await perform(request, body: form.finalized())
        do {
            return try DocVersion.decoder.decode(DocVersion.self, from: data)
        } catch {
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - Restore

    /// Makes a snapshot the document's current content. Phase 1 — Version History: "Restore
    /// version".
    ///
    /// The server snapshots the pre-restore content first, so a restore is itself undoable from the
    /// history list. Returns the document's new size and modification date so callers can reflect
    /// them without a second round trip.
    @discardableResult
    func restore(versionID: String, fileID: String) async throws -> (sizeBytes: Int64, modifiedAt: Date) {
        logger.debug("restore: id=\(fileID, privacy: .public) version=\(versionID, privacy: .public)")
        let request = try makeRequest(method: "POST",
                                      path: "/api/v1/drive/files/\(fileID)/versions/\(versionID)/restore")
        let data = try await perform(request, body: nil)
        do {
            let file = try DocVersion.decoder.decode(APIFileMetadataResponse.self, from: data)
            return (file.sizeBytes, file.updatedAt)
        } catch {
            throw VersionHistoryError.decodingError(underlying: error)
        }
    }

    // MARK: - HTTP

    private func makeRequest(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    private func get(_ path: String) async throws -> Data {
        try await perform(try makeRequest(method: "GET", path: path), body: nil)
    }

    /// Refreshes the token, injects it, and returns the raw response body. Callers decode it, or
    /// use it as-is where the body is ciphertext rather than JSON.
    private func perform(_ req: URLRequest, body: Data?) async throws -> Data {
        var req = req
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw VersionHistoryError.notAuthenticated
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: req, from: body)
            } else {
                (data, response) = try await session.data(for: req, retry: .default)
            }
        } catch {
            throw VersionHistoryError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VersionHistoryError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw VersionHistoryError.serverError(statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - API Response Models

private struct APIListVersionsResponse: Decodable {
    let versions: [DocVersion]
    let total: Int
}

/// The subset of Drive's file metadata the restore endpoint returns that this service needs.
private struct APIFileMetadataResponse: Decodable {
    let sizeBytes: Int64
    let updatedAt: Date
}
