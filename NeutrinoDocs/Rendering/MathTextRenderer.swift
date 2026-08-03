import Foundation

// MARK: - MathTextRenderer

/// Flattens a `MathNode` tree to a plain string, using Unicode super/subscripts where they exist.
///
/// Inline math has to live inside an `AttributedString` run — SwiftUI's `Text` cannot host a view —
/// so an inline `$x^2$` becomes "x²" rather than a laid-out fraction. Display math (`$$…$$`) is not
/// subject to this and gets the real two-dimensional layout in `MathView`.
///
/// Where Unicode has no equivalent (a fraction, a root), the TeX-ish source is kept in a readable
/// form: `a/b`, `√(x)`. That is a deliberate fallback, not a rendering — an author who wants a
/// stacked fraction should use display math.
enum MathTextRenderer {

    /// Unicode superscript forms. Several letters simply do not exist as superscripts, so a base
    /// that cannot be converted falls back to caret notation.
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "o": "ₒ",
        "x": "ₓ", "n": "ₙ", "m": "ₘ", "t": "ₜ", "k": "ₖ", "l": "ₗ",
    ]

    // MARK: - Entry point

    static func string(from source: String) -> String {
        render(MathParser.parse(source))
    }

    static func render(_ node: MathNode) -> String {
        switch node {
        case .row(let children):
            return children.map(render).joined()

        case .text(let string), .symbol(let string):
            return string

        case .identifier(let string):
            return string

        case .binaryOperator(let symbol):
            // Thin spaces keep `a+b` from reading as one token without the width of a real space.
            return "\u{2009}\(symbol)\u{2009}"

        case .function(let name):
            return name + "\u{2009}"

        case .textMode(let string):
            return string

        case .bigOperator(let symbol):
            return symbol

        case .fraction(let numerator, let denominator):
            return "\(wrapped(numerator))/\(wrapped(denominator))"

        case .sqrt(let radicand, let index):
            let root = index.map { "\(superscript(render($0)))√" } ?? "√"
            return "\(root)(\(render(radicand)))"

        case .superscript(let base, let exponent):
            return render(base) + superscript(render(exponent))

        case .subscript(let base, let subscriptNode):
            return render(base) + `subscript`(render(subscriptNode))

        case .subsuperscript(let base, let subscriptNode, let exponent):
            return render(base) + `subscript`(render(subscriptNode)) + superscript(render(exponent))

        case .delimited(let open, let content, let close):
            return open + render(content) + close

        case .unparsed(let source):
            return source
        }
    }

    // MARK: - Helpers

    /// Parenthesises a fraction operand only when it is more than a single atom, so `1/2` stays
    /// `1/2` while `(a+b)/2` keeps its grouping.
    private static func wrapped(_ node: MathNode) -> String {
        let rendered = render(node)
        switch node {
        case .row(let children) where children.count > 1:
            return "(\(rendered))"
        default:
            return rendered
        }
    }

    private static func superscript(_ string: String) -> String {
        convert(string, using: superscripts, fallbackPrefix: "^")
    }

    private static func `subscript`(_ string: String) -> String {
        convert(string, using: subscripts, fallbackPrefix: "_")
    }

    /// All-or-nothing: a script converts only if every character has a Unicode form, because a
    /// half-converted "x²ᵇ"-style run is harder to read than plain caret notation.
    private static func convert(_ string: String,
                                using table: [Character: Character],
                                fallbackPrefix: String) -> String {
        guard !string.isEmpty else { return "" }
        var converted = ""
        for character in string {
            guard let mapped = table[character] else {
                return string.count == 1
                    ? "\(fallbackPrefix)\(string)"
                    : "\(fallbackPrefix)(\(string))"
            }
            converted.append(mapped)
        }
        return converted
    }
}
