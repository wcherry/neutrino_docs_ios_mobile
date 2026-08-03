import SwiftUI

// MARK: - MarkdownCalloutView

/// A GitHub-style callout — Phase 2 — Rich Markdown, "Callouts".
///
/// Rendered as a tinted card with the kind's icon and name, rather than as an indented block quote,
/// so the severity is legible at a glance.
struct MarkdownCalloutView: View {

    let callout: MarkdownCallout
    let footnotes: [MarkdownFootnote]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(callout.title ?? callout.kind.displayName)
                    .font(.subheadline.bold())
            } icon: {
                Image(systemName: callout.kind.systemImage)
            }
            .foregroundStyle(tint)

            if !callout.content.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(callout.content.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, footnotes: footnotes)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10))
        .overlay(alignment: .leading) {
            // The colour bar carries the meaning for anyone who cannot distinguish the tint.
            Rectangle().fill(tint).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(callout.title ?? callout.kind.displayName))
        .accessibilityHint(Text(callout.kind.displayName))
    }

    private var tint: Color {
        switch callout.kind {
        case .note:      return .accentColor
        case .tip:       return .green
        case .important: return .purple
        case .warning:   return .orange
        case .caution:   return .red
        }
    }
}

// MARK: - FrontMatterView

/// The metadata card for a document's front matter — Phase 2 — Rich Markdown, "Front matter".
///
/// Collapsed by default: front matter is usually machine-oriented, and expanding it by default
/// would push the document's actual first heading off the screen.
struct FrontMatterView: View {

    let frontMatter: FrontMatter

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(summary)
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Document metadata"))
            .accessibilityHint(Text(isExpanded ? "Collapse" : "Expand"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(frontMatter.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.key)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 64, alignment: .leading)
                            valueView(for: entry)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// A list renders as chips so multi-value keys (tags, authors) are visibly plural.
    @ViewBuilder
    private func valueView(for entry: FrontMatter.Entry) -> some View {
        if let scalar = entry.scalar {
            Text(scalar)
                .font(.caption)
                .textSelection(.enabled)
        } else {
            WrappingChips(values: entry.values)
        }
    }

    private var summary: String {
        if let title = frontMatter.title { return title }
        let count = frontMatter.entries.count
        return count == 1 ? "1 metadata field" : "\(count) metadata fields"
    }
}

// MARK: - WrappingChips

/// Small tag pills that wrap onto as many lines as they need.
///
/// SwiftUI has no wrapping stack before iOS 16's `Layout`, and this app targets iOS 16, so the flow
/// is computed with a width-tracking pass rather than pulled in from a newer API.
private struct WrappingChips: View {

    let values: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - FlowLayout

/// A minimal wrapping layout: places subviews left to right, moving to a new row when the next one
/// would overflow the proposed width.
struct FlowLayout: Layout {

    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(at: CGPoint(x: x, y: y),
                                     anchor: .topLeading,
                                     proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if projected > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
