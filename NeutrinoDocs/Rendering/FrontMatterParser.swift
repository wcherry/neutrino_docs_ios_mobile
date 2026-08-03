import Foundation

// MARK: - FrontMatterParser

/// Splits a leading `---` fenced block off the top of a document and reads it as flat key/value
/// front matter — Phase 2 — Rich Markdown, "Front matter".
///
/// This is intentionally a small subset of YAML rather than a real parser. Document front matter in
/// practice is flat scalars, inline lists, and dash lists; supporting anchors, nested maps, or block
/// scalars would mean shipping a YAML engine to render a metadata card. Anything not understood is
/// preserved as a plain string rather than dropped, so nothing an author wrote disappears silently.
enum FrontMatterParser {

    /// The result of taking front matter off a document.
    struct Split: Equatable {
        let frontMatter: FrontMatter
        /// The document with the front-matter block removed, ready for the Markdown parser.
        let body: String
    }

    /// Recognizes `---` (and the `+++` TOML-style fence some tools emit) as an opening delimiter,
    /// but only on the very first line — a `---` further down is a thematic break.
    private static let fences = ["---", "+++"]

    // MARK: - Entry point

    static func split(_ source: String) -> Split {
        let lines = source.components(separatedBy: "\n")

        guard let opening = lines.first.map(trimmedTrailing),
              fences.contains(opening),
              let closingIndex = closingFenceIndex(in: lines, matching: opening) else {
            return Split(frontMatter: .empty, body: source)
        }

        let entries = parseEntries(Array(lines[1..<closingIndex]))
        // Everything after the closing fence, with the leading blank lines that usually follow it
        // dropped so the body does not start with a gap.
        let remainder = Array(lines[(closingIndex + 1)...])
        let body = remainder.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }

        return Split(frontMatter: FrontMatter(entries: entries),
                     body: body.joined(separator: "\n"))
    }

    /// An unterminated front-matter block is not front matter — without this the whole document
    /// would vanish into the metadata card.
    private static func closingFenceIndex(in lines: [String], matching fence: String) -> Int? {
        guard lines.count > 1 else { return nil }
        for index in 1..<lines.count where trimmedTrailing(lines[index]) == fence {
            return index
        }
        return nil
    }

    // MARK: - Entries

    private static func parseEntries(_ lines: [String]) -> [FrontMatter.Entry] {
        var entries: [FrontMatter.Entry] = []
        // Tracks the most recent `key:` with an empty value, so the `- item` lines under it attach
        // to it rather than being read as top-level entries.
        var pendingListKey: String?
        var pendingListValues: [String] = []

        func flushPendingList() {
            if let key = pendingListKey {
                entries.append(FrontMatter.Entry(key: key, values: pendingListValues))
                pendingListKey = nil
                pendingListValues = []
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // A dash list item belongs to the key above it.
            if line.hasPrefix("- "), pendingListKey != nil {
                pendingListValues.append(unquote(String(line.dropFirst(2))))
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                flushPendingList()
                continue
            }

            flushPendingList()

            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if rawValue.isEmpty {
                // Either an empty value or the header of a dash list — decided by what follows.
                pendingListKey = key
                pendingListValues = []
                continue
            }

            entries.append(FrontMatter.Entry(key: key, values: values(from: rawValue)))
        }

        flushPendingList()
        return entries
    }

    /// Reads a scalar, an inline `[a, b]` list, or a bare comma-separated list.
    private static func values(from raw: String) -> [String] {
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return splitOnCommas(inner)
        }
        // `tags: swift, ios` is common enough in real documents to be worth reading as a list,
        // but only when it is unquoted — a quoted string is one value whatever is inside it.
        if !isQuoted(raw), raw.contains(",") {
            return splitOnCommas(raw)
        }
        return [unquote(raw)]
    }

    private static func splitOnCommas(_ string: String) -> [String] {
        string.components(separatedBy: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func isQuoted(_ string: String) -> Bool {
        (string.hasPrefix("\"") && string.hasSuffix("\"") && string.count >= 2)
            || (string.hasPrefix("'") && string.hasSuffix("'") && string.count >= 2)
    }

    private static func unquote(_ string: String) -> String {
        guard isQuoted(string) else { return string }
        return String(string.dropFirst().dropLast())
    }

    /// Trailing whitespace on a fence line is invisible but would otherwise stop it matching.
    private static func trimmedTrailing(_ line: String) -> String {
        var result = line
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
