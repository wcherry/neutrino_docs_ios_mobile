import Foundation

// MARK: - DocumentOutline

/// The heading tree behind Phase 2's Document Outline — "Heading navigation", "Collapse sections",
/// "Search headings".
///
/// Built from Markdown *source* rather than from a parsed `MarkdownDocumentModel`, for two reasons:
/// the outline has to work in Edit mode, where there is no rendered document to walk; and it needs
/// each heading's line number so selecting one can move the editor's caret there.
///
/// Pure data, so the nesting, the numbering, and the search are all asserted directly in tests.
struct DocumentOutline: Equatable {

    // MARK: - Heading

    struct Heading: Equatable, Identifiable {
        /// Position among all headings, in document order. Doubles as the scroll anchor, which is
        /// why it is an ordinal rather than a slug — two headings can share a title.
        let id: Int
        let level: Int
        let title: String
        /// 0-based line in the source.
        let line: Int
        /// UTF-16 offset of the start of the heading's line, for moving the editor's selection.
        let characterOffset: Int
        /// Ids of the headings nested under this one, in document order.
        var childIDs: [Int]
        /// Id of the enclosing heading, or `nil` at the top level.
        var parentID: Int?
    }

    let headings: [Heading]

    static let empty = DocumentOutline(headings: [])

    var isEmpty: Bool { headings.isEmpty }

    func heading(id: Int) -> Heading? {
        headings.first { $0.id == id }
    }

    /// The anchor a rendered heading uses so the outline can scroll to it.
    static func anchorID(forHeadingAt ordinal: Int) -> String {
        "heading-\(ordinal)"
    }

    var anchorIDsByHeading: [Int: String] {
        Dictionary(uniqueKeysWithValues: headings.map { ($0.id, Self.anchorID(forHeadingAt: $0.id)) })
    }

    // MARK: - Parsing

    private static let atxHeadingRegex = try! NSRegularExpression(
        pattern: #"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#
    )

    /// Builds the outline from Markdown source.
    ///
    /// ATX headings (`## Title`) and Setext headings (a line underlined with `===` or `---`) are
    /// both recognized. Headings inside fenced code blocks are skipped — a `#` comment in a shell
    /// snippet is not a section — and so is a leading front-matter block, whose `---` terminator
    /// would otherwise read as a Setext underline.
    static func parse(_ source: String) -> DocumentOutline {
        guard !source.isEmpty else { return .empty }

        let lines = source.components(separatedBy: "\n")
        var headings: [Heading] = []
        var insideFence = false
        var offset = 0
        var lineOffsets: [Int] = []

        // Character offsets are precomputed so a heading can report where its line starts.
        for line in lines {
            lineOffsets.append(offset)
            offset += (line as NSString).length + 1   // +1 for the newline
        }

        let frontMatterEnd = frontMatterEndLine(lines)

        for (index, line) in lines.enumerated() {
            if index <= frontMatterEnd { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence else { continue }

            let nsLine = line as NSString
            if let match = atxHeadingRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: nsLine.length)
            ) {
                let level = match.range(at: 1).length
                let title = nsLine.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                headings.append(Heading(id: headings.count,
                                        level: level,
                                        title: title,
                                        line: index,
                                        characterOffset: lineOffsets[index],
                                        childIDs: [],
                                        parentID: nil))
                continue
            }

            // Setext: the *previous* line is the title, underlined by this one.
            if index > 0, let level = setextLevel(trimmed) {
                let titleLine = lines[index - 1].trimmingCharacters(in: .whitespaces)
                guard !titleLine.isEmpty, !isBlockStructure(titleLine) else { continue }
                headings.append(Heading(id: headings.count,
                                        level: level,
                                        title: titleLine,
                                        line: index - 1,
                                        characterOffset: lineOffsets[index - 1],
                                        childIDs: [],
                                        parentID: nil))
            }
        }

        return DocumentOutline(headings: link(headings))
    }

    /// A `---`/`===` run underlines the line above it. `---` is ambiguous with a thematic break;
    /// CommonMark resolves it in favour of the heading when there is a paragraph above, which is
    /// what `isBlockStructure` checks for at the call site.
    private static func setextLevel(_ trimmed: String) -> Int? {
        guard trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Lines that cannot be a Setext title — a list item, a quote, another heading, or a fence.
    private static func isBlockStructure(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("```")
            || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("|")
    }

    /// The last line of a leading front-matter block, or -1 when there is none.
    private static func frontMatterEndLine(_ lines: [String]) -> Int {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == "---" || first == "+++" else { return -1 }
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == first {
            return index
        }
        return -1
    }

    // MARK: - Nesting

    /// Links each heading to its parent using a level stack, so `###` under `##` under `#` nests
    /// even when levels are skipped (a `####` directly under a `##` still attaches to it).
    private static func link(_ flat: [Heading]) -> [Heading] {
        var headings = flat
        var stack: [Int] = []   // indices of open ancestors, shallowest first

        for index in headings.indices {
            // Pop until the top of the stack is shallower than this heading.
            while let last = stack.last, headings[last].level >= headings[index].level {
                stack.removeLast()
            }
            if let parent = stack.last {
                headings[index].parentID = headings[parent].id
                headings[parent].childIDs.append(headings[index].id)
            }
            stack.append(index)
        }

        return headings
    }

    // MARK: - Search

    /// Case- and diacritic-insensitive substring match over heading titles — Phase 2 — Document
    /// Outline, "Search headings".
    ///
    /// Returns matching headings *plus* their ancestors, so a match nested three levels deep is
    /// still reachable through its parents rather than appearing as an orphan.
    func filtered(by query: String) -> [Heading] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return headings }

        var keep = Set<Int>()
        for heading in headings where heading.title.range(
            of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil {
            keep.insert(heading.id)
            var parent = heading.parentID
            while let id = parent {
                keep.insert(id)
                parent = self.heading(id: id)?.parentID
            }
        }

        return headings.filter { keep.contains($0.id) }
    }

    /// Ids of every heading beneath `id`, at any depth — what a collapsed section hides.
    func descendantIDs(of id: Int) -> [Int] {
        guard let heading = heading(id: id) else { return [] }
        var result: [Int] = []
        for child in heading.childIDs {
            result.append(child)
            result.append(contentsOf: descendantIDs(of: child))
        }
        return result
    }

    /// The visible headings given a set of collapsed sections — Phase 2 — "Collapse sections".
    func visibleHeadings(collapsed: Set<Int>) -> [Heading] {
        var hidden = Set<Int>()
        for id in collapsed {
            hidden.formUnion(descendantIDs(of: id))
        }
        return headings.filter { !hidden.contains($0.id) }
    }
}
