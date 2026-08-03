import Foundation

// MARK: - MarkdownDocumentModel

/// The pure-Swift, testable representation of a parsed Markdown document.
///
/// Produced by `MarkdownParser.parse(_:)` and consumed by `MarkdownInlineRenderer` and the SwiftUI
/// `MarkdownView`. Keeping the model free of any SwiftUI type is what lets the whole parse be
/// asserted in unit tests without rendering anything.
struct MarkdownDocumentModel: Equatable {
    let blocks: [MarkdownBlock]
    let footnotes: [MarkdownFootnote]
    /// Phase 2 — Rich Markdown, "Front matter". Empty when the document has no leading `---` block.
    let frontMatter: FrontMatter

    init(blocks: [MarkdownBlock],
         footnotes: [MarkdownFootnote],
         frontMatter: FrontMatter = .empty) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.frontMatter = frontMatter
    }

    static let empty = MarkdownDocumentModel(blocks: [], footnotes: [])
}

// MARK: - MarkdownBlock

indirect enum MarkdownBlock: Equatable {
    case paragraph([MarkdownInline])
    case heading(level: Int, inlines: [MarkdownInline])
    case list(MarkdownList)
    case table(MarkdownTable)
    case codeBlock(String, String?)
    case blockQuote([MarkdownBlock])
    case thematicBreak
    /// Phase 2 — Rich Markdown, "Callouts". `> [!NOTE]` and friends.
    case callout(MarkdownCallout)
    /// Phase 2 — Rich Markdown, "Mermaid". Holds the raw diagram source; layout happens at render
    /// time so the model stays free of geometry.
    case mermaid(String)
    /// Phase 2 — Rich Markdown, "Math". A display-mode (`$$…$$`) expression.
    case mathBlock(String)
}

// MARK: - MarkdownCallout

/// A GitHub-style callout: a block quote whose first line is `[!KIND]`, optionally followed by a
/// custom title on the same line.
struct MarkdownCallout: Equatable {
    let kind: MarkdownCalloutKind
    /// `nil` uses the kind's own name as the heading.
    let title: String?
    let content: [MarkdownBlock]
}

// MARK: - MarkdownCalloutKind

enum MarkdownCalloutKind: String, Equatable, CaseIterable {
    case note
    case tip
    case important
    case warning
    case caution

    /// Parses the token inside `[!…]`, which authors write in any case.
    init?(token: String) {
        self.init(rawValue: token.lowercased())
    }

    var displayName: String {
        switch self {
        case .note:      return "Note"
        case .tip:       return "Tip"
        case .important: return "Important"
        case .warning:   return "Warning"
        case .caution:   return "Caution"
        }
    }

    var systemImage: String {
        switch self {
        case .note:      return "info.circle.fill"
        case .tip:       return "lightbulb.fill"
        case .important: return "exclamationmark.circle.fill"
        case .warning:   return "exclamationmark.triangle.fill"
        case .caution:   return "hand.raised.fill"
        }
    }
}

// MARK: - FrontMatter

/// The YAML-ish key/value block some Markdown documents open with, between two `---` fences.
///
/// Deliberately not a general YAML parser: this reads the flat `key: value` and `key: [a, b]` forms
/// that document front matter actually uses, and preserves source order so the rendered metadata
/// card matches what the author wrote.
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

    /// `title:` is the one key with a defined meaning — the editor prefers it over the file name.
    var title: String? {
        guard let value = self["title"]?.first, !value.isEmpty else { return nil }
        return value
    }

    /// `tags:` in either the inline-list or comma-separated scalar form.
    var tags: [String] { self["tags"] ?? [] }
}

// MARK: - MarkdownList

struct MarkdownList: Equatable {
    let isOrdered: Bool
    let startIndex: Int?
    let items: [MarkdownListItem]
}

// MARK: - MarkdownListItem

struct MarkdownListItem: Equatable {
    /// `nil` for a plain list item; `false`/`true` for an unchecked/checked task-list item.
    let checkbox: Bool?
    let content: [MarkdownBlock]
}

// MARK: - MarkdownTable

struct MarkdownTable: Equatable {
    let alignments: [MarkdownTableColumnAlignment]
    let header: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
}

// MARK: - MarkdownTableColumnAlignment

enum MarkdownTableColumnAlignment: Equatable {
    case none
    case leading
    case center
    case trailing
}

// MARK: - MarkdownInline

indirect enum MarkdownInline: Equatable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(inlines: [MarkdownInline], destination: String)
    case image(alt: String, source: String, title: String?)
    case footnoteReference(label: String, index: Int)
    /// Phase 2 — Rich Markdown, "Math". An inline `$…$` expression.
    case inlineMath(String)
    case softBreak
    case lineBreak
}

// MARK: - MarkdownFootnote

struct MarkdownFootnote: Equatable, Identifiable {
    let id: String
    let index: Int
    let content: [MarkdownInline]
}
