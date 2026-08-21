import Foundation
import UIKit

// MARK: - DocumentBuilder

/// Reads the editor's attributed string back into a ProseMirror document.
///
/// The inverse of ``DocumentProjection``. Nothing is inferred from how the text looks — the block
/// and mark attributes are the document, and the fonts and colours beside them are ignored. That is
/// what makes an edit lossless: a colour the phone cannot draw is still a `textStyle` mark on the
/// run, and comes back out as one.
enum DocumentBuilder {

    // MARK: - Building

    /// Builds the `doc` node from the editor's text.
    static func document(from attributed: NSAttributedString) -> ProseMirrorNode {
        let lines = self.lines(in: attributed)
        let blocks = nodes(from: lines, range: 0..<lines.count, depth: 0)
        return ProseMirrorNode(type: DocumentNodeType.doc, content: blocks)
    }

    // MARK: - Lines

    /// One projected block: where it sits in the tree, and the inline content it holds.
    private struct Line {
        let block: DocumentBlock
        let node: ProseMirrorNode
    }

    /// Splits the text on block separators and reads each line's block and content.
    private static func lines(in attributed: NSAttributedString) -> [Line] {
        let text = attributed.string as NSString
        var result: [Line] = []
        var start = 0

        while start <= text.length {
            let searchRange = NSRange(location: start, length: text.length - start)
            let separator = text.range(of: DocumentProjection.blockSeparator,
                                       options: [], range: searchRange)
            let end = separator.location == NSNotFound ? text.length : separator.location
            let content = NSRange(location: start, length: end - start)

            let block = self.block(at: content, in: attributed)
            result.append(Line(block: block, node: leaf(block, content: content, in: attributed)))

            if separator.location == NSNotFound { break }
            start = NSMaxRange(separator)
        }

        return result
    }

    /// The block a line belongs to.
    ///
    /// A line's own characters carry it, and an empty line in the middle of a document still has
    /// the separator that ends it. Only a document ending in an empty line has nothing to read, and
    /// that line takes the block of the one before it — which is what continuing a list by pressing
    /// Return at the end of a document should do anyway.
    private static func block(at content: NSRange, in attributed: NSAttributedString) -> DocumentBlock {
        guard attributed.length > 0 else { return defaultBlock }
        let index = min(content.location, attributed.length - 1)
        let found = attributed.attribute(.documentBlock, at: index, effectiveRange: nil)
        let block = (found as? DocumentBlock) ?? defaultBlock

        // An empty line cannot be an atomic block: a rule or an embed always projects to exactly
        // the one character standing in for it. Only the inherited block of a trailing empty line
        // can be atomic, and taking it at its word would emit a second copy of the node above.
        if content.length == 0, DocumentNodeType.atomics.contains(block.leafType) {
            return block.replacingLeaf(type: DocumentNodeType.paragraph, attrs: nil)
        }

        return block
    }

    private static var defaultBlock: DocumentBlock {
        DocumentBlock([DocumentBlock.Level(type: DocumentNodeType.paragraph, id: 0)])
    }

    /// The node for one line — its leaf type, its attributes, and its inline children.
    private static func leaf(_ block: DocumentBlock,
                             content: NSRange,
                             in attributed: NSAttributedString) -> ProseMirrorNode {
        // A block that is itself atomic — a rule, an embed — projected to a single character
        // holding the whole node. It comes back as that node rather than as a block wrapping it.
        if let atom = atomicBlock(at: content, in: attributed, block: block) {
            return atom
        }

        let children = DocumentNodeType.isCodeBlock(block.leafType)
            ? codeContent(in: content, of: attributed)
            : inlineNodes(in: content, of: attributed)

        // ProseMirror rejects `content: []` on a node whose schema wants inline content, so an
        // empty block carries no content key at all.
        return ProseMirrorNode(type: block.leafType,
                               attrs: block.attrs,
                               content: children.isEmpty ? nil : children)
    }

    /// The node of an atomic block, if that is what this line is.
    ///
    /// Recognised by the line being exactly the one character the node projected to, and by that
    /// node being the line's own block — an inline picture inside a paragraph is the same single
    /// character, but its block is the paragraph, so it is inline content and not this.
    private static func atomicBlock(at content: NSRange,
                                    in attributed: NSAttributedString,
                                    block: DocumentBlock) -> ProseMirrorNode? {
        guard content.length == 1 else { return nil }
        guard let atom = attributed.attribute(.documentNode, at: content.location,
                                              effectiveRange: nil) as? DocumentAtom else {
            return nil
        }
        return atom.node.type == block.leafType ? atom.node : nil
    }

    // MARK: - Inline content

    /// A code block's text, with its breaks turned back into the newlines it stores.
    private static func codeContent(in range: NSRange,
                                    of attributed: NSAttributedString) -> [ProseMirrorNode] {
        guard range.length > 0 else { return [] }
        let code = (attributed.string as NSString).substring(with: range)
            .replacingOccurrences(of: DocumentProjection.lineBreak, with: "\n")
        guard !code.isEmpty else { return [] }
        return [.text(code)]
    }

    /// Walks the runs of one line, turning each back into the node it was projected from.
    private static func inlineNodes(in range: NSRange,
                                    of attributed: NSAttributedString) -> [ProseMirrorNode] {
        guard range.length > 0 else { return [] }
        var result: [ProseMirrorNode] = []

        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            let marks = (attributes[.documentMarks] as? DocumentMarks)?.marks ?? []

            // An atomic node was projected whole, so it goes back whole rather than being rebuilt
            // from the single character standing in for it.
            if let atom = attributes[.documentNode] as? DocumentAtom {
                result.append(atom.node)
                return
            }

            let text = (attributed.string as NSString).substring(with: runRange)
            result.append(contentsOf: self.inlineNodes(fromText: text, marks: marks))
        }

        return coalesced(result)
    }

    /// Splits a run on its intra-block breaks, which are `hardBreak` nodes between text.
    private static func inlineNodes(fromText text: String,
                                    marks: [ProseMirrorMark]) -> [ProseMirrorNode] {
        let segments = text.components(separatedBy: DocumentProjection.lineBreak)
        var result: [ProseMirrorNode] = []

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(ProseMirrorNode(type: DocumentNodeType.hardBreak))
            }
            guard !segment.isEmpty else { continue }
            result.append(.text(segment, marks: marks.isEmpty ? nil : marks))
        }

        return result
    }

    /// Merges neighbouring text nodes carrying the same marks.
    ///
    /// Runs are split by presentation as well as by marks — a re-projection can leave two runs
    /// where the document has one text node — and a document whose text nodes were split
    /// differently each save would show a spurious change on every sync.
    private static func coalesced(_ nodes: [ProseMirrorNode]) -> [ProseMirrorNode] {
        var result: [ProseMirrorNode] = []

        for node in nodes {
            guard node.type == DocumentNodeType.text,
                  var previous = result.last,
                  previous.type == DocumentNodeType.text,
                  previous.marks == node.marks else {
                result.append(node)
                continue
            }
            previous.text = (previous.text ?? "") + (node.text ?? "")
            result[result.count - 1] = previous
        }

        return result
    }

    // MARK: - Tree

    /// Regroups a flat run of lines into the tree their ancestries describe.
    ///
    /// At each depth, consecutive lines sharing the same container *instance* become its children.
    /// Sharing the type alone is not enough: two adjacent bulleted lists would otherwise be rebuilt
    /// as one, which is why a level carries an id.
    private static func nodes(from lines: [Line],
                              range: Range<Int>,
                              depth: Int) -> [ProseMirrorNode] {
        var result: [ProseMirrorNode] = []
        var index = range.lowerBound

        while index < range.upperBound {
            let levels = lines[index].block.levels

            // The line's own block: nothing left to nest it in.
            guard depth < levels.count - 1 else {
                result.append(lines[index].node)
                index += 1
                continue
            }

            let container = levels[depth]
            var end = index + 1
            while end < range.upperBound {
                let other = lines[end].block.levels
                guard other.count - 1 > depth,
                      other[depth].isSameInstance(as: container) else { break }
                end += 1
            }

            let children = nodes(from: lines, range: index..<end, depth: depth + 1)
            result.append(ProseMirrorNode(type: container.type,
                                          attrs: container.attrs,
                                          content: children.isEmpty ? nil : children))
            index = end
        }

        return result
    }
}
