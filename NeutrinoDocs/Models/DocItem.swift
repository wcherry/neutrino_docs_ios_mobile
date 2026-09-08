import Foundation
import NeutrinoOOXML

// MARK: - DocItem

/// A single folder or Neutrino document within the user's Neutrino Drive.
struct DocItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// What a Neutrino document is: a real Word document.
    ///
    /// A document created by any Neutrino client is a `.docx` (`src/drive/storage/native_types.rs`,
    /// issue #127), which this app reads and writes through `NeutrinoOOXML` — so Word, LibreOffice
    /// and Google's editors open one directly, and import and export are file copies.
    static let documentMIME = DocxCodec.mimeType

    /// Every MIME type this app browses.
    ///
    /// One entry, and it stays a list because that is the shape both call sites want and because
    /// the server's `type=` filter cannot express "a document" on its own — see
    /// ``DocsDriveService``.
    static let documentMIMEs = [DocxCodec.mimeType]

    /// Whether a Drive file is a Neutrino document.
    static func isDocument(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return documentMIMEs.contains(mimeType)
    }

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
    /// One of `DocItem.documentMIMEs` for documents; `nil` for folders.
    var mimeType: String?
    /// Drive's `isStarred` flag — the Favorites model, shared with the web app, stored on the file
    /// or folder row itself rather than in a list of its own.
    var isStarred: Bool = false
    /// Drive's `contentVersion` as of the last time this device heard from the server. Sent back
    /// as `expectedContentVersion` on the next save so the server can reject a stale write; nil
    /// means unguarded (a listing that does not report it, or a pre-version server).
    var contentVersion: Int?
    /// True for items reached through `GET /drive/shared-with-me`, i.e. owned by somebody else.
    /// Every other Drive listing this app calls is owner-scoped server-side, so anything without
    /// this flag belongs to the signed-in account.
    var isShared: Bool = false

    // MARK: - Computed

    /// SF Symbol representing the item in a listing.
    var iconName: String {
        type == .folder ? "folder.fill" : "doc.text.fill"
    }

    /// Whether this app can open the document's stored body for editing.
    var isEditable: Bool {
        type == .file && Self.isDocument(mimeType)
    }

    /// The title to show in a listing.
    ///
    /// A `.docx` is a real Word document and its extension is part of the *file* name — it has to
    /// land on disk as `Report.docx` to open on a double-click — but the document is called
    /// "Report", which is what the web library shows too (`stripOoxmlExtension` in
    /// `web/packages/api-docs`).
    var displayName: String { DocxCodec.strippingExtension(name) }

    /// The name a "Duplicate" of this item should get: `My Report.docx` -> `My Report copy.docx`.
    ///
    /// Drive has no server-side copy endpoint, so duplication is a client-side
    /// download-decrypt-re-encrypt-upload (see `DocsDriveService.duplicate`), and the new name is
    /// this app's business rather than the server's. The extension is put back on rather than left
    /// where it was: `My Report.docx copy` is a file the operating system no longer recognises.
    var duplicateName: String { DocxCodec.withExtension(displayName + " copy") }
}
