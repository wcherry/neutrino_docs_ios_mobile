import Foundation
import UIKit

// MARK: - DocumentDecoration

/// Something the editor draws beside a line that is not part of the line's text.
///
/// A bullet is the clearest case: the document says the line is an item of a `bulletList`, and
/// nothing in the text says so — there is no `- ` to show, because the document is a tree. The dot
/// on screen is drawn from the structure rather than read from the characters, which is what lets
/// the same document draw a number instead when its list is ordered.
struct DocumentDecoration: Equatable {

    enum Kind: Equatable {
        /// A bulleted item's dot, at a nesting depth.
        case bullet(depth: Int)
        /// An ordered item's label — `3.` — already numbered.
        case orderedMarker(String, depth: Int)
        case checkbox(checked: Bool, depth: Int)
        /// One bar per level of quoting, so a quote inside a quote reads as two.
        case quoteBar(depth: Int)
        /// The panel behind a code block. A code block is a single line in the projection — its
        /// own newlines are breaks *within* the block — so one decoration covers all of it.
        case codeBlock
        case thematicBreak
    }

    /// Index of the line in the projected text, counting block separators.
    var line: Int
    var kind: Kind
}

// MARK: - DocumentDecorations

/// Reads the decorations a projected document calls for.
///
/// Pure, and deliberately independent of the text view: what a document draws beside its lines is
/// asserted directly in tests rather than discovered by looking at a screenshot.
enum DocumentDecorations {

    /// Every decoration the text calls for, in line order.
    static func decorations(in text: NSAttributedString) -> [DocumentDecoration] {
        var result: [DocumentDecoration] = []
        var previousItemID: Int?

        for (index, line) in lineRanges(in: text).enumerated() {
            let block = EditorDocumentState.block(ofLine: line, in: text)

            // Quote bars, one per level of nesting.
            let quoteDepth = block.levels.dropLast().filter {
                $0.type == DocumentNodeType.blockquote
            }.count
            if quoteDepth > 0 {
                result.append(DocumentDecoration(line: index, kind: .quoteBar(depth: quoteDepth)))
            }

            if DocumentNodeType.isCodeBlock(block.leafType) {
                result.append(DocumentDecoration(line: index, kind: .codeBlock))
            }

            if DocumentNodeType.atomics.contains(block.leafType),
               ["horizontalRule", "horizontal_rule"].contains(block.leafType) {
                result.append(DocumentDecoration(line: index, kind: .thematicBreak))
            }

            // A list marker belongs to the item, not to every block inside it: an item holding two
            // paragraphs gets one bullet, against its first line.
            if let item = block.listItem, let list = block.enclosingList {
                defer { previousItemID = item.id }
                guard previousItemID != item.id else { continue }

                let depth = max(0, block.listDepth - 1)
                switch list.type {
                case "orderedList", "ordered_list":
                    let ordinal = item.ordinal ?? (list.attrs?["start"]?.intValue ?? 1)
                    result.append(DocumentDecoration(line: index,
                                                     kind: .orderedMarker("\(ordinal).", depth: depth)))
                case "taskList", "task_list":
                    let checked = item.attrs?["checked"]?.boolValue ?? false
                    result.append(DocumentDecoration(line: index,
                                                     kind: .checkbox(checked: checked, depth: depth)))
                default:
                    result.append(DocumentDecoration(line: index, kind: .bullet(depth: depth)))
                }
            } else {
                previousItemID = nil
            }
        }

        return result
    }

    /// The content range of every line, in order.
    static func lineRanges(in text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var result: [NSRange] = []
        var start = 0

        while start <= string.length {
            let searchRange = NSRange(location: start, length: string.length - start)
            let separator = string.range(of: DocumentProjection.blockSeparator,
                                         options: [], range: searchRange)
            let end = separator.location == NSNotFound ? string.length : separator.location
            result.append(NSRange(location: start, length: end - start))
            if separator.location == NSNotFound { break }
            start = NSMaxRange(separator)
        }

        return result
    }

    // MARK: - Geometry

    /// How far in a marker's column starts, for a line nested `depth` lists deep.
    static func markerIndent(depth: Int) -> CGFloat {
        DocumentStyle.indentWidth * CGFloat(depth + 1) - DocumentStyle.listMarkerWidth
    }

    /// Padding around a code block's panel.
    static let codeBlockPadding: CGFloat = 8
    static let codeBlockCornerRadius: CGFloat = 6
}
