import Foundation

// MARK: - FoldableRegion

/// A stretch of the document the editor can collapse — Phase 2 — Editor Improvements,
/// "Code folding".
struct FoldableRegion: Equatable, Identifiable {

    enum Kind: Equatable {
        /// A heading and everything under it, up to the next heading of the same or shallower level.
        case section(level: Int)
        /// A code block.
        case codeBlock
        /// A run of list items at the same depth.
        case list
    }

    /// 0-based line the fold starts on — the heading, or the block's first line. Stays visible when
    /// the region is folded.
    let startLine: Int
    /// 0-based last line of the region, inclusive. Hidden when folded.
    let endLine: Int
    let kind: Kind
    /// Text shown in place of the hidden lines.
    let summary: String

    var id: Int { startLine }

    /// The lines hidden when this region is folded — everything after the header line.
    var hiddenLines: ClosedRange<Int>? {
        guard endLine > startLine else { return nil }
        return (startLine + 1)...endLine
    }

    var lineCount: Int { endLine - startLine + 1 }
}

// MARK: - CodeFolding

/// Finds the foldable regions of a document.
///
/// Read from the block structure rather than from syntax: a section is a `heading` node and the
/// blocks that follow it, and a list is a run of lines sharing a list container. There is no fence
/// to match and no indentation to count, so a `#` inside a code block cannot be mistaken for a
/// section — it is text inside a `codeBlock` node, and nothing about it looks like a heading.
///
/// Pure and line-based, matching how the editor's gutter works: the caller gets ranges of line
/// numbers and decides what to do with them. Regions can nest (a list inside a section) and the
/// resolver below handles what stays hidden when several are folded at once.
enum CodeFolding {

    // MARK: - Discovery

    /// The foldable regions of a projected document.
    static func regions(in text: NSAttributedString) -> [FoldableRegion] {
        guard text.length > 0 else { return [] }

        let lines = DocumentDecorations.lineRanges(in: text)
        let blocks = lines.map { EditorDocumentState.block(ofLine: $0, in: text) }
        guard !blocks.isEmpty else { return [] }

        var regions: [FoldableRegion] = []
        regions.append(contentsOf: sectionRegions(blocks))
        regions.append(contentsOf: listRegions(blocks))

        return regions.sorted { $0.startLine < $1.startLine }
    }

    // MARK: - Sections

    /// A heading folds everything down to the next heading of the same or a shallower level.
    private static func sectionRegions(_ blocks: [DocumentBlock]) -> [FoldableRegion] {
        var headings: [(line: Int, level: Int)] = []

        for (index, block) in blocks.enumerated() where DocumentNodeType.isHeading(block.leafType) {
            headings.append((index, block.attrs?["level"]?.intValue ?? 1))
        }

        var regions: [FoldableRegion] = []

        for (position, heading) in headings.enumerated() {
            // Scan forward for the next heading at this level or shallower.
            var end = blocks.count - 1
            for next in headings[(position + 1)...] where next.level <= heading.level {
                end = next.line - 1
                break
            }

            guard end > heading.line else { continue }
            let hidden = end - heading.line
            regions.append(FoldableRegion(
                startLine: heading.line,
                endLine: end,
                kind: .section(level: heading.level),
                summary: "\(hidden) \(hidden == 1 ? "line" : "lines")"
            ))
        }

        return regions
    }

    // MARK: - Lists

    /// A run of lines sharing the same outermost list folds to its first item.
    private static func listRegions(_ blocks: [DocumentBlock]) -> [FoldableRegion] {
        var regions: [FoldableRegion] = []
        var index = 0

        while index < blocks.count {
            guard let list = blocks[index].levels.first(where: { DocumentNodeType.isList($0.type) })
            else {
                index += 1
                continue
            }

            var end = index
            while end + 1 < blocks.count,
                  blocks[end + 1].levels.contains(where: { $0.isSameInstance(as: list) }) {
                end += 1
            }

            // Two items at least, or there is nothing to collapse.
            if end > index {
                let hidden = end - index
                regions.append(FoldableRegion(
                    startLine: index,
                    endLine: end,
                    kind: .list,
                    summary: "\(hidden) \(hidden == 1 ? "item" : "items")"
                ))
            }
            index = end + 1
        }

        return regions
    }

    // MARK: - Resolution

    /// The set of line numbers hidden by a given set of folded region starts.
    ///
    /// Folding an outer section hides the inner ones whether or not they are folded themselves, so
    /// this is a union rather than a per-region calculation.
    static func hiddenLines(folding foldedStartLines: Set<Int>,
                            regions: [FoldableRegion]) -> Set<Int> {
        var hidden = Set<Int>()
        for region in regions where foldedStartLines.contains(region.startLine) {
            guard let range = region.hiddenLines else { continue }
            hidden.formUnion(range)
        }
        return hidden
    }
}
