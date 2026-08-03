import Foundation

// MARK: - DocumentBody

/// A document as this app works with it: the Markdown the editor shows, plus the parts of the
/// stored ProseMirror document that Markdown cannot express and that must survive a save.
///
/// `layout` travels with the text through every path an edit can take — the editing session, the
/// offline queue, a named version — so a document written back from a phone keeps the header,
/// footer, watermark and theme it was given on the web.
struct DocumentBody: Equatable {

    /// The Markdown editing surface.
    var markdown: String

    /// The web app's `_meta` block, held verbatim. Nil for a document stored without one.
    var layout: JSONValue?

    init(markdown: String, layout: JSONValue? = nil) {
        self.markdown = markdown
        self.layout = layout
    }

    static let empty = DocumentBody(markdown: "")
}

// MARK: - NeutrinoDocumentCodec

/// Translates between a stored document body and the Markdown this app edits.
///
/// A Neutrino Doc's stored body is the web editor's ProseMirror JSON — the backend even seeds a new
/// file with `{"type":"doc","content":[]}` — and both apps read and write the same file through the
/// same Drive endpoints. This type is the single point where that wire format is entered and left,
/// so nothing above it has to know the document is not really Markdown.
///
/// ## Reading a body that is not JSON
///
/// Early builds of this app stored raw Markdown in the same files. Those bodies are still readable:
/// anything that does not decode as a ProseMirror document is taken as Markdown as-is. They are
/// rewritten as JSON the first time they are saved, which is also what makes them open correctly in
/// the web app afterwards.
enum NeutrinoDocumentCodec {

    // MARK: - Decode

    /// Reads a stored body into the Markdown editing surface.
    static func decode(_ stored: String) -> DocumentBody {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Only text that could be a JSON object is worth handing to the decoder: a Markdown
        // document starting with `#` never is, and skipping the attempt keeps the common path off
        // the JSON parser entirely.
        guard trimmed.hasPrefix("{"), let document = ProseMirrorDocument.decode(from: trimmed) else {
            return DocumentBody(markdown: stored)
        }

        return DocumentBody(markdown: ProseMirrorMarkdownReader.markdown(from: document),
                            layout: document.layout)
    }

    // MARK: - Encode

    /// Renders the editing surface back to the stored wire format.
    ///
    /// Encoding cannot meaningfully fail — the document is built here rather than supplied — but
    /// `JSONEncoder` is throwing, so a failure falls back to the Markdown text rather than losing
    /// the user's work to an error. A body that is not JSON is still readable by both apps.
    static func encode(_ body: DocumentBody) -> String {
        let document = ProseMirrorDocument(
            doc: ProseMirrorMarkdownWriter.document(fromMarkdown: body.markdown),
            layout: body.layout
        )
        return (try? document.encoded()) ?? body.markdown
    }
}
