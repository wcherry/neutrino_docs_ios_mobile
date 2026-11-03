import UIKit
import NeutrinoCore
import NeutrinoPrint

// MARK: - DocPreviewer

/// Keeps the document's Drive preview — the picture of page one in the Drive grid — in step with
/// the editor.
///
/// The picture is page one exactly as it prints: ``DocumentPrint`` builds the job and NeutrinoPrint
/// draws its first page. *When* it is redrawn is ``DocumentPreviewGate``'s, the same rule the web
/// editor follows: on load only when the file has no preview, and after a save only when page one
/// changed.
@MainActor
final class DocPreviewer: ObservableObject {

    /// Roughly what fits on page one at the print size — the blocks whose text starts within this
    /// many characters of the top. An approximation of the page boundary that is free to compute,
    /// where the exact one means paginating the whole document on every save; near the boundary it
    /// can redraw a page that did not change, never miss one that did by more than a line or two.
    static let pageOneCharacters = 3_000

    private var gate: DocumentPreviewGate?
    /// The document the next render draws: the one the latest signature was taken from.
    private var document: ProseMirrorNode?
    private var title = ""
    private var bodyFont = UIFont.systemFont(ofSize: 11)
    private var contentService: DocContentService?

    /// Points the previewer at a document. Called once, when it has loaded.
    func attach(fileID: String, contentService: DocContentService) {
        guard gate == nil else { return }
        self.contentService = contentService
        gate = DocumentPreviewGate(
            render: { [weak self] in await self?.renderPageOne() },
            upload: { [contentService] jpeg in try await contentService.setPreview(jpeg, for: fileID) }
        )
    }

    /// The document is on screen: records page one, or draws it if the file has no preview.
    /// Skipped for a reader, whose upload the server would refuse.
    func loaded(_ document: ProseMirrorNode, title: String, bodyFont: UIFont,
                hasPreview: Bool, canEdit: Bool) {
        guard canEdit || hasPreview, let gate else { return }
        remember(document, title: title, bodyFont: bodyFont)
        let signature = Self.signature(of: document)
        Task { await gate.loaded(signature: signature, hasPreview: hasPreview) }
    }

    /// A save landed: redraws page one if it changed.
    func saved(_ document: ProseMirrorNode, title: String, bodyFont: UIFont, hasPreview: Bool) {
        guard let gate else { return }
        remember(document, title: title, bodyFont: bodyFont)
        let signature = Self.signature(of: document)
        Task { await gate.saved(signature: signature, hasPreview: hasPreview) }
    }

    private func remember(_ document: ProseMirrorNode, title: String, bodyFont: UIFont) {
        self.document = document
        self.title = title
        self.bodyFont = bodyFont
    }

    private func renderPageOne() async -> Data? {
        guard let document, let contentService else { return nil }
        let job = await DocumentPrint.job(
            for: document, title: title, bodyFont: bodyFont,
            resolveAttachment: { fileID in try await contentService.attachmentData(forFileID: fileID) }
        )
        return NeutrinoPrintPageRenderer(job: job).firstPageJPEG(maxEdge: DriveThumbnail.maxEdge)
    }

    // MARK: - Signature

    /// Page one's blocks, encoded. Equal whenever page one would print the same, so an edit further
    /// down never redraws it.
    static func signature(of document: ProseMirrorNode) -> String {
        var blocks: [ProseMirrorNode] = []
        var characters = 0
        for block in document.children {
            if !blocks.isEmpty && characters >= pageOneCharacters { break }
            blocks.append(block)
            characters += textLength(of: block)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(blocks)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func textLength(of node: ProseMirrorNode) -> Int {
        (node.text?.count ?? 0) + node.children.reduce(0) { $0 + textLength(of: $1) }
    }
}
