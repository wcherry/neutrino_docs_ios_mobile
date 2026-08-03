import Foundation

// MARK: - MermaidDiagram

/// A parsed Mermaid flowchart — Phase 2 — Rich Markdown, "Mermaid".
///
/// Only the flowchart family (`graph` / `flowchart`) is modelled. That is what documentation
/// actually contains, and it is the one Mermaid dialect whose layout can be done natively rather
/// than by shipping a JavaScript engine in a web view. Sequence, class, and Gantt diagrams parse to
/// `nil` and fall back to showing their source, which is honest about what is supported.
struct MermaidDiagram: Equatable {

    var direction: Direction
    var nodes: [Node]
    var edges: [Edge]

    // MARK: - Direction

    enum Direction: String, Equatable {
        case topToBottom
        case leftToRight

        /// Mermaid spells this `TD`, `TB`, `LR`, `RL`, `BT`. `RL` and `BT` are reversed axes; they
        /// are mapped onto their forward equivalents rather than rendered mirrored, so the graph is
        /// readable even though the arrow order differs from Mermaid's own output.
        init(token: String) {
            switch token.uppercased() {
            case "LR", "RL": self = .leftToRight
            default:         self = .topToBottom
            }
        }
    }

    // MARK: - Node

    struct Node: Equatable, Identifiable {
        let id: String
        var label: String
        var shape: Shape
    }

    enum Shape: Equatable {
        case rectangle
        case rounded
        case stadium
        case circle
        case diamond
        case hexagon
        case subroutine
        case parallelogram
    }

    // MARK: - Edge

    struct Edge: Equatable, Identifiable {
        let from: String
        let to: String
        var label: String?
        var style: Style
        /// Whether the edge draws an arrow head at its destination.
        var hasArrow: Bool

        var id: String { "\(from)->\(to)-\(label ?? "")" }

        enum Style: Equatable {
            case solid
            case dotted
            case thick
        }
    }

    /// Node lookup by id, for the renderer's edge drawing.
    func node(id: String) -> Node? {
        nodes.first { $0.id == id }
    }
}

// MARK: - MermaidParser

/// Parses the Mermaid flowchart subset into a `MermaidDiagram`.
///
/// Handles the node shapes (`[]`, `()`, `([])`, `(())`, `{}`, `{{}}`, `[[]]`, `[//]`), the edge
/// forms (`-->`, `---`, `-.->`, `==>`), both label styles (`-->|text|` and `-- text -->`),
/// declaration-only nodes, chained edges (`A --> B --> C`), and `subgraph` blocks (flattened —
/// their nodes are kept, the grouping box is not drawn).
enum MermaidParser {

    /// Diagram headers this parser can render. Anything else returns `nil`.
    private static let flowchartKeywords = ["graph", "flowchart"]

    // MARK: - Entry point

    static func parse(_ source: String) -> MermaidDiagram? {
        let lines = source
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }   // `%%` is a Mermaid comment

        guard let header = lines.first else { return nil }
        let headerParts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard let keyword = headerParts.first?.lowercased(),
              flowchartKeywords.contains(keyword) else { return nil }

        let direction = MermaidDiagram.Direction(
            token: headerParts.count > 1 ? headerParts[1].trimmingCharacters(in: .whitespaces) : "TD"
        )

        var builder = Builder()
        for line in lines.dropFirst() {
            builder.consume(line)
        }

        guard !builder.nodes.isEmpty else { return nil }
        return MermaidDiagram(direction: direction, nodes: builder.orderedNodes, edges: builder.edges)
    }

    // MARK: - Builder

    /// Accumulates nodes and edges, keeping first-seen order so layout is deterministic.
    private struct Builder {
        private(set) var nodes: [String: MermaidDiagram.Node] = [:]
        private(set) var order: [String] = []
        private(set) var edges: [MermaidDiagram.Edge] = []

        var orderedNodes: [MermaidDiagram.Node] { order.compactMap { nodes[$0] } }

        mutating func consume(_ line: String) {
            // `subgraph`/`end` only group nodes visually; the nodes inside are parsed normally.
            let lowered = line.lowercased()
            if lowered.hasPrefix("subgraph") || lowered == "end" { return }
            // Styling directives carry no structure.
            if ["style", "classdef", "class", "linkstyle", "click"].contains(where: {
                lowered.hasPrefix($0 + " ")
            }) { return }

            let segments = Tokenizer.split(line)
            guard !segments.isEmpty else { return }

            // A line with no edge is a bare node declaration.
            guard segments.count > 1 else {
                if case .node(let text) = segments[0] { declare(text) }
                return
            }

            // Walk the alternating node / connector sequence so `A --> B --> C` chains.
            var previousID: String?
            var pendingConnector: Tokenizer.Connector?

            for segment in segments {
                switch segment {
                case .node(let text):
                    let id = declare(text)
                    if let previousID, let connector = pendingConnector {
                        edges.append(MermaidDiagram.Edge(from: previousID,
                                                         to: id,
                                                         label: connector.label,
                                                         style: connector.style,
                                                         hasArrow: connector.hasArrow))
                    }
                    previousID = id
                    pendingConnector = nil

                case .connector(let connector):
                    pendingConnector = connector
                }
            }
        }

        /// Registers a node from its source text, returning its id. A later mention carrying a
        /// label upgrades an earlier bare reference, which is how Mermaid itself behaves.
        @discardableResult
        private mutating func declare(_ text: String) -> String {
            let parsed = NodeSyntax.parse(text)
            if var existing = nodes[parsed.id] {
                if let label = parsed.label {
                    existing.label = label
                    existing.shape = parsed.shape
                    nodes[parsed.id] = existing
                }
                return parsed.id
            }
            nodes[parsed.id] = MermaidDiagram.Node(id: parsed.id,
                                                   label: parsed.label ?? parsed.id,
                                                   shape: parsed.shape)
            order.append(parsed.id)
            return parsed.id
        }
    }

    // MARK: - Node syntax

    /// Splits `A[Label]` into an id, an optional label, and a shape.
    enum NodeSyntax {
        struct Parsed {
            let id: String
            let label: String?
            let shape: MermaidDiagram.Shape
        }

        /// Longest opener first, so `((` is not mistaken for `(`.
        private static let brackets: [(open: String, close: String, shape: MermaidDiagram.Shape)] = [
            ("((", "))", .circle),
            ("([", "])", .stadium),
            ("[[", "]]", .subroutine),
            ("{{", "}}", .hexagon),
            ("[/", "/]", .parallelogram),
            ("[", "]", .rectangle),
            ("(", ")", .rounded),
            ("{", "}", .diamond),
            (">", "]", .parallelogram),
        ]

        static func parse(_ text: String) -> Parsed {
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            for bracket in brackets {
                guard let openRange = trimmed.range(of: bracket.open),
                      trimmed.hasSuffix(bracket.close),
                      trimmed.distance(from: trimmed.startIndex, to: openRange.lowerBound) > 0
                else { continue }

                let id = String(trimmed[trimmed.startIndex..<openRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let labelStart = openRange.upperBound
                let labelEnd = trimmed.index(trimmed.endIndex, offsetBy: -bracket.close.count)
                guard labelStart <= labelEnd else { continue }

                let label = unquote(String(trimmed[labelStart..<labelEnd]))
                return Parsed(id: id, label: label, shape: bracket.shape)
            }

            return Parsed(id: trimmed, label: nil, shape: .rectangle)
        }

        private static func unquote(_ string: String) -> String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
                return trimmed
            }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    // MARK: - Tokenizer

    /// Splits a flowchart line into alternating node and connector segments.
    enum Tokenizer {
        struct Connector: Equatable {
            var label: String?
            var style: MermaidDiagram.Edge.Style
            var hasArrow: Bool
        }

        enum Segment: Equatable {
            case node(String)
            case connector(Connector)
        }

        /// Arrow bodies, longest first so `-.->` is not read as `-` then `.` then `->`.
        private static let arrows: [(token: String, style: MermaidDiagram.Edge.Style, arrow: Bool)] = [
            ("-.->", .dotted, true),
            ("-.-",  .dotted, false),
            ("==>",  .thick,  true),
            ("===",  .thick,  false),
            ("-->",  .solid,  true),
            ("---",  .solid,  false),
            ("--o",  .solid,  true),
            ("--x",  .solid,  true),
            ("->",   .solid,  true),
            // The opening halves of the `A -- label --> B` and `A == label ==> B` forms. Listed
            // last so the complete arrows above always win; `coalesceMidArrowLabels` folds the
            // connector / node / connector triple these produce back into one labelled edge.
            ("--",   .solid,  false),
            ("==",   .thick,  false),
        ]

        static func split(_ line: String) -> [Segment] {
            var segments: [Segment] = []
            var buffer = ""
            var index = line.startIndex

            /// Node text between connectors; brackets are tracked so an arrow inside a label
            /// (`A[a --> b]`) is not mistaken for a connector.
            var bracketDepth = 0
            var insideQuotes = false

            func flushNode() {
                let text = buffer.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { segments.append(.node(text)) }
                buffer = ""
            }

            while index < line.endIndex {
                let character = line[index]

                if character == "\"" { insideQuotes.toggle() }
                if !insideQuotes {
                    if "([{".contains(character) { bracketDepth += 1 }
                    if ")]}".contains(character) { bracketDepth = max(0, bracketDepth - 1) }
                }

                if bracketDepth == 0, !insideQuotes,
                   let match = matchArrow(in: line, at: index) {
                    flushNode()
                    var connector = Connector(label: nil, style: match.style, hasArrow: match.arrow)
                    index = match.end

                    // `-->|label|`
                    if index < line.endIndex, line[index] == "|" {
                        let afterPipe = line.index(after: index)
                        if let closing = line[afterPipe...].firstIndex(of: "|") {
                            connector.label = String(line[afterPipe..<closing])
                                .trimmingCharacters(in: .whitespaces)
                            index = line.index(after: closing)
                        }
                    }

                    segments.append(.connector(connector))
                    continue
                }

                buffer.append(character)
                index = line.index(after: index)
            }

            flushNode()
            return coalesceMidArrowLabels(segments)
        }

        private static func matchArrow(
            in line: String, at index: String.Index
        ) -> (style: MermaidDiagram.Edge.Style, arrow: Bool, end: String.Index)? {
            for arrow in arrows {
                guard let end = line.index(index, offsetBy: arrow.token.count, limitedBy: line.endIndex),
                      line[index..<end] == arrow.token else { continue }
                return (arrow.style, arrow.arrow, end)
            }
            return nil
        }

        /// Folds the `A -- label --> B` form, which tokenizes as connector / node / connector, into
        /// a single labelled connector.
        private static func coalesceMidArrowLabels(_ segments: [Segment]) -> [Segment] {
            var result: [Segment] = []
            var index = 0

            while index < segments.count {
                if case .connector(let first) = segments[index],
                   index + 2 < segments.count,
                   case .node(let text) = segments[index + 1],
                   case .connector(let second) = segments[index + 2],
                   !first.hasArrow {
                    // The label rides on the *second* connector, which is the one with the arrow.
                    result.append(.connector(Connector(label: text,
                                                       style: second.style,
                                                       hasArrow: second.hasArrow)))
                    index += 3
                    continue
                }
                result.append(segments[index])
                index += 1
            }

            return result
        }
    }
}
