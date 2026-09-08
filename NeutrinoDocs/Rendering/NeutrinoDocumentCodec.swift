import Foundation
import OSLog
import NeutrinoOOXML

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

    /// An empty document — one empty paragraph, as the editor shows it.
    static let empty = DocumentBody(doc: ProseMirrorNode(type: DocumentNodeType.doc, content: []))

    /// The blocks of the document, which is what every reader of a body actually wants.
    var blocks: [ProseMirrorNode] { doc.children }

    /// Every image the document points at, in document order. What a caller has to resolve to bytes
    /// before the body can be written back — see ``NeutrinoDocumentCodec``.
    var imageSources: [String] {
        var out: [String] = []
        var seen = Set<String>()
        func walk(_ node: ProseMirrorNode) {
            if node.type == DocumentNodeType.image,
               let src = node.attribute("src")?.stringValue, !src.isEmpty,
               seen.insert(src).inserted {
                out.append(src)
            }
            node.children.forEach(walk)
        }
        walk(doc)
        return out
    }
}

// MARK: - NeutrinoDocumentCodec

/// The one place the stored wire format is entered and left.
///
/// A Neutrino document is a real Word document: Drive stores a `.docx` (issue #127), every client
/// reads and writes that same package, and the tree the editor holds is what
/// `NeutrinoOOXML` maps to and from it. This type is the seam — decode just after decrypting,
/// encode just before encrypting — and the only place in the app that knows the body is not JSON.
///
/// ## Images
///
/// A picture in a document is a *reference* to another Drive file, and a `.docx` has to carry the
/// bytes. Only this device can fetch those, so ``encode(_:title:images:)`` takes what the caller
/// managed to resolve (see `DocContentService.imageBytes(for:)`). What it could not resolve — a save
/// made with no connection — is written as a placeholder carrying the whole image node, so the
/// picture is still in the document when it is read back and becomes a real picture again on the
/// next save that can reach Drive.
///
/// ## Reading a body that is not a package
///
/// A stored body that is not a `.docx` is taken as plain text: one paragraph per line, holding
/// exactly the characters that were stored. Nothing is interpreted — guessing at a syntax would turn
/// whatever the characters happen to be into structure the author never wrote. The text is kept
/// rather than dropped, so a body written by something else can be read, edited, and saved back as a
/// real document.
enum NeutrinoDocumentCodec {

    private static let logger = Logger(subsystem: "com.neutrino.docs", category: "DocumentCodec")

    // MARK: - Decode

    /// Reads a stored body into the document the editor works on.
    static func decode(_ stored: Data) -> DocumentBody {
        guard !stored.isEmpty else { return .empty }

        guard DocxCodec.isDocument(stored) else {
            logger.notice("body is not a .docx; reading it as plain text")
            return DocumentBody(doc: plainText(String(decoding: stored, as: UTF8.self)))
        }

        do {
            let json = try DocxCodec.decodeToJSON(stored)
            guard let document = ProseMirrorDocument.decode(from: json) else {
                logger.error("decode produced JSON the document model would not take")
                return .empty
            }
            return DocumentBody(doc: document.doc, layout: document.layout)
        } catch {
            // A package this app cannot read is not a document it should offer to overwrite, but it
            // is also not a crash: the editor shows an empty document and the save path refuses to
            // write over content it never loaded (see `DocEditorView`).
            logger.error("decode failed: \(error, privacy: .public)")
            return .empty
        }
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

    /// Renders the document back to the stored `.docx`.
    ///
    /// - Parameters:
    ///   - title: the document's title, which is also what a `{{title}}` field resolves to. The
    ///     Drive file's name with the extension stripped — see `DocItem.displayName`.
    ///   - images: bytes for the sources `DocumentBody.imageSources` reports, as far as the caller
    ///     could resolve them.
    ///
    /// A body that cannot be encoded falls back to an empty document rather than to nothing at all,
    /// and says so in the log. The caller has already decided to save, and a package that cannot be
    /// built is a bug here rather than something the user can act on.
    static func encode(_ body: DocumentBody, title: String,
                       images: [String: Data] = [:]) -> Data {
        do {
            let document = ProseMirrorDocument(doc: body.doc, layout: body.layout)
            return try DocxCodec.encodeJSON(try document.encoded(), title: title, images: images)
        } catch {
            logger.error("encode failed, writing an empty document: \(error, privacy: .public)")
            return (try? DocxCodec.emptyDocument(title: title)) ?? Data()
        }
    }
}
