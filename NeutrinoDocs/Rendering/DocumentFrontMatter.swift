import Foundation

// MARK: - FrontMatter

/// A document's metadata block: flat `key: value` pairs the author wrote at the top of the
/// document.
///
/// A tree document keeps it as a tagged `yaml` code block — the web app's spelling, and the reason
/// it survives a round trip through either editor. The block is data, not structure: nothing here
/// affects how the document is laid out, and the only two keys with a defined meaning are `title`
/// and `tags`, which the search index reads.
///
/// Deliberately not a general YAML parser: this reads the flat `key: value` and `key: [a, b]` forms
/// that document metadata actually uses, and preserves source order so what is read back matches
/// what the author wrote.
struct FrontMatter: Equatable {

    struct Entry: Equatable, Identifiable {
        let key: String
        let values: [String]

        var id: String { key }

        /// The single scalar value, or `nil` when the entry is a list.
        var scalar: String? { values.count == 1 ? values[0] : nil }
    }

    let entries: [Entry]

    static let empty = FrontMatter(entries: [])

    var isEmpty: Bool { entries.isEmpty }

    subscript(key: String) -> [String]? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.values
    }

    /// `title:` is the one key the app prefers over the file name.
    var title: String? {
        guard let value = self["title"]?.first, !value.isEmpty else { return nil }
        return value
    }

    /// `tags:` in either the inline-list or comma-separated scalar form.
    var tags: [String] { self["tags"] ?? [] }

    // MARK: - Reading

    /// Reads the contents of a document's front-matter block.
    static func read(_ yaml: String) -> FrontMatter {
        FrontMatter(entries: entries(in: yaml.components(separatedBy: "\n")))
    }

    private static func entries(in lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        // Tracks the most recent `key:` with an empty value, so the `- item` lines under it attach
        // to it rather than being read as top-level entries.
        var pendingListKey: String?
        var pendingListValues: [String] = []

        func flushPendingList() {
            if let key = pendingListKey {
                entries.append(Entry(key: key, values: pendingListValues))
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

            entries.append(Entry(key: key, values: values(from: rawValue)))
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
}

// MARK: - The front-matter block

extension ProseMirrorNode {

    /// Marks the code block that holds the document's front matter, so it is recognisable as
    /// metadata rather than as a code sample that happens to be YAML.
    static let frontMatterAttribute = "neutrinoFrontMatter"

    /// Whether this node is the document's front-matter block.
    var isFrontMatter: Bool {
        guard DocumentNodeType.isCodeBlock(type) else { return false }
        if attribute(Self.frontMatterAttribute)?.boolValue == true { return true }
        return attribute("language")?.stringValue == "yaml"
    }

    /// The document's front matter, which is the leading block when it is one.
    var frontMatter: FrontMatter {
        guard let first = children.first, first.isFrontMatter else { return .empty }
        return FrontMatter.read(first.plainText)
    }
}
