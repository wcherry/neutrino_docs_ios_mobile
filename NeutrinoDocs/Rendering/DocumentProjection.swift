import Foundation
import UIKit

// MARK: - DocumentProjection

/// Flattens a ProseMirror document into the attributed string the editor holds.
///
/// The projection is the whole of what the user edits: there is no source syntax behind it and no
/// second representation to keep in step. `DocumentBuilder` reads it back, and the two are required
/// to be inverses — a document that survives `attributedString(from:)` then `document(from:)`
/// unchanged is the property every other guarantee in the editor rests on.
///
/// ## The shape of the text
///
/// One line per block, blocks separated by `\n`, and the separator belongs to the block it follows.
/// Everything a line needs to be rebuilt is on its characters:
///
/// - `.documentBlock` — the block and its ancestry, so nesting survives.
/// - `.documentMarks` — the inline marks, so bold survives.
/// - `.documentNode` — for the single character an atomic node projects to.
///
/// Two characters are given a meaning of their own. `U+2028` is a break *inside* a block: a
/// `hardBreak` in a paragraph, and a newline within a code block's text — neither of which may
/// split the line, since a line is a block. `U+FFFC` is an atomic node, and always carries
/// `.documentNode`.
enum DocumentProjection {

    // MARK: - Characters

    /// Separates blocks. The only character the builder splits on.
    static let blockSeparator = "\n"

    /// A break within a block — a `hardBreak`, or a newline inside a code block.
    static let lineBreak = "\u{2028}"

    /// Stands in for an atomic node. `NSTextAttachment`'s character, so UIKit lays out the space.
    static let atom = "\u{FFFC}"

    // MARK: - Projection

    /// Projects a `doc` node, or any node holding blocks, into styled text.
    static func attributedString(from doc: ProseMirrorNode, style: DocumentStyle) -> NSAttributedString {
        var projector = Projector(style: style)
        projector.appendBlocks(doc.children, ancestry: [])
        return projector.finish()
    }

    // MARK: - Kind

    enum Kind {
        /// Holds other blocks; becomes a level of ancestry.
        case container
        /// Holds inline content; becomes one line.
        case textBlock
        /// Holds nothing; becomes one character.
        case atom
    }

    /// What a node is, falling back to its shape when the type is one this app has never heard of.
    ///
    /// The fallback is what lets a document from a newer web release open at all: an unknown node
    /// wrapping paragraphs is treated as a quote-like container and its children still appear,
    /// rather than the whole subtree vanishing.
    static func kind(of node: ProseMirrorNode) -> Kind {
        if DocumentNodeType.textBlocks.contains(node.type) { return .textBlock }
        if DocumentNodeType.containers.contains(node.type) { return .container }
        if DocumentNodeType.atomics.contains(node.type) { return .atom }

        let children = node.children
        guard !children.isEmpty else { return .atom }
        let holdsInline = children.contains {
            $0.type == DocumentNodeType.text || DocumentNodeType.inlineAtomics.contains($0.type)
        }
        return holdsInline ? .textBlock : .container
    }

    // MARK: - Projector

    private struct Projector {

        let style: DocumentStyle
        private var output = NSMutableAttributedString()
        private var nextID = 0

        init(style: DocumentStyle) {
            self.style = style
        }

        /// Ids only have to be unique within one projection: they distinguish two adjacent lists
        /// from one, and nothing outside a single attributed string ever compares them.
        private mutating func makeID() -> Int {
            nextID += 1
            return nextID
        }

        // MARK: Blocks

        mutating func appendBlocks(_ nodes: [ProseMirrorNode],
                                   ancestry: [DocumentBlock.Level],
                                   ordinalStart: Int? = nil) {
            for (index, node) in nodes.enumerated() {
                let ordinal = ordinalStart.map { $0 + index }

                switch DocumentProjection.kind(of: node) {
                case .container:
                    let level = DocumentBlock.Level(type: node.type, attrs: node.attrs,
                                                    id: makeID(), ordinal: ordinal)
                    let childOrdinals = DocumentNodeType.isOrderedList(node.type)
                        ? (node.attribute("start")?.intValue ?? 1)
                        : nil
                    appendBlocks(node.children, ancestry: ancestry + [level],
                                 ordinalStart: childOrdinals)

                case .textBlock:
                    let level = DocumentBlock.Level(type: node.type, attrs: node.attrs,
                                                    id: makeID(), ordinal: ordinal)
                    appendLine(node, block: DocumentBlock(ancestry + [level]))

                case .atom:
                    // An atomic block still occupies a line of its own, so a rule or an embed can
                    // be selected, deleted, and typed after like any other paragraph.
                    let level = DocumentBlock.Level(type: node.type, attrs: node.attrs,
                                                    id: makeID(), ordinal: ordinal)
                    let block = DocumentBlock(ancestry + [level])
                    append(DocumentProjection.atom,
                           attributes: style.attributes(for: block)
                               .merging([.documentBlock: block,
                                         .documentNode: DocumentAtom(node)]) { _, new in new })
                    appendSeparator(block: block)
                }
            }
        }

        /// One text block: its inline content, then the separator that ends the line.
        private mutating func appendLine(_ node: ProseMirrorNode, block: DocumentBlock) {
            if DocumentNodeType.isCodeBlock(block.leafType) {
                // A code block's newlines live inside its text node. They are breaks within the
                // block, not block separators, so they project as `U+2028` like a hard break.
                let code = node.children.compactMap(\.text).joined()
                    .replacingOccurrences(of: "\n", with: DocumentProjection.lineBreak)
                append(code, attributes: style.attributes(for: block)
                    .merging([.documentBlock: block]) { _, new in new })
            } else {
                appendInline(node.children, block: block)
            }
            appendSeparator(block: block)
        }

        /// The `\n` that ends a line, carrying the line's own attributes.
        ///
        /// It belongs to the block it follows, which is what gives an empty block in the middle of
        /// a document a character to hang its identity on.
        private mutating func appendSeparator(block: DocumentBlock) {
            append(DocumentProjection.blockSeparator,
                   attributes: style.attributes(for: block)
                       .merging([.documentBlock: block]) { _, new in new })
        }

        // MARK: Inline

        private mutating func appendInline(_ nodes: [ProseMirrorNode], block: DocumentBlock) {
            let base = style.attributes(for: block)
                .merging([.documentBlock: block]) { _, new in new }

            for node in nodes {
                let marks = DocumentMarks(node.marks ?? [])
                var attributes = marks.isEmpty ? base : style.applying(marks, to: base)
                if !marks.isEmpty {
                    attributes[.documentMarks] = marks
                }

                switch node.type {
                case DocumentNodeType.text:
                    // A newline inside a text node would split the line and so change the
                    // document's structure; it becomes a break within the block instead.
                    let text = (node.text ?? "")
                        .replacingOccurrences(of: "\n", with: DocumentProjection.lineBreak)
                    append(text, attributes: attributes)

                case let type where DocumentNodeType.isHardBreak(type):
                    append(DocumentProjection.lineBreak, attributes: attributes)

                default:
                    attributes[.documentNode] = DocumentAtom(node)
                    append(DocumentProjection.atom, attributes: attributes)
                }
            }
        }

        // MARK: Output

        private mutating func append(_ string: String,
                                     attributes: [NSAttributedString.Key: Any]) {
            guard !string.isEmpty else { return }
            output.append(NSAttributedString(string: string, attributes: attributes))
        }

        /// Drops the separator after the final block: a document does not end with a blank line
        /// unless it really ends with an empty block.
        mutating func finish() -> NSAttributedString {
            if output.length > 0,
               output.attributedSubstring(from: NSRange(location: output.length - 1, length: 1))
                   .string == DocumentProjection.blockSeparator {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
            return output
        }
    }
}
