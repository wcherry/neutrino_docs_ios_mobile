import Foundation
import Markdown

// MARK: - MarkdownParser

/// Parses raw Markdown source into a `MarkdownDocumentModel`.
///
/// Wraps `swift-markdown`'s `Document(parsing:)` — CommonMark plus the GFM extensions (tables,
/// strikethrough, task lists) that its bundled cmark-gfm backend enables by default — and adds a
/// hand-rolled pre/post-processing pass for footnotes, which are not part of GFM and would
/// otherwise survive as inert literal text.
enum MarkdownParser {

    /// Internal URL scheme used to smuggle footnote references through cmark as ordinary links.
    /// Namespaced to this app so it cannot collide with a real link in somebody's document.
    static let footnoteScheme = "ndoc-footnote://"

    private static let footnoteDefinitionRegex = try! NSRegularExpression(
        pattern: #"^\[\^([^\]]+)\]:\s?(.*)$"#
    )

    private static let footnoteReferenceRegex = try! NSRegularExpression(
        pattern: #"\[\^([^\]]+)\]"#
    )

    // MARK: - Entry point

    static func parse(_ source: String) -> MarkdownDocumentModel {
        guard !source.isEmpty else { return .empty }

        let (bodyWithoutDefinitions, definitions) = extractFootnoteDefinitions(from: source)
        let definitionsByLabel = Dictionary(definitions.map { ($0.label, $0.text) },
                                            uniquingKeysWith: { first, _ in first })

        let (rewrittenBody, indexByLabel, referencedCount) = rewriteFootnoteReferences(
            in: bodyWithoutDefinitions,
            knownLabels: definitionsByLabel
        )

        let document = Document(parsing: rewrittenBody)
        let blocks = convertBlocks(document.children, indexByLabel: indexByLabel)
        let footnotes = buildFootnotes(definitions: definitions,
                                       indexByLabel: indexByLabel,
                                       referencedCount: referencedCount)

        return MarkdownDocumentModel(blocks: blocks, footnotes: footnotes)
    }

    // MARK: - Footnote pre-processing

    /// Extracts footnote definition lines (`[^label]: text`), returning the source with those lines
    /// stripped and the definitions in the order they appeared.
    private static func extractFootnoteDefinitions(
        from source: String
    ) -> (body: String, definitions: [(label: String, text: String)]) {
        var definitions: [(label: String, text: String)] = []
        var seenLabels = Set<String>()
        var remainingLines: [String] = []

        for line in source.components(separatedBy: "\n") {
            let fullRange = NSRange(line.startIndex..., in: line)
            if let match = footnoteDefinitionRegex.firstMatch(in: line, options: [], range: fullRange) {
                let label = substring(line, match: match, group: 1)
                let text = substring(line, match: match, group: 2)
                // First definition wins; a duplicate label is a typo, not a second footnote.
                if !seenLabels.contains(label) {
                    definitions.append((label, text))
                    seenLabels.insert(label)
                }
                continue
            }
            remainingLines.append(line)
        }

        return (remainingLines.joined(separator: "\n"), definitions)
    }

    /// Rewrites in-body `[^label]` references — only those with a matching definition — into real
    /// CommonMark links, so cmark parses them as ordinary `Link` nodes.
    ///
    /// Indices are assigned in order of first appearance, left to right and top to bottom, which is
    /// what a reader expects the numbering to follow.
    private static func rewriteFootnoteReferences(
        in body: String,
        knownLabels: [String: String]
    ) -> (rewritten: String, indexByLabel: [String: Int], referencedCount: Int) {
        let nsBody = body as NSString
        let matches = footnoteReferenceRegex.matches(
            in: body, options: [], range: NSRange(location: 0, length: nsBody.length)
        )

        var indexByLabel: [String: Int] = [:]
        var nextIndex = 1
        var replacements: [(range: NSRange, label: String)] = []

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let label = nsBody.substring(with: match.range(at: 1))
            // A reference with no definition is left as literal text, matching how other Markdown
            // renderers treat it.
            guard knownLabels[label] != nil else { continue }
            if indexByLabel[label] == nil {
                indexByLabel[label] = nextIndex
                nextIndex += 1
            }
            replacements.append((match.range, label))
        }

        let mutableBody = NSMutableString(string: body)
        // Applied back to front so each replacement cannot shift the ranges of the ones after it.
        for (range, label) in replacements.reversed() {
            mutableBody.replaceCharacters(in: range, with: "[^\(label)](\(footnoteScheme)\(label))")
        }

        return (mutableBody as String, indexByLabel, indexByLabel.count)
    }

    /// Builds the final footnotes array, ordered by index. Referenced footnotes keep the index
    /// assigned by first appearance; unreferenced definitions are appended afterwards in their
    /// original order.
    private static func buildFootnotes(
        definitions: [(label: String, text: String)],
        indexByLabel: [String: Int],
        referencedCount: Int
    ) -> [MarkdownFootnote] {
        var indexByLabel = indexByLabel
        var nextIndex = referencedCount + 1

        var footnotes: [MarkdownFootnote] = []
        for (label, text) in definitions {
            let index: Int
            if let existing = indexByLabel[label] {
                index = existing
            } else {
                index = nextIndex
                indexByLabel[label] = index
                nextIndex += 1
            }
            footnotes.append(MarkdownFootnote(id: label, index: index, content: parseInlineOnly(text)))
        }

        return footnotes.sorted { $0.index < $1.index }
    }

    /// Parses a standalone run of text (a footnote body) purely for its inline formatting,
    /// discarding block structure.
    private static func parseInlineOnly(_ text: String) -> [MarkdownInline] {
        guard !text.isEmpty else { return [] }
        let document = Document(parsing: text)
        guard let paragraph = document.children.first(where: { $0 is Paragraph }) as? Paragraph else {
            return [.text(text)]
        }
        return convertInlines(paragraph.children, indexByLabel: [:])
    }

    private static func substring(_ string: String, match: NSTextCheckingResult, group: Int) -> String {
        guard let range = Range(match.range(at: group), in: string) else { return "" }
        return String(string[range])
    }

    // MARK: - Block conversion

    private static func convertBlocks(_ children: MarkupChildren,
                                      indexByLabel: [String: Int]) -> [MarkdownBlock] {
        children.compactMap { convertBlock($0, indexByLabel: indexByLabel) }
    }

    private static func convertBlock(_ markup: Markup, indexByLabel: [String: Int]) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level,
                            inlines: convertInlines(heading.children, indexByLabel: indexByLabel))

        case let paragraph as Paragraph:
            return .paragraph(convertInlines(paragraph.children, indexByLabel: indexByLabel))

        case let list as UnorderedList:
            let items = Array(list.listItems).map { convertListItem($0, indexByLabel: indexByLabel) }
            return .list(MarkdownList(isOrdered: false, startIndex: nil, items: items))

        case let list as OrderedList:
            let items = Array(list.listItems).map { convertListItem($0, indexByLabel: indexByLabel) }
            return .list(MarkdownList(isOrdered: true, startIndex: Int(list.startIndex), items: items))

        case let table as Table:
            return .table(convertTable(table, indexByLabel: indexByLabel))

        case let codeBlock as CodeBlock:
            return .codeBlock(codeBlock.code, codeBlock.language)

        case let blockQuote as BlockQuote:
            return .blockQuote(convertBlocks(blockQuote.children, indexByLabel: indexByLabel))

        case is ThematicBreak:
            return .thematicBreak

        default:
            // Anything Phase 1 does not render (HTML blocks, custom directives) is dropped rather
            // than shown as raw source.
            return nil
        }
    }

    private static func convertListItem(_ item: ListItem, indexByLabel: [String: Int]) -> MarkdownListItem {
        MarkdownListItem(
            checkbox: convertCheckbox(item.checkbox),
            content: convertBlocks(item.children, indexByLabel: indexByLabel)
        )
    }

    private static func convertCheckbox(_ checkbox: Checkbox?) -> Bool? {
        switch checkbox {
        case .checked:   return true
        case .unchecked: return false
        case .none:      return nil
        }
    }

    private static func convertTable(_ table: Table, indexByLabel: [String: Int]) -> MarkdownTable {
        let alignments = table.columnAlignments.map(convertAlignment)
        let header: [[MarkdownInline]] = Array(table.head.cells).map {
            convertInlines($0.children, indexByLabel: indexByLabel)
        }
        let rows: [[[MarkdownInline]]] = Array(table.body.rows).map { row in
            Array(row.cells).map { convertInlines($0.children, indexByLabel: indexByLabel) }
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }

    private static func convertAlignment(_ alignment: Table.ColumnAlignment?) -> MarkdownTableColumnAlignment {
        switch alignment {
        case .none:   return .none
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }

    // MARK: - Inline conversion

    private static func convertInlines(_ children: MarkupChildren,
                                       indexByLabel: [String: Int]) -> [MarkdownInline] {
        children.compactMap { convertInline($0, indexByLabel: indexByLabel) }
    }

    private static func convertInline(_ markup: Markup, indexByLabel: [String: Int]) -> MarkdownInline? {
        switch markup {
        case let text as Text:
            return .text(text.string)

        case let emphasis as Emphasis:
            return .emphasis(convertInlines(emphasis.children, indexByLabel: indexByLabel))

        case let strong as Strong:
            return .strong(convertInlines(strong.children, indexByLabel: indexByLabel))

        case let strikethrough as Strikethrough:
            return .strikethrough(convertInlines(strikethrough.children, indexByLabel: indexByLabel))

        case let code as InlineCode:
            return .code(code.code)

        case let link as Link:
            if let destination = link.destination, destination.hasPrefix(footnoteScheme) {
                let label = String(destination.dropFirst(footnoteScheme.count))
                return .footnoteReference(label: label, index: indexByLabel[label] ?? 0)
            }
            return .link(inlines: convertInlines(link.children, indexByLabel: indexByLabel),
                         destination: link.destination ?? "")

        case let image as Image:
            let alt = Array(image.children).compactMap { ($0 as? InlineMarkup)?.plainText }.joined()
            return .image(alt: alt, source: image.source ?? "", title: image.title)

        case is SoftBreak:
            return .softBreak

        case is LineBreak:
            return .lineBreak

        default:
            return nil
        }
    }
}
