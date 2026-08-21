import Foundation

// MARK: - DocItem

/// A single folder or Neutrino document within the user's Neutrino Drive.
struct DocItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// The only file MIME type this app browses. Drive's proprietary type for Neutrino documents,
    /// the same value the server's `type=doc` filter matches on. Everything else in Drive is out of
    /// scope for Docs.
    ///
    /// Note the server also has a `type=document` filter, which is a different, disjoint set
    /// (`text/%`, PDF, Word, RTF — uploaded files rather than native documents). Docs wants `doc`.
    static let documentMIME = "application/x-neutrino-doc"

    // MARK: - Properties

    let id: String
    var name: String
    let type: ItemType
    /// `nil` means the root of the drive.
    var parentID: String?
    /// Bytes; `nil` for folders.
    var size: Int64?
    var modifiedAt: Date
    var isTrashed: Bool
    /// `DocItem.documentMIME` for documents; `nil` for folders.
    var mimeType: String?
    /// Drive's `isStarred` flag — the Favorites model, shared with the web app, stored on the file
    /// or folder row itself rather than in a list of its own.
    var isStarred: Bool = false
    /// True for items reached through `GET /drive/shared-with-me`, i.e. owned by somebody else.
    /// Every other Drive listing this app calls is owner-scoped server-side, so anything without
    /// this flag belongs to the signed-in account.
    var isShared: Bool = false

    // MARK: - Computed

    /// SF Symbol representing the item in a listing.
    var iconName: String {
        type == .folder ? "folder.fill" : "doc.text.fill"
    }

    /// The title to show in a listing, which is simply the document's name.
    ///
    /// A name is a plain title: a Neutrino Doc holds a document tree, so there is no file format for
    /// an extension to name and nothing this app creates carries one.
    var displayName: String { name }

    /// The name a "Duplicate" of this item should get: `My Report` -> `My Report copy`.
    ///
    /// Drive has no server-side copy endpoint, so duplication is a client-side
    /// download-decrypt-re-encrypt-upload (see `DocsDriveService.duplicate`), and the new name is
    /// this app's business rather than the server's.
    var duplicateName: String { name + " copy" }
}
