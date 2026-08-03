import Foundation

// MARK: - FoldableRegion

/// A stretch of source the editor can collapse — Phase 2 — Editor Improvements, "Code folding".
struct FoldableRegion: Equatable, Identifiable {

    enum Kind: Equatable {
        /// A heading and everything under it, up to the next heading of the same or shallower level.
        case section(level: Int)
        /// A fenced code block, including both fences.
        case codeBlock
        /// A run of list items at the same indent.
        case list
    }

    /// 0-based line the fold starts on — the heading, or the opening fence. Stays visible when the
    /// region is folded.
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

/// Finds the foldable regions in Markdown source.
///
/// Pure and line-based, matching how the editor's gutter works: the caller gets ranges of line
/// numbers and decides what to do with them. Regions can nest (a code block inside a section) and
/// the resolver below handles what stays hidden when several are folded at once.
enum CodeFolding {

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^\s{0,3}(#{1,6})\s+(.*)$"#
    )

    // MARK: - Discovery

    static func regions(in source: String) -> [FoldableRegion] {
        guard !source.isEmpty else { return [] }
        let lines = source.components(separatedBy: "\n")

        var regions: [FoldableRegion] = []
        regions.append(contentsOf: codeBlockRegions(lines))
        regions.append(contentsOf: sectionRegions(lines, fenced: fencedLines(lines)))

        return regions.sorted { $0.startLine < $1.startLine }
    }

    // MARK: - Code blocks

    /// The set of lines inside (or delimiting) a fenced code block, so headings there are ignored.
    private static func fencedLines(_ lines: [String]) -> Set<Int> {
        var result = Set<Int>()
        var openIndex: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { continue }
            if let start = openIndex {
                for line in start...index { result.insert(line) }
                openIndex = nil
            } else {
                openIndex = index
            }
        }

        // An unterminated fence runs to the end of the document, which is what cmark assumes too.
        if let start = openIndex {
            for line in start..<lines.count { result.insert(line) }
        }

        return result
    }

    private static func codeBlockRegions(_ lines: [String]) -> [FoldableRegion] {
        var regions: [FoldableRegion] = []
        var openIndex: Int?
        var language = ""

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { continue }

            if let start = openIndex {
                if index > start + 1 {
                    regions.append(FoldableRegion(
                        startLine: start,
                        endLine: index,
                        kind: .codeBlock,
                        summary: summary(language: language, lines: index - start - 1)
                    ))
                }
                openIndex = nil
                language = ""
            } else {
                openIndex = index
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }

        if let start = openIndex, lines.count - 1 > start + 1 {
            regions.append(FoldableRegion(
                startLine: start,
                endLine: lines.count - 1,
                kind: .codeBlock,
                summary: summary(language: language, lines: lines.count - 1 - start)
            ))
        }

        return regions
    }

    private static func summary(language: String, lines: Int) -> String {
        let plural = lines == 1 ? "line" : "lines"
        return language.isEmpty ? "\(lines) \(plural)" : "\(language) — \(lines) \(plural)"
    }

    // MARK: - Sections

    /// A heading folds everything down to the next heading of the same or a shallower level.
    private static func sectionRegions(_ lines: [String], fenced: Set<Int>) -> [FoldableRegion] {
        var headings: [(line: Int, level: Int, title: String)] = []

        for (index, line) in lines.enumerated() where !fenced.contains(index) {
            let nsLine = line as NSString
            guard let match = headingRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: nsLine.length)
            ) else { continue }
            headings.append((index,
                             match.range(at: 1).length,
                             nsLine.substring(with: match.range(at: 2))
                                .trimmingCharacters(in: .whitespaces)))
        }

        var regions: [FoldableRegion] = []

        for (position, heading) in headings.enumerated() {
            // Scan forward for the next heading at this level or shallower.
            var end = lines.count - 1
            for next in headings[(position + 1)...] where next.level <= heading.level {
                end = next.line - 1
                break
            }

            // Trailing blank lines belong to the gap between sections, not to the section.
            while end > heading.line,
                  lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
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

    /// Applies folds to source for display: hidden lines are dropped and each folded header gets
    /// its summary appended.
    ///
    /// Used by the editor's gutter preview rather than by the text storage — folding the real text
    /// would change what a save writes.
    static func displayLines(for source: String,
                             folding foldedStartLines: Set<Int>,
                             regions: [FoldableRegion]) -> [String] {
        let lines = source.components(separatedBy: "\n")
        let hidden = hiddenLines(folding: foldedStartLines, regions: regions)
        let summaries = Dictionary(regions.map { ($0.startLine, $0.summary) },
                                   uniquingKeysWith: { first, _ in first })

        var result: [String] = []
        for (index, line) in lines.enumerated() {
            if hidden.contains(index) { continue }
            if foldedStartLines.contains(index), let summary = summaries[index] {
                result.append("\(line)  ⋯ \(summary)")
            } else {
                result.append(line)
            }
        }
        return result
    }
}
