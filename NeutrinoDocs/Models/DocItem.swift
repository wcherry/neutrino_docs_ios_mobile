import Foundation
import NeutrinoCore

// MARK: - DocItem

/// A single folder or Neutrino document within the user's Neutrino Drive.
struct DocItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// Every MIME type a Neutrino document is stored under, which is what this app browses.
    ///
    /// **There are two generations of the format and both are live.** A document created today is
    /// a real `.docx` (`src/drive/storage/native_types.rs`, issue #127); the `x-neutrino-doc` JSON
    /// above it predates that change and is still read and written unchanged — nothing is migrated.
    /// The web library asks for both (`DOC_MIME_TYPES` in `web/packages/api-docs`), and so does
    /// this app: asking for one of them shows half a drive, or — in a drive where every document
    /// was created after the change — none of it at all, which is what this fixes.
    ///
    /// Taken from the shared package so routing a link and filtering a listing cannot disagree
    /// about what a document is.
    static let documentMIMEs = NeutrinoAppLink.Kind.doc.mimeTypes

    /// The format this app *writes*: the bespoke ProseMirror JSON, which the web editor still
    /// reads. Writing OOXML would mean building a `.docx` zip on the phone, which this app cannot
    /// do yet — see ``isEditable``.
    static let documentMIME = "application/x-neutrino-doc"

    /// The stored formats this app can actually parse, under both of the spellings Drive holds.
    ///
    /// Narrower than ``documentMIMEs`` on purpose. A `.docx` is a zip, and the editor's codec
    /// reads a body it cannot parse as *plain text* — so opening one would show a screenful of
    /// binary and the first autosave would overwrite a real Word document with ProseMirror JSON.
    /// Listing a document this app cannot open is right; opening it is not.
    static let editableMIMEs = ["application/x-neutrino-doc", "application/vnd.neutrino.doc"]

    /// Whether a Drive file is a Neutrino document, in either of its formats.
    ///
    /// The server's `type=` filter cannot express "either format" — the per-app `doc` value is
    /// pinned to the bespoke JSON for the benefit of already-shipped clients — so the listings ask
    /// for the coarser `office` category and narrow it with this.
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
        if type == .folder { return "folder.fill" }
        // A Word document gets its own glyph, so a listing says which of its rows this app can
        // open before the user taps one.
        return isEditable ? "doc.text.fill" : "doc.richtext.fill"
    }

    /// Whether this app can open the document's stored body for editing.
    ///
    /// False for a `.docx`, which is the format every document created since issue #127 is in.
    /// This app reads and writes the bespoke ProseMirror JSON only, so a Word document is listed,
    /// renamed, starred, moved and shared here, but opened on the web. See ``editableMIMEs`` for
    /// why letting the editor try anyway would be worse than saying so.
    var isEditable: Bool {
        type == .file && Self.editableMIMEs.contains(mimeType ?? "")
    }

    /// The title to show in a listing.
    ///
    /// A document written in the bespoke JSON has no file format for an extension to name, and
    /// nothing this app creates carries one, so its name is already a plain title. A `.docx` is a
    /// real Word document and its extension is part of the *file* name — it has to land on disk as
    /// `Report.docx` to open on a double-click — but the document is called "Report", which is what
    /// the web library shows too (`stripOoxmlExtension` in `web/packages/api-docs`).
    var displayName: String {
        guard mimeType == NeutrinoAppLink.OOXML.docx else { return name }
        return name.hasSuffix(".docx") ? String(name.dropLast(5)) : name
    }

    /// The name a "Duplicate" of this item should get: `My Report` -> `My Report copy`.
    ///
    /// Drive has no server-side copy endpoint, so duplication is a client-side
    /// download-decrypt-re-encrypt-upload (see `DocsDriveService.duplicate`), and the new name is
    /// this app's business rather than the server's.
    var duplicateName: String { name + " copy" }
}
