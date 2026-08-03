import CoreGraphics
import Foundation

// MARK: - MermaidLayout

/// Assigns every node in a flowchart a place on a grid — Phase 2's native Mermaid rendering.
///
/// A layered ("Sugiyama-style") layout, minus the crossing-minimisation sweep: nodes are ranked by
/// their longest path from a root, ordered within a rank by the average position of their parents,
/// and spaced evenly. That is enough for the small, mostly-tree flowcharts documentation contains,
/// and it is deterministic, which matters because the result is asserted in tests.
///
/// Pure geometry with no view types — the sizing constants come in from the renderer so Dynamic
/// Type can change them without this file knowing anything about fonts.
enum MermaidLayout {

    // MARK: - Metrics

    /// The measurements the caller supplies, derived from the current font.
    struct Metrics: Equatable {
        var nodeWidth: CGFloat = 132
        var nodeHeight: CGFloat = 48
        /// Gap between one rank and the next, along the flow direction.
        var rankSpacing: CGFloat = 52
        /// Gap between siblings within a rank.
        var siblingSpacing: CGFloat = 20

        static let `default` = Metrics()
    }

    // MARK: - Result

    struct Result: Equatable {
        var placements: [Placement]
        var size: CGSize

        func placement(for id: String) -> Placement? {
            placements.first { $0.id == id }
        }
    }

    struct Placement: Equatable, Identifiable {
        let id: String
        /// Distance from the start of the flow — row for top-to-bottom, column for left-to-right.
        let rank: Int
        /// Position within the rank.
        let indexInRank: Int
        var frame: CGRect
    }

    // MARK: - Entry point

    static func layout(_ diagram: MermaidDiagram, metrics: Metrics = .default) -> Result {
        guard !diagram.nodes.isEmpty else {
            return Result(placements: [], size: .zero)
        }

        let ranks = assignRanks(diagram)
        let ordered = orderWithinRanks(diagram, ranks: ranks)
        return position(diagram, ranksByNode: ranks, nodesByRank: ordered, metrics: metrics)
    }

    // MARK: - Ranking

    /// Longest-path ranking: a node sits one rank below its deepest parent. Cycles are broken by
    /// refusing to revisit a node already on the current path, so a cyclic graph still lays out
    /// instead of recursing forever.
    private static func assignRanks(_ diagram: MermaidDiagram) -> [String: Int] {
        var incoming: [String: [String]] = [:]
        for edge in diagram.edges where edge.from != edge.to {
            incoming[edge.to, default: []].append(edge.from)
        }

        var ranks: [String: Int] = [:]
        var resolving: Set<String> = []

        func rank(of id: String) -> Int {
            if let known = ranks[id] { return known }
            // Already on the path: this edge closes a cycle and is ignored for ranking.
            guard !resolving.contains(id) else { return 0 }

            guard let parents = incoming[id], !parents.isEmpty else {
                ranks[id] = 0
                return 0
            }

            resolving.insert(id)
            let value = parents.map { rank(of: $0) + 1 }.max() ?? 0
            resolving.remove(id)
            ranks[id] = value
            return value
        }

        for node in diagram.nodes { _ = rank(of: node.id) }
        return ranks
    }

    // MARK: - Ordering

    /// Orders each rank by the mean position of a node's parents in the rank above, which pulls
    /// children under their parents and keeps most edges from crossing. Ties keep declaration
    /// order, so the layout is stable.
    private static func orderWithinRanks(_ diagram: MermaidDiagram,
                                         ranks: [String: Int]) -> [Int: [String]] {
        var declarationIndex: [String: Int] = [:]
        for (index, node) in diagram.nodes.enumerated() { declarationIndex[node.id] = index }

        var byRank: [Int: [String]] = [:]
        for node in diagram.nodes {
            byRank[ranks[node.id] ?? 0, default: []].append(node.id)
        }

        var parents: [String: [String]] = [:]
        for edge in diagram.edges where edge.from != edge.to {
            parents[edge.to, default: []].append(edge.from)
        }

        // Rank 0 keeps declaration order; each later rank is sorted against the one before it.
        var positionInRank: [String: Int] = [:]
        for rank in byRank.keys.sorted() {
            let ids = byRank[rank]!.sorted { left, right in
                let leftKey = barycenter(of: left, parents: parents, positions: positionInRank)
                let rightKey = barycenter(of: right, parents: parents, positions: positionInRank)
                if leftKey != rightKey { return leftKey < rightKey }
                return (declarationIndex[left] ?? 0) < (declarationIndex[right] ?? 0)
            }
            byRank[rank] = ids
            for (index, id) in ids.enumerated() { positionInRank[id] = index }
        }

        return byRank
    }

    /// A node with no placed parent sorts to the end of its rank rather than the start — it is a
    /// fresh root, and putting it first would push the connected part of the graph sideways.
    private static func barycenter(of id: String,
                                   parents: [String: [String]],
                                   positions: [String: Int]) -> Double {
        let placed = (parents[id] ?? []).compactMap { positions[$0] }
        guard !placed.isEmpty else { return .greatestFiniteMagnitude }
        return Double(placed.reduce(0, +)) / Double(placed.count)
    }

    // MARK: - Positioning

    private static func position(_ diagram: MermaidDiagram,
                                 ranksByNode: [String: Int],
                                 nodesByRank: [Int: [String]],
                                 metrics: Metrics) -> Result {
        let isVertical = diagram.direction == .topToBottom
        let ranks = nodesByRank.keys.sorted()

        // The widest rank sets the cross-axis extent; narrower ranks are centred within it.
        let widestCount = nodesByRank.values.map(\.count).max() ?? 1
        let crossNodeSize = isVertical ? metrics.nodeWidth : metrics.nodeHeight
        let crossExtent = CGFloat(widestCount) * crossNodeSize
            + CGFloat(max(0, widestCount - 1)) * metrics.siblingSpacing

        let flowNodeSize = isVertical ? metrics.nodeHeight : metrics.nodeWidth
        let flowExtent = CGFloat(ranks.count) * flowNodeSize
            + CGFloat(max(0, ranks.count - 1)) * metrics.rankSpacing

        var placements: [Placement] = []

        for rank in ranks {
            let ids = nodesByRank[rank] ?? []
            let count = ids.count
            let rowExtent = CGFloat(count) * crossNodeSize
                + CGFloat(max(0, count - 1)) * metrics.siblingSpacing
            let crossStart = (crossExtent - rowExtent) / 2
            let flowOffset = CGFloat(rank) * (flowNodeSize + metrics.rankSpacing)

            for (index, id) in ids.enumerated() {
                let crossOffset = crossStart + CGFloat(index) * (crossNodeSize + metrics.siblingSpacing)
                let origin = isVertical
                    ? CGPoint(x: crossOffset, y: flowOffset)
                    : CGPoint(x: flowOffset, y: crossOffset)
                placements.append(Placement(
                    id: id,
                    rank: rank,
                    indexInRank: index,
                    frame: CGRect(origin: origin,
                                  size: CGSize(width: metrics.nodeWidth, height: metrics.nodeHeight))
                ))
            }
        }

        // Keep the declared node order in the result so rendering order is predictable.
        let orderByID = Dictionary(uniqueKeysWithValues: diagram.nodes.enumerated().map { ($1.id, $0) })
        placements.sort { (orderByID[$0.id] ?? 0) < (orderByID[$1.id] ?? 0) }

        let size = isVertical
            ? CGSize(width: crossExtent, height: flowExtent)
            : CGSize(width: flowExtent, height: crossExtent)

        return Result(placements: placements, size: size)
    }
}
