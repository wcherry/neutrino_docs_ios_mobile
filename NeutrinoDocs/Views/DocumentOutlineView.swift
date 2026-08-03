import SwiftUI

// MARK: - DocumentOutlineView

/// The document outline — Phase 2 — Document Outline: "Heading navigation", "Collapse sections",
/// "Search headings".
///
/// Presented as a sheet on iPhone and as a side panel on iPad. Selecting a heading moves the
/// editor's caret to it in Edit mode and scrolls the rendered document to it in Preview mode,
/// which is why the caller supplies the action rather than the view reaching for the controller.
struct DocumentOutlineView: View {

    let outline: DocumentOutline
    /// Called with the chosen heading. The caller decides what "go there" means for the mode it is
    /// in.
    let onSelect: (DocumentOutline.Heading) -> Void

    @State private var query = ""
    @State private var collapsed: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if outline.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No headings",
                    message: "Add a heading with # to build an outline of this document.",
                    systemImage: "list.bullet.indent"
                )
            } else {
                list
            }
        }
        .navigationTitle("Outline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if visibleHeadings.isEmpty {
                Text("No headings match “\(query)”.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleHeadings) { heading in
                    row(for: heading)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Search headings")
    }

    private func row(for heading: DocumentOutline.Heading) -> some View {
        HStack(spacing: 4) {
            // Indentation makes the nesting legible; the chevron only appears where there is
            // something to collapse.
            if hasChildren(heading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { toggleCollapse(heading) }
                } label: {
                    Image(systemName: collapsed.contains(heading.id) ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed.contains(heading.id)
                                    ? "Expand \(heading.title)"
                                    : "Collapse \(heading.title)")
            } else {
                Spacer().frame(width: 20)
            }

            Button {
                onSelect(heading)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text(heading.title.isEmpty ? "Untitled" : heading.title)
                        .font(font(for: heading.level))
                        .lineLimit(1)
                    Spacer()
                    Text("\(heading.line + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(min(heading.level, 6) - 1) * 12)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Heading level \(heading.level), line \(heading.line + 1)")
    }

    // MARK: - Derived

    /// Search takes precedence over collapse: a heading that matches is shown even if an ancestor
    /// is collapsed, otherwise searching inside a collapsed section would find nothing.
    private var visibleHeadings: [DocumentOutline.Heading] {
        let matches = outline.filtered(by: query)
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return matches }

        var hidden = Set<Int>()
        for id in collapsed { hidden.formUnion(outline.descendantIDs(of: id)) }
        return matches.filter { !hidden.contains($0.id) }
    }

    private func hasChildren(_ heading: DocumentOutline.Heading) -> Bool {
        !heading.childIDs.isEmpty
    }

    private func toggleCollapse(_ heading: DocumentOutline.Heading) {
        if collapsed.contains(heading.id) {
            collapsed.remove(heading.id)
        } else {
            collapsed.insert(heading.id)
        }
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1:  return .headline
        case 2:  return .subheadline.weight(.semibold)
        case 3:  return .subheadline
        default: return .footnote
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DocumentOutlineView(
            outline: DocumentOutline.parse("""
            # Introduction
            Text.
            ## Background
            More.
            ### Detail
            Deep.
            ## Method
            Steps.
            # Results
            Numbers.
            """),
            onSelect: { _ in }
        )
    }
}
