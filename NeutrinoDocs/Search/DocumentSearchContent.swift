import Foundation

// MARK: - DocumentSearchContent

/// Reads the four indexable fields out of a document — Phase 5, "Indexed: Titles, Content,
/// Headings, Tags".
///
/// Kept apart from the index itself so the extraction can be tested on Markdown alone, without an
/// index or a Drive item in sight.
struct DocumentSearchContent: Equatable {

    /// The front matter `title:` when there is one, otherwise the file name. Front matter wins for
    /// the same reason the editor prefers it: it is what the author called the document.
    let title: String
    let headings: [String]
    let tags: [String]
    /// The prose, with Markdown syntax stripped, front matter removed, and code blocks left out.
    let content: String
    /// The opening of `content`, for the result row.
    let preview: String

    // MARK: - Building

    static func extract(markdown: String, fileName: String) -> DocumentSearchContent {
        let split = FrontMatterParser.split(markdown)
        let frontMatter = split.frontMatter

        let outline = DocumentOutline.parse(markdown)
        let content = plainText(from: split.body)

        return DocumentSearchContent(
            title: frontMatter.title ?? Self.strippedExtension(of: fileName),
            headings: outline.headings.map(\.title),
            tags: frontMatter.tags,
            content: content,
            preview: Self.preview(of: content)
        )
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

    // MARK: - Plain text

    /// Strips the Markdown syntax that would otherwise be indexed as words.
    ///
    /// Fenced code blocks are dropped entirely: a search for "class" should find the document that
    /// discusses classes, not every document with a code sample in it. Inline code is kept, since a
    /// short `identifier` in a sentence is usually exactly what someone is looking for.
    static func plainText(from markdown: String) -> String {
        var lines: [String] = []
        var fence: String?

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            lines.append(stripInlineSyntax(from: line))
        }

        return lines
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes the markers that are syntax rather than words.
    ///
    /// A link's text is kept and its destination dropped — someone searching for "pricing" means
    /// the word in the sentence, not a URL that happens to contain it. Image alt text is kept for
    /// the same reason.
    private static func stripInlineSyntax(from line: String) -> String {
        var result = line

        for (pattern, template) in Self.replacements {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        return result
    }

    /// Ordered: links and images have to lose their destinations before the leftover punctuation is
    /// swept up, or the URL's words would survive as bare text.
    private static let replacements: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // ![alt](src) and [text](href) -> alt / text
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            // Reference-style links: [text][label] -> text
            (#"\[([^\]]*)\]\[[^\]]*\]"#, "$1"),
            // Leading block markers: #, >, -, *, +, 1., and task checkboxes.
            (#"^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)"#, ""),
            (#"^\s*\[[ xX]\]\s*"#, ""),
            // Emphasis, code, and strikethrough markers.
            (#"[*_`~]"#, ""),
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    // MARK: - Preview

    private static func preview(of content: String) -> String {
        guard content.count > IndexedDocument.previewLimit else { return content }
        // Cut at a word boundary so the preview does not end mid-word.
        let cut = content.prefix(IndexedDocument.previewLimit)
        guard let lastSpace = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[..<lastSpace]) + "…"
    }

    private static func strippedExtension(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return (ext == "md" || ext == "markdown") ? String(fileName[..<dot]) : fileName
    }
}
