import Foundation

// MARK: - ProseMirrorMarkdownReader

/// Renders a stored ProseMirror document as the Markdown text this app edits.
///
/// The wire format of a Neutrino Doc is the web editor's ProseMirror JSON; the editing surface here
/// is Markdown. This is the read half of that translation, and its counterpart is
/// `ProseMirrorMarkdownWriter`.
///
/// ## What happens to nodes this app has no syntax for
///
/// An unknown node is not an error and is never dropped silently: one with children is replaced by
/// its children, so a `columnLayout` or a `trackedInsertion` contributes its text rather than a
/// hole. Only a childless unknown node (a section break, a table of contents placeholder) has
/// nothing to render, and those carry no authored text to lose.
enum ProseMirrorMarkdownReader {

    /// Node types whose children are block-level and should be spliced in place of the node itself.
    private static let transparentBlockNodes: Set<String> = ["columnLayout", "column", "div"]

    // MARK: - Entry point

    static func markdown(from document: ProseMirrorDocument) -> String {
        var blocks = document.doc.children

        // Front matter is written by the Markdown writer as a tagged leading code block, because
        // ProseMirror has no front-matter node. Turning it back into a `---` fence here is what
        // makes an iPhone round trip preserve the metadata card.
        var prefix = ""
        if let first = blocks.first, let fence = frontMatterFence(from: first) {
            prefix = fence + "\n\n"
            blocks.removeFirst()
        }

        return prefix + render(blocks: blocks)
    }

    // MARK: - Blocks

    private static func render(blocks: [ProseMirrorNode]) -> String {
        blocks
            .flatMap { expand($0) }
            .compactMap { render(block: $0) }
            .joined(separator: "\n\n")
    }

    /// Replaces a transparent wrapper with its children so its contents still reach the output.
    private static func expand(_ node: ProseMirrorNode) -> [ProseMirrorNode] {
        transparentBlockNodes.contains(node.type) ? node.children.flatMap(expand) : [node]
    }

    private static func render(block: ProseMirrorNode) -> String? {
        switch block.type {
        case "paragraph":
            let text = inline(block.children)
            guard !text.isEmpty else { return nil }
            // Every line is checked, not just the first: a hard break inside the paragraph starts a
            // new line that would also be read as a list or heading on the way back in.
            return text.components(separatedBy: "\n")
                .map(escapeBlockStart)
                .joined(separator: "\n")

        case "heading":
            let level = min(max(block.attribute("level")?.intValue ?? 1, 1), 6)
            return String(repeating: "#", count: level) + " " + inline(block.children)

        case "codeBlock", "code_block":
            return codeFence(block)

        case "blockquote":
            let inner = render(blocks: block.children)
            return prefixLines(of: inner, with: "> ")

        case "horizontalRule", "horizontal_rule":
            return "---"

        case "bulletList", "bullet_list", "taskList", "task_list":
            return list(block, ordered: false)

        case "orderedList", "ordered_list":
            return list(block, ordered: true)

        case "table":
            return table(block)

        case "image":
            return imageMarkdown(block)

        case "text":
            // A stray inline node at block level — render it rather than lose it.
            return inline([block])

        default:
            let children = block.children
            guard !children.isEmpty else { return nil }
            // Unknown wrapper: fall through to its children so authored text survives.
            return render(blocks: children)
        }
    }

    // MARK: - Front matter

    /// The leading code block the writer tags as front matter, rendered back as a `---` fence.
    ///
    /// After a document has been re-saved by the web app the tag is gone — TipTap drops attributes
    /// its schema does not declare — and the block stays an ordinary `yaml` code block, which is
    /// visible and editable rather than lost.
    private static func frontMatterFence(from node: ProseMirrorNode) -> String? {
        guard node.type == "codeBlock" || node.type == "code_block",
              node.attribute(ProseMirrorMarkdownWriter.frontMatterAttribute)?.boolValue == true else {
            return nil
        }
        let body = plainText(of: node)
        return "---\n" + body + "\n---"
    }

    // MARK: - Code

    private static func codeFence(_ node: ProseMirrorNode) -> String {
        let language = node.attribute("language")?.stringValue ?? ""
        let body = plainText(of: node)
        // A fence must be longer than the longest backtick run inside it, or the block ends early.
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: body) + 1))
        return fence + language + "\n" + body + "\n" + fence
    }

    private static func longestBacktickRun(in string: String) -> Int {
        var longest = 0
        var current = 0
        for character in string {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    // MARK: - Lists

    private static func list(_ node: ProseMirrorNode, ordered: Bool) -> String {
        let start = node.attribute("start")?.intValue ?? 1
        let items = node.children.enumerated().map { offset, item -> String in
            let marker = ordered ? "\(start + offset). " : "- "
            let (checkbox, blocks) = taskState(of: item)
            // Continuation lines line up under the item's text, which is what keeps a nested list
            // nested when the document is parsed back.
            let continuation = String(repeating: " ", count: marker.count)
            // The content is rendered unindented and then shifted as a whole: a nested list must
            // not also indent itself, or each level would be indented twice.
            let content = renderItemContent(blocks)
            let indented = prefixLines(of: content, with: continuation, skippingFirst: true)
            return marker + checkbox + indented
        }
        return items.joined(separator: "\n")
    }

    /// A nested list belongs on the line straight after its parent item, with no blank line — a gap
    /// there makes the list loose, which re-parses into a different document than the one written.
    private static func renderItemContent(_ blocks: [ProseMirrorNode]) -> String {
        let rendered = blocks
            .flatMap { expand($0) }
            .compactMap { block -> (isList: Bool, text: String)? in
                guard let text = render(block: block) else { return nil }
                return (isListNode(block), text)
            }

        return rendered.enumerated().reduce(into: "") { result, entry in
            let (index, block) = entry
            if index > 0 { result += block.isList ? "\n" : "\n\n" }
            result += block.text
        }
    }

    private static func isListNode(_ node: ProseMirrorNode) -> Bool {
        ["bulletList", "bullet_list", "orderedList", "ordered_list", "taskList", "task_list"]
            .contains(node.type)
    }

    /// Reads a list item's checkbox, if it has one, and returns the item's blocks without it.
    ///
    /// Two spellings are recognized. `taskItem` is TipTap's own node, which the web docs editor does
    /// not currently load but an older client may have written. The other is the `[x] ` text prefix
    /// that `ProseMirrorMarkdownWriter` uses precisely because the web schema has no task node — it
    /// has to be lifted back out here, or the brackets would be escaped as literal text and the
    /// checkbox would be gone.
    private static func taskState(of item: ProseMirrorNode) -> (marker: String, blocks: [ProseMirrorNode]) {
        if item.type == "taskItem" || item.type == "task_item" {
            let marker = item.attribute("checked")?.boolValue == true ? "[x] " : "[ ] "
            return (marker, item.children)
        }

        var blocks = item.children
        guard let paragraphIndex = blocks.firstIndex(where: { $0.type == "paragraph" }),
              let firstText = blocks[paragraphIndex].content?.first,
              firstText.type == "text",
              let text = firstText.text else {
            return ("", blocks)
        }

        let markers = ["[x] ", "[X] ", "[ ] "]
        guard let marker = markers.first(where: { text.hasPrefix($0) }) else { return ("", blocks) }

        var inlines = blocks[paragraphIndex].content ?? []
        inlines[0].text = String(text.dropFirst(marker.count))
        blocks[paragraphIndex].content = inlines
        return (marker.lowercased(), blocks)
    }

    // MARK: - Tables

    private static func table(_ node: ProseMirrorNode) -> String {
        let rows = node.children.filter { $0.type == "tableRow" || $0.type == "table_row" }
        guard let headerRow = rows.first else { return "" }

        let header = cells(of: headerRow)
        let columnCount = max(header.count, rows.map { cells(of: $0).count }.max() ?? 0)
        guard columnCount > 0 else { return "" }

        func line(_ values: [String]) -> String {
            let padded = values + Array(repeating: "", count: columnCount - values.count)
            return "| " + padded.joined(separator: " | ") + " |"
        }

        var lines = [line(header)]
        lines.append(line(Array(repeating: "---", count: columnCount)))
        for row in rows.dropFirst() {
            lines.append(line(cells(of: row)))
        }
        return lines.joined(separator: "\n")
    }

    private static func cells(of row: ProseMirrorNode) -> [String] {
        row.children.map { cell in
            // A cell holds blocks, but a Markdown table row is one line: the cell's blocks are
            // joined with spaces and any newline inside becomes a `<br>`, which is what the web
            // editor emits for a multi-line cell too.
            let text = render(blocks: cell.children)
            return text
                .replacingOccurrences(of: "\n\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "|", with: "\\|")
        }
    }

    // MARK: - Inline

    private static func inline(_ nodes: [ProseMirrorNode]) -> String {
        nodes.map(inline).joined()
    }

    private static func inline(_ node: ProseMirrorNode) -> String {
        switch node.type {
        case "text":
            return applyMarks(to: node.text ?? "", marks: node.marks ?? [])

        case "hardBreak", "hard_break":
            // Two trailing spaces are the Markdown hard break; the parser here reads them back as
            // `.lineBreak`.
            return "  \n"

        case "image":
            return imageMarkdown(node)

        case "footnote":
            let label = node.attribute("id")?.stringValue ?? ""
            return label.isEmpty ? "" : "[^\(label)]"

        default:
            return inline(node.children)
        }
    }

    /// Wraps text in Markdown delimiters, innermost first.
    ///
    /// `code` short-circuits the emphasis marks: a code span holds its text literally, so it is
    /// neither escaped nor wrapped in emphasis — `` `**x**` `` is two literal asterisks, and
    /// applying both marks would change what the text says.
    private static func applyMarks(to raw: String, marks: [ProseMirrorMark]) -> String {
        guard !raw.isEmpty else { return raw }
        let types = Set(marks.map(\.type))

        var result: String
        if types.contains("code") {
            result = "`" + raw + "`"
        } else {
            result = escape(raw)
            if types.contains("strike") || types.contains("strikethrough") || types.contains("s") {
                result = "~~" + result + "~~"
            }
            if types.contains("italic") || types.contains("em") {
                result = "*" + result + "*"
            }
            if types.contains("bold") || types.contains("strong") {
                result = "**" + result + "**"
            }
        }

        if let link = marks.first(where: { $0.type == "link" }),
           let href = link.attrs?["href"]?.stringValue, !href.isEmpty {
            result = "[" + result + "](" + href + ")"
        }
        return result
    }

    // MARK: - Images

    private static func imageMarkdown(_ node: ProseMirrorNode) -> String {
        let alt = node.attribute("alt")?.stringValue ?? ""
        let source = node.attribute("src")?.stringValue ?? ""
        if let title = node.attribute("title")?.stringValue, !title.isEmpty {
            return "![\(alt)](\(source) \"\(title)\")"
        }
        return "![\(alt)](\(source))"
    }

    // MARK: - Text helpers

    /// Concatenates the text of a node's descendants without any Markdown decoration — used for
    /// code blocks, whose content is literal.
    private static func plainText(of node: ProseMirrorNode) -> String {
        if node.type == "hardBreak" || node.type == "hard_break" { return "\n" }
        if let text = node.text { return text }
        return node.children.map(plainText).joined()
    }

    /// Escapes the characters that would otherwise be read back as syntax.
    ///
    /// Deliberately narrow. This text goes into an editor the user reads and types in, and escaping
    /// every special character produces backslash-strewn prose — `snake\_case`, `array\[0\]` — that
    /// is worse to work with than the rare re-parse it prevents. So:
    ///
    /// - `*` is always escaped: CommonMark treats it as emphasis mid-word too (`a*b*c`).
    /// - `_` is escaped only at a word boundary, because mid-word underscores are literal.
    /// - `]` is left alone; without an unescaped `[` before it, it cannot start anything.
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let characters = Array(text)

        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "`", "*", "[":
                result.append("\\")
                result.append(character)
            case "_":
                let before = index > 0 ? characters[index - 1] : nil
                let after = index + 1 < characters.count ? characters[index + 1] : nil
                if isWordBoundary(before) || isWordBoundary(after) {
                    result.append("\\")
                }
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    /// A nil neighbour is the start or end of the text, which is a boundary too.
    private static func isWordBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return !character.isLetter && !character.isNumber
    }

    /// Characters that turn a line into a different block when it is parsed back, and so have to be
    /// escaped when a paragraph happens to begin with one.
    private static let blockStarters: Set<Character> = ["#", ">", "-", "+", "*"]

    /// Escapes a leading block marker so a paragraph that starts with `- ` or `# ` stays a
    /// paragraph. Ordered-list starts (`1.`) are handled separately since they are two characters.
    private static func escapeBlockStart(_ line: String) -> String {
        guard let first = line.first else { return line }

        if blockStarters.contains(first) {
            // Already escaped by the inline escaper (`*`), or not actually a marker without the
            // space that follows one.
            return "\\" + line
        }
        if first.isNumber {
            let afterDigits = line.drop { $0.isNumber }
            if afterDigits.hasPrefix(".") || afterDigits.hasPrefix(")") {
                let digits = line.prefix { $0.isNumber }
                return String(digits) + "\\" + String(afterDigits)
            }
        }
        return line
    }

    /// Prefixes every line, which is how block quotes and list continuations are built.
    private static func prefixLines(of text: String, with prefix: String,
                                    skippingFirst: Bool = false) -> String {
        // A blank line takes the marker without its trailing padding, so the output has no lines
        // that are nothing but whitespace.
        let blankPrefix = String(prefix.reversed().drop { $0 == " " }.reversed())

        return text.components(separatedBy: "\n")
            .enumerated()
            .map { index, line in
                if skippingFirst, index == 0 { return line }
                return line.isEmpty ? blankPrefix : prefix + line
            }
            .joined(separator: "\n")
    }
}
