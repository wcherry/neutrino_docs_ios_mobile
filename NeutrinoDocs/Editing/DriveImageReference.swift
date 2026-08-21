import Foundation

// MARK: - DriveImageReference

/// The `neutrino-drive:<fileId>` reference a document stores in place of a picture.
///
/// ## What a document holds now
///
/// A Neutrino Doc no longer carries image bytes. Every picture is a file in Drive and the document
/// holds only its id, so a document is the size of its text however many photographs it shows.
/// `EditorImageStore` turns a reference back into a picture by downloading and decrypting the file
/// it names, which is the only way it *can* work: a Drive file is end-to-end encrypted, so its
/// download URL serves ciphertext that no image view could render.
///
/// This replaced storing the bytes inline as a `data:` URI. That put a photograph — hundreds of
/// thousands of characters of base64 — into the document text itself, where it was re-encrypted and
/// re-uploaded on every autosave, and walked by the editor on every keystroke.
///
/// ## Shared with the web app
///
/// The spelling is the same one `driveImageRef` and `parseDriveImageRef` use in
/// `web/apps/web/src/lib/driveImages.ts`, and the two must stay in step: both apps read and write
/// the same file through the same Drive endpoints.
///
/// ## Documents written before this
///
/// Anything that is not a reference — an `http(s):` URL, a `data:` URI — is left exactly as it is
/// and still renders, matching what the web app does. This app no longer *writes* either form, but
/// it reads both, so a document from before the change opens unchanged and is not silently rewritten.
enum DriveImageReference {

    /// The URI scheme, including its colon.
    static let scheme = "neutrino-drive:"

    /// What a document stores for a picture held in Drive.
    static func source(fileID: String) -> String { scheme + fileID }

    /// The Drive file id a source refers to, or nil when it is not a reference.
    ///
    /// Surrounding whitespace is tolerated because a source travels as text, where a
    /// stray space either side of a link destination is invisible and easily introduced by hand.
    static func fileID(from source: String) -> String? {
        guard source.hasPrefix(scheme) else { return nil }
        let id = source.dropFirst(scheme.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Whether a source has to be resolved through Drive before anything can be drawn.
    static func isReference(_ source: String) -> Bool { fileID(from: source) != nil }
}
