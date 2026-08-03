import Foundation

// MARK: - MathNode

/// A parsed TeX-subset math expression — Phase 2 — Rich Markdown, "Math".
///
/// The tree is pure data with no view types, so the parser can be asserted directly in tests and
/// `MathView` is only a layout pass over it.
indirect enum MathNode: Equatable {
    /// Several nodes laid out left to right on one baseline.
    case row([MathNode])
    /// A literal run: digits, letters, or punctuation that needs no special treatment.
    case text(String)
    /// A variable, set in italic the way TeX sets identifiers.
    case identifier(String)
    /// A binary or relational operator, which gets air on both sides.
    case binaryOperator(String)
    /// A symbol that stands alone (∞, ∂, a Greek letter).
    case symbol(String)
    /// A named function set upright: sin, cos, log, lim.
    case function(String)
    case fraction(numerator: MathNode, denominator: MathNode)
    case sqrt(radicand: MathNode, index: MathNode?)
    case superscript(base: MathNode, exponent: MathNode)
    case `subscript`(base: MathNode, subscriptNode: MathNode)
    /// Both at once, stacked on the same base — `x_i^2`.
    case subsuperscript(base: MathNode, subscriptNode: MathNode, exponent: MathNode)
    /// A large operator that can carry limits: ∑, ∏, ∫.
    case bigOperator(String)
    /// `\text{…}` — upright prose inside a formula.
    case textMode(String)
    /// A bracketed group, kept as a node so delimiters can grow with their content.
    case delimited(open: String, content: MathNode, close: String)
    /// Source the parser could not make sense of, preserved verbatim so nothing is silently lost.
    case unparsed(String)

    var isEmpty: Bool {
        if case .row(let children) = self { return children.isEmpty }
        return false
    }
}

// MARK: - MathParser

/// Parses the TeX subset that documents actually use into a `MathNode` tree.
///
/// Supported: `^` and `_` scripts, `\frac`, `\sqrt` (with an optional index), `{}` grouping,
/// `\left`/`\right` delimiters, `\text`, named functions, and a table of Greek letters and
/// operators. Anything else is preserved as `.unparsed` rather than dropped — an unrenderable
/// formula should still show the author their own source.
enum MathParser {

    // MARK: - Symbol tables

    /// Commands that stand for a single character.
    static let symbols: [String: String] = [
        // Lowercase Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Uppercase Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Standalone symbols
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃",
        "emptyset": "∅", "varnothing": "∅", "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "prime": "′", "degree": "°", "dots": "…", "ldots": "…",
        "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "angle": "∠", "triangle": "△",
    ]

    /// Commands that behave as binary or relational operators.
    static let operators: [String: String] = [
        "times": "×", "div": "÷", "cdot": "·", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "in": "∈", "notin": "∉", "ni": "∋", "cup": "∪", "cap": "∩", "setminus": "∖",
        "land": "∧", "lor": "∨", "lnot": "¬", "neg": "¬",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "mapsto": "↦", "implies": "⟹", "iff": "⟺", "perp": "⊥", "parallel": "∥",
        "oplus": "⊕", "otimes": "⊗", "circ": "∘", "bullet": "∙",
    ]

    /// Large operators, which take limits above and below in display mode.
    static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭",
        "oint": "∮", "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
        "lim": "lim", "max": "max", "min": "min", "sup": "sup", "inf": "inf",
    ]

    /// Functions set upright rather than italic.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp", "det", "dim", "ker", "deg", "gcd", "arg", "mod",
    ]

    private static let openDelimiters: Set<Character> = ["(", "[", "|"]
    private static let closeDelimiters: Set<Character> = [")", "]", "|"]

    // MARK: - Entry point

    static func parse(_ source: String) -> MathNode {
        var scanner = Scanner(source: Array(source))
        let node = scanner.parseRow(until: nil)
        return node
    }

    // MARK: - Scanner

    private struct Scanner {
        let source: [Character]
        var index = 0

        var isAtEnd: Bool { index >= source.count }

        func peek(_ offset: Int = 0) -> Character? {
            let target = index + offset
            return target < source.count ? source[target] : nil
        }

        mutating func advance() -> Character? {
            guard !isAtEnd else { return nil }
            defer { index += 1 }
            return source[index]
        }

        // MARK: Rows

        /// Parses nodes until `terminator` (consumed by the caller) or the end of the input.
        mutating func parseRow(until terminator: Character?) -> MathNode {
            var nodes: [MathNode] = []

            while let character = peek() {
                if let terminator, character == terminator { break }
                // A stray `}` ends an implicit group rather than being consumed as text.
                if terminator == nil, character == "}" { break }

                guard let node = parseScripted() else { break }
                nodes.append(node)
            }

            return nodes.count == 1 ? nodes[0] : .row(nodes)
        }

        /// Parses one atom together with any `^`/`_` scripts attached to it.
        mutating func parseScripted() -> MathNode? {
            guard var base = parseAtom() else { return nil }

            var exponent: MathNode?
            var subscriptNode: MathNode?

            // `x^2_i` and `x_i^2` mean the same thing, so both orders are accepted.
            while let character = peek(), character == "^" || character == "_" {
                _ = advance()
                skipWhitespace()
                let script = parseAtom() ?? .row([])
                if character == "^" {
                    exponent = exponent.map { .row([$0, script]) } ?? script
                } else {
                    subscriptNode = subscriptNode.map { .row([$0, script]) } ?? script
                }
            }

            switch (subscriptNode, exponent) {
            case (nil, nil):
                return base
            case (nil, .some(let exp)):
                return .superscript(base: base, exponent: exp)
            case (.some(let sub), nil):
                return .subscript(base: base, subscriptNode: sub)
            case (.some(let sub), .some(let exp)):
                base = .subsuperscript(base: base, subscriptNode: sub, exponent: exp)
                return base
            }
        }

        // MARK: Atoms

        mutating func parseAtom() -> MathNode? {
            skipWhitespace()
            guard let character = peek() else { return nil }

            switch character {
            case "{":
                _ = advance()
                let content = parseRow(until: "}")
                expect("}")
                return content

            case "\\":
                return parseCommand()

            case "^", "_":
                // A script with nothing to attach to — the caller handles the well-formed case.
                return nil

            default:
                return parseLiteral()
            }
        }

        /// Runs of digits and letters group into one node; everything else is taken one character
        /// at a time so operators keep their own spacing.
        mutating func parseLiteral() -> MathNode? {
            guard let character = peek() else { return nil }

            if character.isNumber {
                var digits = ""
                while let next = peek(), next.isNumber || next == "." {
                    digits.append(next)
                    _ = advance()
                }
                return .text(digits)
            }

            if character.isLetter {
                // Single letters are variables. A run of letters is still a run of variables in
                // TeX (`xy` is x·y), so each becomes its own italic identifier.
                _ = advance()
                return .identifier(String(character))
            }

            _ = advance()

            if isOperatorCharacter(character) {
                return .binaryOperator(String(character))
            }
            if openDelimiters.contains(character) || closeDelimiters.contains(character) {
                return .text(String(character))
            }
            return .text(String(character))
        }

        private func isOperatorCharacter(_ character: Character) -> Bool {
            "+-=<>*/±×÷≤≥≠".contains(character)
        }

        // MARK: Commands

        mutating func parseCommand() -> MathNode? {
            expect("\\")

            // An escaped delimiter or symbol: `\{`, `\%`, `\$`.
            if let character = peek(), !character.isLetter {
                _ = advance()
                return .text(String(character))
            }

            var name = ""
            while let character = peek(), character.isLetter {
                name.append(character)
                _ = advance()
            }

            guard !name.isEmpty else { return .unparsed("\\") }

            switch name {
            case "frac", "dfrac", "tfrac":
                let numerator = parseRequiredGroup()
                let denominator = parseRequiredGroup()
                return .fraction(numerator: numerator, denominator: denominator)

            case "sqrt":
                var index: MathNode?
                skipWhitespace()
                if peek() == "[" {
                    _ = advance()
                    index = parseRow(until: "]")
                    expect("]")
                }
                return .sqrt(radicand: parseRequiredGroup(), index: index)

            case "text", "textrm", "mathrm", "operatorname":
                return .textMode(parseRawGroup())

            case "left":
                return parseLeftRight()

            case "right":
                // Unbalanced `\right` — consume its delimiter so it does not derail the rest.
                skipWhitespace()
                let delimiter = advance().map(String.init) ?? ""
                return .text(delimiter)

            case "quad":
                return .text("\u{2003}")
            case "qquad":
                return .text("\u{2003}\u{2003}")
            case ",", ";", ":", "!":
                return .text("\u{2009}")

            default:
                if let symbol = symbols[name] { return .symbol(symbol) }
                if let symbol = operators[name] { return .binaryOperator(symbol) }
                if let symbol = bigOperators[name] { return .bigOperator(symbol) }
                if functions.contains(name) { return .function(name) }
                return .unparsed("\\" + name)
            }
        }

        /// `\left( … \right)` — the delimiters are kept so the renderer can size them to content.
        mutating func parseLeftRight() -> MathNode {
            skipWhitespace()
            let open = readDelimiter()
            var depth = 0
            var nodes: [MathNode] = []

            // Scans to the matching `\right`, tracking nesting so an inner pair does not close the
            // outer one.
            while !isAtEnd {
                skipWhitespace()
                if peek() == "\\", matchesCommand("right"), depth == 0 {
                    consumeCommand("right")
                    skipWhitespace()
                    let close = readDelimiter()
                    let content: MathNode = nodes.count == 1 ? nodes[0] : .row(nodes)
                    return .delimited(open: open, content: content, close: close)
                }
                if peek() == "\\", matchesCommand("left") {
                    depth += 1
                } else if peek() == "\\", matchesCommand("right") {
                    depth -= 1
                }
                guard let node = parseScripted() else { break }
                nodes.append(node)
            }

            // No closing `\right`: render what was found rather than nothing.
            let content: MathNode = nodes.count == 1 ? nodes[0] : .row(nodes)
            return .delimited(open: open, content: content, close: "")
        }

        private mutating func readDelimiter() -> String {
            guard let character = peek() else { return "" }
            if character == "\\" {
                // `\{`, `\|`, `\langle`
                var probe = index + 1
                var name = ""
                while probe < source.count, source[probe].isLetter {
                    name.append(source[probe])
                    probe += 1
                }
                if name.isEmpty, probe < source.count {
                    index = probe + 1
                    return String(source[probe])
                }
                index = probe
                switch name {
                case "langle": return "⟨"
                case "rangle": return "⟩"
                case "lbrace": return "{"
                case "rbrace": return "}"
                case "lvert", "vert": return "|"
                case "rvert":  return "|"
                default: return ""
                }
            }
            if character == "." {
                // `\left.` is an invisible delimiter.
                _ = advance()
                return ""
            }
            _ = advance()
            return String(character)
        }

        private func matchesCommand(_ name: String) -> Bool {
            var probe = index
            guard probe < source.count, source[probe] == "\\" else { return false }
            probe += 1
            for character in name {
                guard probe < source.count, source[probe] == character else { return false }
                probe += 1
            }
            // Must not be a longer command that merely starts with this name.
            if probe < source.count, source[probe].isLetter { return false }
            return true
        }

        private mutating func consumeCommand(_ name: String) {
            index += 1 + name.count
        }

        // MARK: Groups

        /// A `{…}` argument. A command missing its argument yields an empty row rather than
        /// swallowing the rest of the formula.
        mutating func parseRequiredGroup() -> MathNode {
            skipWhitespace()
            guard peek() == "{" else {
                // `\frac12` is legal TeX and means `\frac{1}{2}`: the argument is the next single
                // *token*, so a digit run has to be taken one digit at a time here — unlike in
                // ordinary text, where "12" is one number.
                if let character = peek(), character.isNumber {
                    _ = advance()
                    return .text(String(character))
                }
                return parseAtom() ?? .row([])
            }
            _ = advance()
            let content = parseRow(until: "}")
            expect("}")
            return content
        }

        /// A `{…}` argument read as literal characters, for `\text`.
        mutating func parseRawGroup() -> String {
            skipWhitespace()
            guard peek() == "{" else { return "" }
            _ = advance()
            var result = ""
            var depth = 1
            while let character = advance() {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                result.append(character)
            }
            return result
        }

        // MARK: Utilities

        mutating func skipWhitespace() {
            while let character = peek(), character == " " || character == "\t" || character == "\n" {
                _ = advance()
            }
        }

        mutating func expect(_ character: Character) {
            if peek() == character { _ = advance() }
        }
    }
}
