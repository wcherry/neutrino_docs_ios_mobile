import SwiftUI

// MARK: - MathView

/// Lays out a `MathNode` tree two-dimensionally — Phase 2 — Rich Markdown, "Math".
///
/// Used for display math (`$$…$$` and ```math fences), where fractions stack, roots get a radical,
/// and scripts sit at the right optical size. Inline math takes the flattened Unicode path in
/// `MathTextRenderer` instead, because a SwiftUI `Text` run cannot contain a view.
struct MathView: View {

    let source: String
    /// Display math is centred and set a little larger than body text, the way TeX sets it.
    var isDisplay: Bool = true

    var body: some View {
        MathNodeView(node: MathParser.parse(source), scale: 1)
            .font(.system(size: baseSize, design: .serif))
            .frame(maxWidth: .infinity, alignment: isDisplay ? .center : .leading)
            .padding(.vertical, isDisplay ? 8 : 0)
            .textSelection(.enabled)
            .accessibilityLabel(Text(MathAccessibility.describe(source)))
    }

    private var baseSize: CGFloat { isDisplay ? 20 : 17 }
}

// MARK: - MathNodeView

/// Renders one node, recursing into its children. Split out from `MathView` so the recursion has
/// somewhere to carry the current script scale.
struct MathNodeView: View {

    let node: MathNode
    /// Shrinks with nesting depth, the way TeX steps down through script styles. Bottoming out
    /// stops a deeply nested exponent from becoming unreadable.
    let scale: CGFloat

    private var scriptScale: CGFloat { max(scale * 0.72, 0.45) }

    var body: some View {
        switch node {
        case .row(let children):
            HStack(alignment: .mathBaseline, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    MathNodeView(node: child, scale: scale)
                }
            }

        case .text(let string):
            scaledText(string)

        case .identifier(let name):
            scaledText(name).italic()

        case .symbol(let symbol):
            scaledText(symbol)

        case .binaryOperator(let symbol):
            scaledText(symbol).padding(.horizontal, 3 * scale)

        case .function(let name):
            scaledText(name).padding(.trailing, 2 * scale)

        case .textMode(let string):
            scaledText(string)

        case .bigOperator(let symbol):
            scaledText(symbol)
                .font(.system(size: 22 * scale, design: .serif))
                .padding(.horizontal, 2 * scale)

        case .fraction(let numerator, let denominator):
            FractionView(numerator: numerator, denominator: denominator, scale: scale)

        case .sqrt(let radicand, let index):
            RadicalView(radicand: radicand, index: index, scale: scale)

        case .superscript(let base, let exponent):
            HStack(alignment: .mathBaseline, spacing: 0) {
                MathNodeView(node: base, scale: scale)
                MathNodeView(node: exponent, scale: scriptScale)
                    .alignmentGuide(.mathBaseline) { $0[.mathBaseline] + $0.height * 0.42 }
            }

        case .subscript(let base, let subscriptNode):
            HStack(alignment: .mathBaseline, spacing: 0) {
                MathNodeView(node: base, scale: scale)
                MathNodeView(node: subscriptNode, scale: scriptScale)
                    .alignmentGuide(.mathBaseline) { $0[.mathBaseline] - $0.height * 0.22 }
            }

        case .subsuperscript(let base, let subscriptNode, let exponent):
            HStack(alignment: .mathBaseline, spacing: 0) {
                MathNodeView(node: base, scale: scale)
                // Both scripts share one column so they stack rather than run on.
                VStack(alignment: .leading, spacing: 0) {
                    MathNodeView(node: exponent, scale: scriptScale)
                    MathNodeView(node: subscriptNode, scale: scriptScale)
                }
            }

        case .delimited(let open, let content, let close):
            DelimitedView(open: open, content: content, close: close, scale: scale)

        case .unparsed(let source):
            // An unsupported command shows its own source rather than vanishing.
            scaledText(source)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func scaledText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 20 * scale, design: .serif))
    }
}

// MARK: - FractionView

private struct FractionView: View {
    let numerator: MathNode
    let denominator: MathNode
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2 * scale) {
            MathNodeView(node: numerator, scale: scale * 0.95)
            Rectangle()
                .frame(height: max(1, 1.2 * scale))
            MathNodeView(node: denominator, scale: scale * 0.95)
        }
        .fixedSize()
        .padding(.horizontal, 3 * scale)
        // The bar, not the baseline of either operand, is what should line up with surrounding
        // text — otherwise a fraction sits visibly low in a formula.
        .alignmentGuide(.mathBaseline) { $0.height * 0.58 }
    }
}

// MARK: - RadicalView

private struct RadicalView: View {
    let radicand: MathNode
    let index: MathNode?
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let index {
                MathNodeView(node: index, scale: max(scale * 0.55, 0.4))
                    .offset(y: 2 * scale)
            }
            Text("√")
                .font(.system(size: 20 * scale, design: .serif))
            // The overbar is what makes the extent of the root unambiguous.
            MathNodeView(node: radicand, scale: scale)
                .padding(.horizontal, 2 * scale)
                .overlay(alignment: .top) {
                    Rectangle().frame(height: max(1, 1.2 * scale))
                }
        }
        .fixedSize()
    }
}

// MARK: - DelimitedView

/// `\left( … \right)`. The delimiters scale with their content, which is the whole reason the
/// parser keeps them as a node instead of plain text.
private struct DelimitedView: View {
    let open: String
    let content: MathNode
    let close: String
    let scale: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .mathBaseline, spacing: 1) {
            delimiter(open)
            MathNodeView(node: content, scale: scale)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MathHeightKey.self, value: proxy.size.height)
                    }
                )
            delimiter(close)
        }
        .onPreferenceChange(MathHeightKey.self) { contentHeight = $0 }
    }

    @ViewBuilder
    private func delimiter(_ symbol: String) -> some View {
        if symbol.isEmpty {
            EmptyView()
        } else {
            Text(symbol)
                .font(.system(size: 20 * scale, design: .serif))
                .scaleEffect(x: 1, y: verticalStretch, anchor: .center)
        }
    }

    /// Grows the glyph to match tall content (a fraction, a stacked script) but never shrinks it
    /// below its natural size.
    private var verticalStretch: CGFloat {
        let natural = 24 * scale
        guard contentHeight > natural else { return 1 }
        return min(contentHeight / natural, 2.4)
    }
}

private struct MathHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Math baseline

extension VerticalAlignment {
    /// A shared baseline for math atoms.
    ///
    /// `.firstTextBaseline` cannot be used: a fraction or a radical is a composed view with no text
    /// baseline of its own, and would align by its top edge instead, dropping the rest of the
    /// formula. Each composed view publishes its own optical centre through this guide.
    private enum MathBaselineID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.firstTextBaseline]
        }
    }

    static let mathBaseline = VerticalAlignment(MathBaselineID.self)
}

// MARK: - MathAccessibility

/// Speaks a formula as words, since the rendered glyphs mean nothing to VoiceOver.
enum MathAccessibility {
    static func describe(_ source: String) -> String {
        let spoken = describe(MathParser.parse(source))
        return spoken.isEmpty ? "empty formula" : "formula: \(spoken)"
    }

    private static func describe(_ node: MathNode) -> String {
        switch node {
        case .row(let children):
            return children.map(describe).joined(separator: " ")
        case .text(let string), .symbol(let string), .textMode(let string):
            return string
        case .identifier(let name):
            return name
        case .binaryOperator(let symbol):
            return spokenOperator(symbol)
        case .function(let name), .bigOperator(let name):
            return name
        case .fraction(let numerator, let denominator):
            return "\(describe(numerator)) over \(describe(denominator))"
        case .sqrt(let radicand, let index):
            guard let index else { return "square root of \(describe(radicand))" }
            return "root \(describe(index)) of \(describe(radicand))"
        case .superscript(let base, let exponent):
            return "\(describe(base)) to the power \(describe(exponent))"
        case .subscript(let base, let subscriptNode):
            return "\(describe(base)) sub \(describe(subscriptNode))"
        case .subsuperscript(let base, let subscriptNode, let exponent):
            return "\(describe(base)) sub \(describe(subscriptNode)) to the power \(describe(exponent))"
        case .delimited(_, let content, _):
            return "open bracket \(describe(content)) close bracket"
        case .unparsed(let source):
            return source
        }
    }

    private static func spokenOperator(_ symbol: String) -> String {
        switch symbol {
        case "+": return "plus"
        case "-": return "minus"
        case "=": return "equals"
        case "×": return "times"
        case "÷": return "divided by"
        case "±": return "plus or minus"
        case "≤": return "less than or equal to"
        case "≥": return "greater than or equal to"
        case "≠": return "not equal to"
        case "≈": return "approximately"
        case "<": return "less than"
        case ">": return "greater than"
        default:  return symbol
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            MathView(source: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#)
            MathView(source: #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#)
            MathView(source: #"e^{i\pi} + 1 = 0"#)
            MathView(source: #"\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}"#)
        }
        .padding()
    }
}
