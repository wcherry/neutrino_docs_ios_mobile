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

        // Phase 2 — Rich Markdown, "Front matter". Taken off before anything else looks at the
        // text: a leading `---` block would otherwise parse as a thematic break plus a paragraph.
        let split = FeatureFlags.richMarkdown
            ? FrontMatterParser.split(source)
            : FrontMatterParser.Split(frontMatter: .empty, body: source)
        let frontMatter = split.frontMatter

        // Phase 2 — Rich Markdown, "Math". Display math is folded into a ```math fence before
        // cmark sees it, so a multi-line `$$…$$` survives as one block instead of becoming a
        // paragraph full of soft breaks.
        let bodyWithMathFences = FeatureFlags.richMarkdown
            ? rewriteDisplayMath(in: split.body)
            : split.body

        let (bodyWithoutDefinitions, definitions) = extractFootnoteDefinitions(from: bodyWithMathFences)
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

        return MarkdownDocumentModel(blocks: blocks,
                                     footnotes: footnotes,
                                     frontMatter: frontMatter)
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

    // MARK: - Callouts (Phase 2)

    private static let calloutMarkerRegex = try! NSRegularExpression(
        pattern: #"^\[!([A-Za-z]+)\]\s*(.*)$"#
    )

    /// Recognizes the GitHub callout form: a block quote whose first paragraph opens with
    /// `[!NOTE]`, optionally followed by a custom title on the same line.
    ///
    /// Returns `nil` for an ordinary block quote, and for an unknown keyword — `[!FOO]` is far more
    /// likely to be literal text the author wanted than a callout kind this app forgot.
    private static func calloutFromBlockQuote(_ blocks: [MarkdownBlock]) -> MarkdownCallout? {
        guard case .paragraph(let inlines)? = blocks.first,
              case .text(let leading)? = inlines.first else { return nil }

        let nsLeading = leading as NSString
        guard let match = calloutMarkerRegex.firstMatch(
            in: leading, range: NSRange(location: 0, length: nsLeading.length)
        ) else { return nil }

        guard let kind = MarkdownCalloutKind(token: nsLeading.substring(with: match.range(at: 1)))
        else { return nil }

        let trailing = nsLeading.substring(with: match.range(at: 2))
            .trimmingCharacters(in: .whitespaces)

        // Rebuild the first paragraph without the marker. What followed the marker on the same
        // line is the title; the paragraph's remaining inlines are body text.
        var remainingInlines = Array(inlines.dropFirst())
        // The line break that separated the marker line from the body is now leading whitespace.
        if case .softBreak? = remainingInlines.first {
            remainingInlines.removeFirst()
        }

        var content = Array(blocks.dropFirst())
        if !remainingInlines.isEmpty {
            content.insert(.paragraph(remainingInlines), at: 0)
        }

        return MarkdownCallout(kind: kind,
                               title: trailing.isEmpty ? nil : trailing,
                               content: content)
    }

    // MARK: - Math (Phase 2)

    /// Rewrites `$$…$$` display-math blocks into ```math fences.
    ///
    /// Handles both the single-line (`$$x^2$$`) and fenced (`$$` … `$$`) forms. Content already
    /// inside a code fence is skipped — a shell snippet full of `$$` is not an equation.
    private static func rewriteDisplayMath(in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var insideCodeFence = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideCodeFence.toggle()
                output.append(line)
                index += 1
                continue
            }

            guard !insideCodeFence, trimmed.hasPrefix("$$") else {
                output.append(line)
                index += 1
                continue
            }

            // `$$x^2$$` all on one line.
            if trimmed.count > 4, trimmed.hasSuffix("$$") {
                let inner = String(trimmed.dropFirst(2).dropLast(2))
                output.append(contentsOf: ["```math", inner, "```"])
                index += 1
                continue
            }

            // An opening `$$` on its own; collect until the closing one.
            var body: [String] = []
            // Anything trailing the opening delimiter is the first line of the equation.
            let firstLine = String(trimmed.dropFirst(2))
            if !firstLine.isEmpty { body.append(firstLine) }

            var cursor = index + 1
            var foundClose = false
            while cursor < lines.count {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                if candidate.hasSuffix("$$") {
                    let inner = String(candidate.dropLast(2))
                    if !inner.isEmpty { body.append(inner) }
                    foundClose = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }

            guard foundClose else {
                // Unterminated: leave the source exactly as the author wrote it.
                output.append(line)
                index += 1
                continue
            }

            output.append("```math")
            output.append(contentsOf: body)
            output.append("```")
            index = cursor + 1
        }

        return output.joined(separator: "\n")
    }

    /// Matches an inline `$…$` span. The delimiters must hug non-space characters, which is what
    /// keeps a lone currency amount ("$5 and $10") from being read as math.
    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"\$(?!\s)((?:[^$\\\n]|\\.)+?)(?<!\s)\$"#
    )

    /// Splits `$…$` spans out of a text inline. Everything else is returned untouched, so this can
    /// run over every text node without needing to know its context — code spans never reach here
    /// because cmark has already turned them into `.code`.
    static func splitInlineMath(_ text: String) -> [MarkdownInline] {
        let nsText = text as NSString
        let matches = inlineMathRegex.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let before = nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                if !before.isEmpty { result.append(.text(before)) }
            }
            result.append(.inlineMath(nsText.substring(with: match.range(at: 1))))
            cursor = NSMaxRange(match.range)
        }

        if cursor < nsText.length {
            let after = nsText.substring(from: cursor)
            if !after.isEmpty { result.append(.text(after)) }
        }

        return result
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
            // Phase 2 — Rich Markdown. Two fence languages mean something other than code:
            // ```mermaid is a diagram, and ```math is a display equation.
            let language = codeBlock.language?.lowercased()
                .trimmingCharacters(in: .whitespaces) ?? ""
            // `where` on a comma-separated case list binds to the last pattern only, so the flag
            // is checked up front rather than inside the switch.
            if FeatureFlags.richMarkdown {
                if language == "mermaid" { return .mermaid(codeBlock.code) }
                if ["math", "latex", "tex"].contains(language) {
                    return .mathBlock(codeBlock.code)
                }
            }
            return .codeBlock(codeBlock.code, codeBlock.language)

        case let blockQuote as BlockQuote:
            let children = convertBlocks(blockQuote.children, indexByLabel: indexByLabel)
            // Phase 2 — Rich Markdown, "Callouts". A block quote opening with `[!NOTE]` is a
            // callout; every other block quote stays a block quote.
            if FeatureFlags.richMarkdown, let callout = calloutFromBlockQuote(children) {
                return .callout(callout)
            }
            return .blockQuote(children)

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
        // Each plain-text run is re-scanned for `$…$` spans (Phase 2 — Rich Markdown, "Math").
        // Doing it here rather than in the pre-pass means math inside emphasis or a table cell is
        // found too, and math inside a code span never is — cmark has already claimed those.
        children.flatMap { child -> [MarkdownInline] in
            guard let inline = convertInline(child, indexByLabel: indexByLabel) else { return [] }
            if FeatureFlags.richMarkdown, case .text(let string) = inline {
                return splitInlineMath(string)
            }
            return [inline]
        }
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
