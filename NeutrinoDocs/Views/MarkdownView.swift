import SwiftUI

// MARK: - MarkdownView

/// Read-only renderer for a Markdown string — Phase 1's Document Viewer.
///
/// Parses `text` with `MarkdownParser` and renders the resulting model as native SwiftUI:
/// headings, lists, task lists, tables, code blocks, block quotes, thematic breaks, images, links,
/// and footnotes.
struct MarkdownView: View {

    let text: String

    /// Which heading to scroll to, set by the outline. Cleared once the scroll has happened so the
    /// same heading can be picked twice in a row.
    var scrollTarget: Binding<DocumentOutline.Heading.ID?>?

    /// The parse is done once per text change rather than on every layout pass — `body` can run
    /// many times for one document, and re-parsing a long document each time is felt as scroll
    /// jank. A computed property would re-parse on each `body` call, so it happens in `init`, which
    /// SwiftUI only calls when `text` actually changes.
    private let document: MarkdownDocumentModel

    init(text: String, scrollTarget: Binding<DocumentOutline.Heading.ID?>? = nil) {
        self.text = text
        self.scrollTarget = scrollTarget
        self.document = MarkdownParser.parse(text)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !document.frontMatter.isEmpty {
                        FrontMatterView(frontMatter: document.frontMatter)
                    }

                    if document.blocks.isEmpty && document.footnotes.isEmpty
                        && document.frontMatter.isEmpty {
                        Text("This document is empty.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                            MarkdownBlockView(block: block, footnotes: document.footnotes)
                                // Headings carry the outline's anchor ids so picking one can
                                // scroll straight to it.
                                .id(headingAnchor(at: index, block: block))
                        }
                    }

                    if !document.footnotes.isEmpty {
                        footnotesSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .environment(\.openURL, OpenURLAction { url in
                // A footnote marker is a link only so it can be tapped; it must scroll rather than
                // hand an unopenable custom scheme to the system.
                guard url.absoluteString.hasPrefix(MarkdownParser.footnoteScheme) else {
                    return .systemAction
                }
                let label = url.host
                    ?? url.absoluteString.replacingOccurrences(of: MarkdownParser.footnoteScheme, with: "")
                withAnimation {
                    proxy.scrollTo("footnote-\(label)", anchor: .top)
                }
                return .handled
            })
            .onChange(of: scrollTarget?.wrappedValue) { target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                // Cleared so selecting the same heading again still scrolls.
                scrollTarget?.wrappedValue = nil
            }
        }
    }

    /// Anchor id for a heading block, matching the ids `DocumentOutline` hands out. Non-heading
    /// blocks get a positional id, which keeps `ForEach` stable without colliding with an anchor.
    private func headingAnchor(at index: Int, block: MarkdownBlock) -> String {
        guard case .heading = block else { return "block-\(index)" }
        // The nth heading in the block list is the nth heading in the outline, because both walk
        // the same array in the same order.
        let ordinal = document.blocks.prefix(index).filter { if case .heading = $0 { return true }
                                                             else { return false } }.count
        return DocumentOutline.anchorID(forHeadingAt: ordinal)
    }

    // MARK: - Footnotes

    private var footnotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text("Footnotes")
                .font(.headline)
            ForEach(document.footnotes) { footnote in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(footnote.index).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(MarkdownInlineRenderer.attributedString(for: footnote.content))
                        .font(.footnote)
                }
                .id("footnote-\(footnote.id)")
            }
        }
    }
}

// MARK: - MarkdownBlockView

/// Renders a single block, recursing into nested blocks (lists, block quotes).
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let footnotes: [MarkdownFootnote]

    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            Text(MarkdownInlineRenderer.attributedString(for: inlines))
                .font(Self.headingFont(for: level))
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let inlines):
            paragraphView(inlines)

        case .list(let list):
            MarkdownListView(list: list, footnotes: footnotes, nestingLevel: 0)

        case .table(let table):
            MarkdownTableView(table: table, footnotes: footnotes)

        case .codeBlock(let code, let language):
            MarkdownCodeBlockView(code: code, language: language)

        case .blockQuote(let blocks):
            MarkdownBlockQuoteView(blocks: blocks, footnotes: footnotes)

        case .thematicBreak:
            Divider()

        case .callout(let callout):
            MarkdownCalloutView(callout: callout, footnotes: footnotes)

        case .mermaid(let source):
            MermaidView(source: source)

        case .mathBlock(let source):
            MathView(source: source)
        }
    }

    /// A paragraph that is entirely one image renders as a real block-level image; anything else
    /// goes through the inline renderer, which falls back to alt text.
    @ViewBuilder
    private func paragraphView(_ inlines: [MarkdownInline]) -> some View {
        if inlines.count == 1, case let .image(alt, source, _) = inlines[0] {
            MarkdownImageView(alt: alt, source: source)
        } else {
            Text(MarkdownInlineRenderer.attributedString(for: inlines))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func headingFont(for level: Int) -> Font {
        switch level {
        case 1:  return .largeTitle
        case 2:  return .title
        case 3:  return .title2
        case 4:  return .title3
        case 5:  return .headline
        default: return .subheadline
        }
    }
}

// MARK: - MarkdownListView

struct MarkdownListView: View {
    let list: MarkdownList
    let footnotes: [MarkdownFootnote]
    let nestingLevel: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                MarkdownListItemView(item: item,
                                     footnotes: footnotes,
                                     marker: marker(for: offset),
                                     nestingLevel: nestingLevel)
            }
        }
        .padding(.leading, CGFloat(nestingLevel) * 16)
    }

    /// Ordered lists count from the source's start index, so a list beginning at `3.` is numbered
    /// 3, 4, 5 rather than renumbered from one.
    private func marker(for offset: Int) -> String {
        guard list.isOrdered else { return "\u{2022}" }
        return "\((list.startIndex ?? 1) + offset)."
    }
}

// MARK: - MarkdownListItemView

struct MarkdownListItemView: View {
    let item: MarkdownListItem
    let footnotes: [MarkdownFootnote]
    let marker: String
    let nestingLevel: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            checkboxOrMarker
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(item.content.enumerated()), id: \.offset) { _, block in
                    if case .list(let nested) = block {
                        MarkdownListView(list: nested, footnotes: footnotes, nestingLevel: nestingLevel + 1)
                    } else {
                        MarkdownBlockView(block: block, footnotes: footnotes)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var checkboxOrMarker: some View {
        if let checkbox = item.checkbox {
            // Read-only: the viewer renders the state, the editor is where it is changed.
            Image(systemName: checkbox ? "checkmark.square" : "square")
                .foregroundStyle(checkbox ? Color.accentColor : Color.secondary)
                .accessibilityLabel(checkbox ? "Checked" : "Unchecked")
        } else {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
        }
    }
}

// MARK: - MarkdownTableView

struct MarkdownTableView: View {
    let table: MarkdownTable
    let footnotes: [MarkdownFootnote]

    var body: some View {
        // A wide table scrolls inside itself rather than forcing the whole document sideways.
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        Text(MarkdownInlineRenderer.attributedString(for: cell))
                            .font(.subheadline.bold())
                            .gridColumnAlignment(alignment(for: index))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(MarkdownInlineRenderer.attributedString(for: cell))
                                .gridColumnAlignment(alignment(for: index))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func alignment(for columnIndex: Int) -> HorizontalAlignment {
        guard columnIndex < table.alignments.count else { return .leading }
        switch table.alignments[columnIndex] {
        case .none, .leading: return .leading
        case .center:         return .center
        case .trailing:       return .trailing
        }
    }
}

// MARK: - MarkdownCodeBlockView

struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - MarkdownBlockQuoteView

struct MarkdownBlockQuoteView: View {
    let blocks: [MarkdownBlock]
    let footnotes: [MarkdownFootnote]

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, footnotes: footnotes)
                }
            }
            .padding(.leading, 4)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - MarkdownImageView

struct MarkdownImageView: View {
    let alt: String
    let source: String

    var body: some View {
        if let url = URL(string: source), url.scheme != nil {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                case .failure:
                    failureView
                @unknown default:
                    failureView
                }
            }
        } else {
            // A relative path points into Drive, which needs an authorized fetch this viewer does
            // not do; showing the alt text is honest about that rather than spinning forever.
            failureView
        }
    }

    private var failureView: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(.secondary)
            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Preview

#Preview {
    MarkdownView(text: """
    # Heading

    Some **bold**, *italic*, and `code` text with a [link](https://example.com).

    - [ ] Todo
    - [x] Done

    | A | B |
    | --- | ---: |
    | 1 | 2 |

    > A quote.

    ---

    Footnote reference[^1].

    [^1]: The footnote body.
    """)
}
