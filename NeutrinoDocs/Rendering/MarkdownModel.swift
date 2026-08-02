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
    case softBreak
    case lineBreak
}

// MARK: - MarkdownFootnote

struct MarkdownFootnote: Equatable, Identifiable {
    let id: String
    let index: Int
    let content: [MarkdownInline]
}
