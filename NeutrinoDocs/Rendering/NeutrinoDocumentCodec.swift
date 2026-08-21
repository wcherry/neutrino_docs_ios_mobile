import Foundation
import OSLog

// MARK: - DocumentBody

/// A document as this app works with it: the ProseMirror tree the editor edits, plus the layout
/// block the web app keeps beside it.
///
/// The tree is the document — not a rendering of it, and not a format this app converts to and from.
/// `layout` travels with it through every path an edit can take: the editing session, the offline
/// queue, a named version. So a document written back from a phone keeps the header, footer,
/// watermark and theme it was given on the web.
struct DocumentBody: Equatable {

    /// The `doc` node, exactly as the editor holds it.
    var doc: ProseMirrorNode

    /// The web app's `_meta` block, held verbatim. Nil for a document stored without one.
    var layout: JSONValue?

    init(doc: ProseMirrorNode, layout: JSONValue? = nil) {
        self.doc = doc
        self.layout = layout
    }

    /// What the backend seeds a new file with. The editor shows it as a single empty paragraph.
    static let empty = DocumentBody(doc: ProseMirrorNode(type: DocumentNodeType.doc, content: []))

    /// The blocks of the document, which is what every reader of a body actually wants.
    var blocks: [ProseMirrorNode] { doc.children }
}

// MARK: - NeutrinoDocumentCodec

/// The one place the stored wire format is entered and left.
///
/// A Neutrino Doc's stored body is the web editor's ProseMirror JSON — the backend seeds a new file
/// with `{"type":"doc","content":[]}` — and both apps read and write the same file through the same
/// Drive endpoints. Since the editor now holds that same tree, this type is a thin envelope: it
/// decides which of the two envelope shapes a document is written back in, and nothing else.
///
/// ## Reading a body that is not JSON
///
/// A stored body that does not decode as a ProseMirror document is taken as plain text: one
/// paragraph per line, holding exactly the characters that were stored. Nothing is interpreted —
/// the document format has no syntax to read a body as, and guessing at one would turn whatever the
/// characters happen to be into structure the author never wrote. The text is kept rather than
/// dropped, so a body written by something else can be read, edited, and saved back as JSON.
enum NeutrinoDocumentCodec {

    private static let logger = Logger(subsystem: "com.neutrino.docs", category: "DocumentCodec")

    // MARK: - Decode

    /// Reads a stored body into the document the editor works on.
    static func decode(_ stored: String) -> DocumentBody {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Only text that could be a JSON object is worth handing to the decoder, which keeps a
        // body that is not JSON off the JSON parser entirely.
        guard trimmed.hasPrefix("{"), let document = ProseMirrorDocument.decode(from: trimmed) else {
            logger.notice("body is not a ProseMirror document; reading it as plain text")
            return DocumentBody(doc: plainText(stored))
        }

        return DocumentBody(doc: document.doc, layout: document.layout)
    }

    /// Wraps stored text in the smallest document that holds it: a paragraph per line.
    private static func plainText(_ stored: String) -> ProseMirrorNode {
        let paragraphs = stored.components(separatedBy: "\n").map { line in
            ProseMirrorNode.paragraph(line.isEmpty ? [] : [.text(line)])
        }
        return ProseMirrorNode(type: DocumentNodeType.doc,
                               content: paragraphs.isEmpty ? [] : paragraphs)
    }

    // MARK: - Encode

    /// Renders the document back to the stored wire format.
    ///
    /// Encoding a tree built from `JSONValue` cannot meaningfully fail, but `JSONEncoder` is
    /// throwing; a failure falls back to an empty document rather than to nothing at all, and says
    /// so in the log. The caller has already decided to save, and a body that cannot be encoded is
    /// a bug here rather than something the user can act on.
    static func encode(_ body: DocumentBody) -> String {
        let document = ProseMirrorDocument(doc: body.doc, layout: body.layout)
        do {
            return try document.encoded()
        } catch {
            logger.error("encode failed, writing an empty document: \(error, privacy: .public)")
            return #"{"type":"doc","content":[]}"#
        }
    }
}
