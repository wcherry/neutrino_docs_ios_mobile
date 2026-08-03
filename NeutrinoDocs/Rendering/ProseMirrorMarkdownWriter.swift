import Foundation

// MARK: - ProseMirrorMarkdownWriter

/// Builds the ProseMirror document that gets stored, from the Markdown the user edited.
///
/// The write half of the translation whose read half is `ProseMirrorMarkdownReader`. Markdown is
/// parsed with the app's own `MarkdownParser` first, so anything the viewer can render is something
/// this can serialize — the two agree on the document model by construction.
///
/// ## Where this loses information
///
/// Markdown is the narrower format, so a document written here says less than one written by the
/// web editor: font sizes, colours, text alignment, tracked changes and comments have no Markdown
/// spelling and are gone from any part of the document the user actually edited. The document-level
/// layout `_meta` block survives because it is carried alongside rather than through the Markdown —
/// see `ProseMirrorDocument.layout`.
enum ProseMirrorMarkdownWriter {

    /// Marks the code block that stands in for a document's front matter.
    ///
    /// Front matter is a Markdown-source idea with no ProseMirror node, and losing it would mean a
    /// user's metadata card vanished the first time they saved. Writing it as a tagged `yaml` code
    /// block keeps it visible and editable in the web app, and `ProseMirrorMarkdownReader` turns it
    /// back into a `---` fence here.
    static let frontMatterAttribute = "neutrinoFrontMatter"

    // MARK: - Entry point

    static func document(fromMarkdown markdown: String) -> ProseMirrorNode {
        let model = MarkdownParser.parse(markdown)
        var content: [ProseMirrorNode] = []

        if !model.frontMatter.isEmpty {
            content.append(frontMatterNode(FrontMatterWriter.text(for: model.frontMatter)))
        }
        content += model.blocks.flatMap(nodes(for:))
        content += footnoteNodes(model.footnotes)

        // ProseMirror requires a doc to hold at least one block; an empty document is one empty
        // paragraph, which is also what the web editor produces for a blank file.
        if content.isEmpty { content = [ProseMirrorNode.paragraph([])] }
        return ProseMirrorNode(type: "doc", content: content)
    }

    // MARK: - Blocks

    private static func nodes(for block: MarkdownBlock) -> [ProseMirrorNode] {
        switch block {
        case .paragraph(let inlines):
            return [ProseMirrorNode.paragraph(self.inlines(inlines))]

        case .heading(let level, let inlines):
            return [ProseMirrorNode(type: "heading",
                                    attrs: ["level": .int(level)],
                                    content: self.inlines(inlines))]

        case .codeBlock(let code, let language):
            return [codeBlockNode(code, language: language)]

        case .blockQuote(let blocks):
            return [ProseMirrorNode(type: "blockquote", content: blocks.flatMap(nodes(for:)))]

        case .thematicBreak:
            return [ProseMirrorNode(type: "horizontalRule")]

        case .list(let list):
            return [listNode(list)]

        case .table(let table):
            return [tableNode(table)]

        case .callout(let callout):
            return [calloutNode(callout)]

        case .mermaid(let source):
            // The parser recognizes a ```mermaid fence as a diagram, so writing one back is what
            // makes the round trip closed.
            return [codeBlockNode(source, language: "mermaid")]

        case .mathBlock(let source):
            return [codeBlockNode(source, language: "math")]
        }
    }

    private static func codeBlockNode(_ code: String, language: String?) -> ProseMirrorNode {
        var attrs: [String: JSONValue] = [:]
        attrs["language"] = language.map { JSONValue.string($0) } ?? .null

        let body = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return ProseMirrorNode(type: "codeBlock",
                               attrs: attrs,
                               content: body.isEmpty ? nil : [.text(body)])
    }

    private static func frontMatterNode(_ yaml: String) -> ProseMirrorNode {
        ProseMirrorNode(type: "codeBlock",
                        attrs: ["language": .string("yaml"), frontMatterAttribute: .bool(true)],
                        content: yaml.isEmpty ? nil : [.text(yaml)])
    }

    /// A callout is a block quote whose first line names the kind, which is exactly how the parser
    /// recognizes one — so it round-trips through a plain `blockquote` without a bespoke node.
    private static func calloutNode(_ callout: MarkdownCallout) -> ProseMirrorNode {
        var marker = "[!\(callout.kind.rawValue.uppercased())]"
        if let title = callout.title, !title.isEmpty { marker += " " + title }

        let header = ProseMirrorNode.paragraph([.text(marker)])
        return ProseMirrorNode(type: "blockquote",
                               content: [header] + callout.content.flatMap(nodes(for:)))
    }

    // MARK: - Lists

    private static func listNode(_ list: MarkdownList) -> ProseMirrorNode {
        let items = list.items.map { item -> ProseMirrorNode in
            var content = item.content.flatMap(nodes(for:))
            if content.isEmpty { content = [ProseMirrorNode.paragraph([])] }

            // The web editor has no task-list node, so a checkbox is written into the item's text
            // as the `[x] ` Markdown source itself. It reads back as a real checkbox here and shows
            // as plain text there, which is the most either side can do with the other's format.
            if let checkbox = item.checkbox {
                content = prefixingFirstParagraph(content, with: checkbox ? "[x] " : "[ ] ")
            }
            return ProseMirrorNode(type: "listItem", content: content)
        }

        var attrs: [String: JSONValue]?
        if list.isOrdered, let start = list.startIndex, start != 1 {
            attrs = ["start": .int(start)]
        }
        return ProseMirrorNode(type: list.isOrdered ? "orderedList" : "bulletList",
                               attrs: attrs,
                               content: items)
    }

    private static func prefixingFirstParagraph(_ blocks: [ProseMirrorNode],
                                                with prefix: String) -> [ProseMirrorNode] {
        guard let index = blocks.firstIndex(where: { $0.type == "paragraph" }) else {
            return [ProseMirrorNode.paragraph([.text(prefix)])] + blocks
        }
        var blocks = blocks
        blocks[index].content = [.text(prefix)] + (blocks[index].content ?? [])
        return blocks
    }

    // MARK: - Tables

    private static func tableNode(_ table: MarkdownTable) -> ProseMirrorNode {
        func cell(_ inlines: [MarkdownInline], type: String) -> ProseMirrorNode {
            // TipTap's table cells declare these attributes; omitting them leaves the web editor
            // recomputing them on load, which shows up as a spurious "unsaved changes" state.
            ProseMirrorNode(type: type,
                            attrs: ["colspan": .int(1), "rowspan": .int(1), "colwidth": .null],
                            content: [ProseMirrorNode.paragraph(self.inlines(inlines))])
        }

        var rows = [ProseMirrorNode(type: "tableRow",
                                    content: table.header.map { cell($0, type: "tableHeader") })]
        rows += table.rows.map { row in
            ProseMirrorNode(type: "tableRow", content: row.map { cell($0, type: "tableCell") })
        }
        return ProseMirrorNode(type: "table", content: rows)
    }

    // MARK: - Footnotes

    /// Footnote bodies have no home in the web editor's schema, so they are written as an ordinary
    /// trailing section — visible and editable in both apps, and read back as footnotes here
    /// because that is exactly the Markdown source the parser expects.
    private static func footnoteNodes(_ footnotes: [MarkdownFootnote]) -> [ProseMirrorNode] {
        footnotes.map { footnote in
            ProseMirrorNode.paragraph([.text("[^\(footnote.id)]: ")] + inlines(footnote.content))
        }
    }

    // MARK: - Inline

    private static func inlines(_ inlines: [MarkdownInline]) -> [ProseMirrorNode] {
        inlines.flatMap { nodes(for: $0, marks: []) }
    }

    private static func nodes(for inline: MarkdownInline,
                              marks: [ProseMirrorMark]) -> [ProseMirrorNode] {
        switch inline {
        case .text(let string):
            return string.isEmpty ? [] : [.text(string, marks: marks.isEmpty ? nil : marks)]

        case .strong(let children):
            return children.flatMap { nodes(for: $0, marks: adding("bold", to: marks)) }

        case .emphasis(let children):
            return children.flatMap { nodes(for: $0, marks: adding("italic", to: marks)) }

        case .strikethrough(let children):
            return children.flatMap { nodes(for: $0, marks: adding("strike", to: marks)) }

        case .code(let string):
            return [.text(string, marks: adding("code", to: marks))]

        case .link(let children, let destination):
            let link = ProseMirrorMark(type: "link", attrs: ["href": .string(destination)])
            return children.flatMap { nodes(for: $0, marks: marks + [link]) }

        case .image(let alt, let source, let title):
            var attrs: [String: JSONValue] = ["src": .string(source), "alt": .string(alt)]
            attrs["title"] = title.map { JSONValue.string($0) } ?? .null
            return [ProseMirrorNode(type: "image", attrs: attrs)]

        case .footnoteReference(let label, _):
            return [ProseMirrorNode(type: "footnote", attrs: ["id": .string(label)])]

        case .inlineMath(let source):
            // No math mark exists in the web schema; the `$…$` source is the portable form.
            return [.text("$\(source)$", marks: marks.isEmpty ? nil : marks)]

        case .softBreak:
            return [.text(" ", marks: marks.isEmpty ? nil : marks)]

        case .lineBreak:
            return [ProseMirrorNode(type: "hardBreak")]
        }
    }

    private static func adding(_ type: String, to marks: [ProseMirrorMark]) -> [ProseMirrorMark] {
        marks.contains { $0.type == type } ? marks : marks + [ProseMirrorMark(type: type)]
    }
}

// MARK: - FrontMatterWriter

/// Renders a parsed `FrontMatter` back to the YAML-ish source it came from.
///
/// The parser is lossy about formatting — quoting, spacing, comments — so this does not promise the
/// author's exact bytes, only the same keys and values in the same order.
enum FrontMatterWriter {

    static func text(for frontMatter: FrontMatter) -> String {
        frontMatter.entries.map { entry in
            switch entry.values.count {
            case 0:  return "\(entry.key):"
            case 1:  return "\(entry.key): \(quotedIfNeeded(entry.values[0]))"
            default: return "\(entry.key): [\(entry.values.map(quotedIfNeeded).joined(separator: ", "))]"
            }
        }
        .joined(separator: "\n")
    }

    /// Quotes a value that would otherwise change meaning when it is read back — one holding a
    /// comma would come back as a list, and one holding a colon as a different key.
    private static func quotedIfNeeded(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains(":") || value.contains("#")
            || value != value.trimmingCharacters(in: .whitespaces)
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
