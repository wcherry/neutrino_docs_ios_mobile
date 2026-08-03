import SwiftUI

// MARK: - MermaidView

/// Draws a Mermaid flowchart natively — Phase 2 — Rich Markdown, "Mermaid".
///
/// Nodes are placed by `MermaidLayout` and edges drawn as orthogonal connectors between the
/// resulting frames. A diagram this parser does not understand (sequence, class, Gantt, or a
/// flowchart whose syntax it cannot read) falls back to its source in a code card, so the author
/// still sees what they wrote.
struct MermaidView: View {

    let source: String

    var body: some View {
        if let diagram = MermaidParser.parse(source), !diagram.nodes.isEmpty {
            DiagramCanvas(diagram: diagram)
        } else {
            MermaidFallbackView(source: source)
        }
    }
}

// MARK: - DiagramCanvas

private struct DiagramCanvas: View {

    let diagram: MermaidDiagram

    @Environment(\.colorScheme) private var colorScheme

    private var layout: MermaidLayout.Result {
        MermaidLayout.layout(diagram, metrics: .default)
    }

    var body: some View {
        let result = layout

        // A wide diagram scrolls inside its own card rather than forcing the document sideways.
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                edgeLayer(result)
                nodeLayer(result)
            }
            .frame(width: result.size.width, height: result.size.height)
            .padding(edgePadding)
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
    }

    /// Room for the arrow heads, edge labels, and the detour lane a rank-skipping edge routes
    /// along, all of which sit outside the node frames.
    private var edgePadding: EdgeInsets {
        EdgeInsets(top: 16, leading: 16, bottom: 28, trailing: 28)
    }

    // MARK: - Layers

    private func edgeLayer(_ result: MermaidLayout.Result) -> some View {
        ForEach(diagram.edges) { edge in
            if let from = result.placement(for: edge.from),
               let to = result.placement(for: edge.to) {
                MermaidEdgeView(edge: edge,
                                from: from.frame,
                                to: to.frame,
                                isVertical: diagram.direction == .topToBottom,
                                // An edge that skips a rank cannot be drawn straight: the ranks in
                                // between are full of nodes it would run through.
                                skipsRanks: abs(to.rank - from.rank) > 1,
                                bounds: result.size)
            }
        }
    }

    private func nodeLayer(_ result: MermaidLayout.Result) -> some View {
        ForEach(diagram.nodes) { node in
            if let placement = result.placement(for: node.id) {
                MermaidNodeView(node: node)
                    .frame(width: placement.frame.width, height: placement.frame.height)
                    .position(x: placement.frame.midX, y: placement.frame.midY)
            }
        }
    }

    // MARK: - Accessibility

    /// VoiceOver gets the graph as a sentence per edge — the shapes and arrows convey nothing on
    /// their own.
    private var accessibilityDescription: String {
        var parts: [String] = ["Flowchart with \(diagram.nodes.count) nodes."]
        for edge in diagram.edges {
            let from = diagram.node(id: edge.from)?.label ?? edge.from
            let to = diagram.node(id: edge.to)?.label ?? edge.to
            if let label = edge.label, !label.isEmpty {
                parts.append("\(from) to \(to), labelled \(label).")
            } else {
                parts.append("\(from) to \(to).")
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - MermaidNodeView

private struct MermaidNodeView: View {

    let node: MermaidDiagram.Node

    var body: some View {
        Text(node.label)
            .font(.caption)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.accentColor.opacity(0.12)))
            .overlay(shape.stroke(Color.accentColor.opacity(0.55), lineWidth: 1.2))
    }

    /// `AnyShape` is iOS 16+, which matches the deployment target, and keeps this from needing a
    /// separate view per shape.
    private var shape: AnyShape {
        switch node.shape {
        case .rectangle:     return AnyShape(Rectangle())
        case .rounded:       return AnyShape(RoundedRectangle(cornerRadius: 8))
        case .stadium:       return AnyShape(Capsule())
        case .circle:        return AnyShape(Ellipse())
        case .diamond:       return AnyShape(DiamondShape())
        case .hexagon:       return AnyShape(HexagonShape())
        case .subroutine:    return AnyShape(RoundedRectangle(cornerRadius: 2))
        case .parallelogram: return AnyShape(ParallelogramShape())
        }
    }
}

// MARK: - Shapes

private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.18
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct ParallelogramShape: Shape {
    func path(in rect: CGRect) -> Path {
        let skew = rect.width * 0.15
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - MermaidEdgeView

/// One connector: an orthogonal path from the edge of one node to the edge of the next, an arrow
/// head, and an optional label sitting on the line.
private struct MermaidEdgeView: View {

    let edge: MermaidDiagram.Edge
    let from: CGRect
    let to: CGRect
    let isVertical: Bool
    /// True when the edge spans more than one rank, so it has to detour around the nodes between.
    let skipsRanks: Bool
    /// The diagram's extent, used to pick a detour lane outside the node columns.
    let bounds: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            EdgePath(from: from, to: to, isVertical: isVertical,
                     detourLane: detourLane)
                .stroke(Color.secondary.opacity(0.7), style: strokeStyle)

            if edge.hasArrow {
                ArrowHead(at: arrowPoint, pointing: arrowDirection)
                    .fill(Color.secondary.opacity(0.7))
            }

            if let label = edge.label, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(.systemBackground).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .position(labelPoint)
            }
        }
    }

    private var strokeStyle: StrokeStyle {
        switch edge.style {
        case .solid:  return StrokeStyle(lineWidth: 1.4)
        case .thick:  return StrokeStyle(lineWidth: 2.8)
        case .dotted: return StrokeStyle(lineWidth: 1.4, dash: [4, 4])
        }
    }

    /// Where the line meets the destination node — the arrow head sits here.
    private var arrowPoint: CGPoint {
        if isVertical {
            return to.midY >= from.midY
                ? CGPoint(x: to.midX, y: to.minY)
                : CGPoint(x: to.midX, y: to.maxY)
        }
        return to.midX >= from.midX
            ? CGPoint(x: to.minX, y: to.midY)
            : CGPoint(x: to.maxX, y: to.midY)
    }

    private var arrowDirection: ArrowHead.Direction {
        if isVertical { return to.midY >= from.midY ? .down : .up }
        return to.midX >= from.midX ? .right : .left
    }

    /// The cross-axis position of the lane a rank-skipping edge detours along, or `nil` for a
    /// direct edge. Placed outside the node columns so it cannot cross one.
    private var detourLane: CGFloat? {
        guard skipsRanks else { return nil }
        return isVertical ? bounds.width + 12 : bounds.height + 12
    }

    /// A direct edge's label sits in the gap between the two nodes. A detouring edge's label sits
    /// out on its lane instead — the straight-line midpoint would land on whatever node the edge
    /// is routing around, and the gap it leaves from is already taken by the direct edge out of
    /// the same node.
    private var labelPoint: CGPoint {
        if isVertical {
            let goingDown = to.midY >= from.midY
            let exit = goingDown ? from.maxY : from.minY
            let entry = goingDown ? to.minY : to.maxY
            if let lane = detourLane {
                return CGPoint(x: lane, y: (exit + entry) / 2)
            }
            return CGPoint(x: (from.midX + to.midX) / 2, y: (exit + entry) / 2)
        }

        let goingRight = to.midX >= from.midX
        let exit = goingRight ? from.maxX : from.minX
        let entry = goingRight ? to.minX : to.maxX
        if let lane = detourLane {
            return CGPoint(x: (exit + entry) / 2, y: lane)
        }
        return CGPoint(x: (exit + entry) / 2, y: (from.midY + to.midY) / 2)
    }
}

// MARK: - EdgePath

/// An orthogonal connector. A straight line when the two nodes share a centre line, otherwise a
/// dog-leg through the midpoint of the gap between them — the same routing Mermaid itself uses.
private struct EdgePath: Shape {
    let from: CGRect
    let to: CGRect
    let isVertical: Bool
    /// Cross-axis position to route along when the edge skips ranks. `nil` draws directly.
    let detourLane: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if isVertical {
            let goingDown = to.midY >= from.midY
            let start = CGPoint(x: from.midX, y: goingDown ? from.maxY : from.minY)
            let end = CGPoint(x: to.midX, y: goingDown ? to.minY : to.maxY)
            path.move(to: start)

            if let lane = detourLane {
                // Out of the column, along the lane, then back in — clear of every rank between.
                let exit = start.y + (goingDown ? 12 : -12)
                let entry = end.y + (goingDown ? -12 : 12)
                path.addLine(to: CGPoint(x: start.x, y: exit))
                path.addLine(to: CGPoint(x: lane, y: exit))
                path.addLine(to: CGPoint(x: lane, y: entry))
                path.addLine(to: CGPoint(x: end.x, y: entry))
                path.addLine(to: end)
            } else if abs(start.x - end.x) < 0.5 {
                path.addLine(to: end)
            } else {
                let midY = (start.y + end.y) / 2
                path.addLine(to: CGPoint(x: start.x, y: midY))
                path.addLine(to: CGPoint(x: end.x, y: midY))
                path.addLine(to: end)
            }
        } else {
            let goingRight = to.midX >= from.midX
            let start = CGPoint(x: goingRight ? from.maxX : from.minX, y: from.midY)
            let end = CGPoint(x: goingRight ? to.minX : to.maxX, y: to.midY)
            path.move(to: start)

            if let lane = detourLane {
                let exit = start.x + (goingRight ? 12 : -12)
                let entry = end.x + (goingRight ? -12 : 12)
                path.addLine(to: CGPoint(x: exit, y: start.y))
                path.addLine(to: CGPoint(x: exit, y: lane))
                path.addLine(to: CGPoint(x: entry, y: lane))
                path.addLine(to: CGPoint(x: entry, y: end.y))
                path.addLine(to: end)
            } else if abs(start.y - end.y) < 0.5 {
                path.addLine(to: end)
            } else {
                let midX = (start.x + end.x) / 2
                path.addLine(to: CGPoint(x: midX, y: start.y))
                path.addLine(to: CGPoint(x: midX, y: end.y))
                path.addLine(to: end)
            }
        }

        return path
    }
}

// MARK: - ArrowHead

private struct ArrowHead: Shape {
    enum Direction { case up, down, left, right }

    let at: CGPoint
    let pointing: Direction

    private let size: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch pointing {
        case .down:
            path.move(to: at)
            path.addLine(to: CGPoint(x: at.x - size / 2, y: at.y - size))
            path.addLine(to: CGPoint(x: at.x + size / 2, y: at.y - size))
        case .up:
            path.move(to: at)
            path.addLine(to: CGPoint(x: at.x - size / 2, y: at.y + size))
            path.addLine(to: CGPoint(x: at.x + size / 2, y: at.y + size))
        case .right:
            path.move(to: at)
            path.addLine(to: CGPoint(x: at.x - size, y: at.y - size / 2))
            path.addLine(to: CGPoint(x: at.x - size, y: at.y + size / 2))
        case .left:
            path.move(to: at)
            path.addLine(to: CGPoint(x: at.x + size, y: at.y - size / 2))
            path.addLine(to: CGPoint(x: at.x + size, y: at.y + size / 2))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - MermaidFallbackView

/// Shown for diagram types this renderer does not lay out. Says so plainly and shows the source,
/// which is more useful than an empty box or a silent drop.
private struct MermaidFallbackView: View {

    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kindDescription, systemImage: "chart.xyaxis.line")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(source.trimmingCharacters(in: .newlines))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Names the diagram type when it can be read off the first line, so the message is specific
    /// rather than a generic failure.
    private var kindDescription: String {
        let first = source
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let keyword = first.split(separator: " ").first.map(String.init)?.lowercased() ?? ""

        switch keyword {
        case "sequencediagram": return "Sequence diagram — shown as source"
        case "classdiagram":    return "Class diagram — shown as source"
        case "statediagram", "statediagram-v2": return "State diagram — shown as source"
        case "erdiagram":       return "ER diagram — shown as source"
        case "gantt":           return "Gantt chart — shown as source"
        case "pie":             return "Pie chart — shown as source"
        case "journey":         return "User journey — shown as source"
        default:                return "Mermaid diagram — shown as source"
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            MermaidView(source: """
            graph TD
                A[Start] --> B{Signed in?}
                B -->|Yes| C[Open document]
                B -->|No| D[Show login]
                D --> C
                C --> E[Edit]
            """)

            MermaidView(source: """
            flowchart LR
                A((Draft)) --> B([Review])
                B --> C{Approved}
                C -->|yes| D[Publish]
                C -->|no| A
            """)

            MermaidView(source: """
            sequenceDiagram
                Alice->>Bob: Hello
            """)
        }
        .padding()
    }
}
