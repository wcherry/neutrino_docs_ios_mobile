import Foundation

// MARK: - DocumentOutline

/// The heading tree behind Phase 2's Document Outline — "Heading navigation", "Collapse sections",
/// "Search headings".
///
/// Built from the projected document — the styled text the editor is showing — because that is the
/// only place both halves of what the outline needs exist at once: which blocks are headings, and
/// where in the text each one begins, so selecting one can move the caret there.
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

    // MARK: - Building

    /// Builds the outline from a document as the editor holds it.
    ///
    /// A heading is a heading because the block says so, not because a line starts with `#`, so
    /// there is nothing here to be fooled by: a `#` comment inside a code block is text in a code
    /// block, and a `---` under a paragraph is a rule. And because the offsets are offsets into the
    /// very string the text view is showing, selecting a heading moves the caret exactly there —
    /// there is no source to map back from.
    static func outline(of text: NSAttributedString) -> DocumentOutline {
        guard text.length > 0 else { return .empty }

        let string = text.string as NSString
        var headings: [Heading] = []

        for (index, line) in EditorDocumentState.lines(in: text,
                                                       covering: NSRange(location: 0, length: text.length))
            .enumerated() {
            let block = EditorDocumentState.block(ofLine: line, in: text)
            let level = DocumentEditing.headingLevel(of: block)
            guard level > 0 else { continue }

            headings.append(Heading(id: headings.count,
                                    level: level,
                                    title: string.substring(with: line)
                                        .trimmingCharacters(in: .whitespaces),
                                    line: index,
                                    characterOffset: line.location,
                                    childIDs: [],
                                    parentID: nil))
        }

        return DocumentOutline(headings: link(headings))
    }

    /// The outline of a document that is not on screen — a stored body, or a version being
    /// previewed. Projected first, since a heading's offset only means anything against the text
    /// the editor would show.
    static func outline(of document: ProseMirrorNode, style: DocumentStyle) -> DocumentOutline {
        outline(of: DocumentProjection.attributedString(from: document, style: style))
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
