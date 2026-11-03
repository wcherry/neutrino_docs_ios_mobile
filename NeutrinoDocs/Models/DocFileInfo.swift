import Foundation
import NeutrinoCore

// MARK: - DocFileInfo

/// The metadata Drive returns for a single file from `GET /api/v1/drive/files/{id}/info`.
///
/// This is the only Drive endpoint that answers for a file the caller can *access* rather than one
/// the caller *owns*, which makes it the right source for two things:
///
/// - `yourRole` — what this account may do with the document, which decides whether the editor is
///   writable (see `DocEditorView`).
/// - `updatedAt` — the server's current version, used for the offline queue's conflict check. The
///   folder listing that would otherwise answer this belongs to the document's owner, so it 404s
///   for a document shared *with* the caller — silently disabling conflict detection for exactly
///   the documents two people might be editing at once.
struct DocFileInfo: Decodable, Hashable {

    // MARK: - Properties

    let id: String
    let name: String
    let sizeBytes: Int64
    let folderID: String?
    let mimeType: String?
    let updatedAt: Date
    /// Non-nil when the file is in the Trash. `/info` still describes a trashed file, unlike the
    /// listings, which drop it.
    let deletedAt: Date?
    let yourRole: ShareRole
    /// Drive's `content_version`, bumped by one on every content write.
    ///
    /// This is the value to send back as `expectedContentVersion` on the next save, which is what
    /// lets the *server* reject a stale write. Comparing `updatedAt` here instead can only ever be
    /// a check-then-write: another device can land an edit in the gap between the check and the
    /// upload, and this client would overwrite it without noticing.
    ///
    /// Optional because a server predating the field omits it; a nil version simply means the save
    /// goes unguarded, exactly as it did before.
    let contentVersion: Int?
    /// True when Drive holds a preview picture of the file (its `coverThumbnailUrl` is set) —
    /// what decides whether opening the document has to draw one.
    let hasPreview: Bool

    // MARK: - Init

    init(id: String, name: String, sizeBytes: Int64, folderID: String?, mimeType: String?,
         updatedAt: Date, deletedAt: Date? = nil, yourRole: ShareRole, contentVersion: Int? = nil,
         hasPreview: Bool = false) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.folderID = folderID
        self.mimeType = mimeType
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.yourRole = yourRole
        self.contentVersion = contentVersion
        self.hasPreview = hasPreview
    }

    // MARK: - Computed

    /// True when the file is still somewhere the caller can reach — what the sync engine means by
    /// "the server still has this document".
    var isLive: Bool { deletedAt == nil }

    // MARK: - Decoding

    /// Drive's zone-less timestamps, camelCase keys — the same shapes the file listings use.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, mimeType, updatedAt, deletedAt, yourRole, contentVersion
        case coverThumbnailUrl
        case folderID = "folderId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        // Absent means the caller owns it: `/info` omits the field for a file in the caller's own
        // drive, and every non-shared listing this app calls is owner-scoped server-side.
        yourRole = ShareRole(serverValue: try container.decodeIfPresent(String.self, forKey: .yourRole) ?? "owner")
        contentVersion = try container.decodeIfPresent(Int.self, forKey: .contentVersion)
        hasPreview = (try container.decodeIfPresent(String.self, forKey: .coverThumbnailUrl)) != nil
    }
}
