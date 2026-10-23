import UIKit
import NeutrinoPrint

// MARK: - DocumentPrint

/// Turns a document into the ``PrintJob`` NeutrinoPrint paginates and sends to the printer.
///
/// Only the part that is about *this* app's documents lives here: projecting the tree into styled
/// text, fetching its pictures, and drawing the bullets and code panels the editor draws beside its
/// lines. The pages, the running header, page numbers, light-appearance rendering and the print
/// dialog are NeutrinoPrint's, and are the same in every Neutrino app.
///
/// A printed document is the whole document: folds are opened and nothing is scrolled out of view.
@MainActor
enum DocumentPrint {

    /// Body text on paper. Whatever size the editor is set to suits a phone screen held at arm's
    /// length, not a page at reading distance.
    static let bodyPointSize: CGFloat = 11

    /// The print job for `document`, once its pictures have been fetched.
    ///
    /// - Parameters:
    ///   - bodyFont: The editor's font. Its family and design carry over; its size does not.
    ///   - resolveAttachment: Downloads and decrypts a Drive picture by file id, as the editor does.
    static func job(for document: ProseMirrorNode,
                    title: String,
                    bodyFont: UIFont,
                    resolveAttachment: ((String) async throws -> Data)?) async -> PrintJob {
        let style = DocumentStyle(bodyFont: bodyFont.withSize(bodyPointSize))
        let projected = DocumentProjection.attributedString(from: document, style: style)

        let images = EditorImageStore()
        images.resolveAttachment = resolveAttachment
        await images.preload(DocumentImageAttachment.imageSources(in: projected))

        let text = DocumentImageAttachment.installingResolved(in: projected, from: images)
        return PrintJob(name: title, content: .pages(pageSource(for: text, font: style.bodyFont)))
    }

    /// Paginates `text` and draws its decorations on each page.
    ///
    /// Nonisolated, and holding nothing but the text: the print system may draw pages off the
    /// main thread.
    nonisolated static func pageSource(for text: NSAttributedString,
                                       font: UIFont) -> AttributedTextPageSource {
        let source = AttributedTextPageSource(text: text)
        let decorations = DocumentDecorations.decorations(in: text)
        let lines = lineRanges(in: text)

        source.drawBehindText = { page in
            guard !decorations.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }

            let painter = DocumentDecorationPainter(
                decorations: decorations,
                font: font,
                columnMinX: page.rect.minX,
                columnMaxX: page.rect.maxX,
                lineGeometry: { line in
                    guard lines.indices.contains(line),
                          let rect = page.boundingRect(forCharacterRange: lines[line]) else {
                        return nil
                    }
                    return DocumentDecorationPainter.LineGeometry(
                        rect: rect,
                        startsHere: page.contains(characterAt: lines[line].location)
                    )
                }
            )
            painter.drawPanels(in: page.rect, context: context)
            painter.drawMarkers(in: page.rect, context: context)
        }
        return source
    }

    /// Each line's characters with the separator that ends it — the range the editor measures a
    /// line by, so an empty list item still has a line to put its bullet against.
    nonisolated static func lineRanges(in text: NSAttributedString) -> [NSRange] {
        let length = text.length
        return DocumentDecorations.lineRanges(in: text).map { range in
            NSRange(location: range.location,
                    length: min(range.length + 1, length - range.location))
        }
    }
}
