import Foundation

// MARK: - DocumentSearchContent

/// Reads the four indexable fields out of a document — Phase 5, "Indexed: Titles, Content,
/// Headings, Tags".
///
/// Kept apart from the index itself so the extraction can be tested on a document alone, without an
/// index or a Drive item in sight.
struct DocumentSearchContent: Equatable {

    /// The front matter `title:` when there is one, otherwise the document's name. Front matter
    /// wins for the same reason the editor prefers it: it is what the author called the document.
    let title: String
    let headings: [String]
    let tags: [String]
    /// The prose: what the document says, with code blocks left out.
    let content: String
    /// The opening of `content`, for the result row.
    let preview: String

    // MARK: - Building

    /// Reads the indexable fields straight out of the document tree.
    ///
    /// Nothing is stripped here, because there is no syntax to strip: a heading is a heading node
    /// and its title is its text. Code blocks are skipped — a search for "class" should find the
    /// document that discusses classes, not every document with a code sample in it — and the
    /// front-matter block is read for the title and tags rather than indexed as prose.
    static func extract(document: ProseMirrorNode, fileName: String) -> DocumentSearchContent {
        var parts = Parts()
        for block in document.children { collect(block, into: &parts) }

        let frontMatter = FrontMatter.read(parts.frontMatter ?? "")
        let content = parts.words.joined(separator: " ")

        return DocumentSearchContent(
            title: frontMatter.title ?? fileName,
            headings: parts.headings,
            tags: frontMatter.tags,
            content: content,
            preview: Self.preview(of: content)
        )
    }

    /// What one walk of the tree gathers.
    private struct Parts {
        var headings: [String] = []
        var words: [String] = []
        /// The leading `yaml` code block, which is how front matter is stored in a tree document.
        var frontMatter: String?
        var isFirstBlock = true
    }

    private static func collect(_ node: ProseMirrorNode, into parts: inout Parts) {
        let wasFirst = parts.isFirstBlock
        parts.isFirstBlock = false

        if DocumentNodeType.isCodeBlock(node.type) {
            // Front matter rides in a leading tagged block — metadata, not prose.
            if wasFirst, node.isFrontMatter { parts.frontMatter = text(of: node) }
            return
        }

        if DocumentNodeType.isHeading(node.type) {
            let title = text(of: node).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { parts.headings.append(title) }
        }

        if DocumentNodeType.textBlocks.contains(node.type) {
            let line = text(of: node)
            if !line.isEmpty { parts.words.append(line) }
            return
        }

        for child in node.children { collect(child, into: &parts) }
    }

    /// The words in a block: its text runs, plus the alt text of any picture in it — someone
    /// searching for "pricing" means the word, whether it was typed or described.
    private static func text(of node: ProseMirrorNode) -> String {
        if let text = node.text { return text }
        if node.type == DocumentNodeType.image {
            return node.attribute("alt")?.stringValue ?? ""
        }
        return node.children
            .map { text(of: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The fields as the index wants them: one string per field.
    ///
    /// Headings are also part of `content`, and that double counting is deliberate — a term in a
    /// heading scores once as a heading and once as body text, which is what makes a document whose
    /// heading is about the query outrank one that merely mentions it.
    var indexedFields: [SearchField: String] {
        [
            .title:   title,
            .heading: headings.joined(separator: " "),
            .tag:     tags.joined(separator: " "),
            .content: content,
        ]
    }

    // MARK: - Preview

    private static func preview(of content: String) -> String {
        guard content.count > IndexedDocument.previewLimit else { return content }
        // Cut at a word boundary so the preview does not end mid-word.
        let cut = content.prefix(IndexedDocument.previewLimit)
        guard let lastSpace = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[..<lastSpace]) + "…"
    }
}
