import Foundation
import UIKit

// MARK: - MarkdownSyntaxHighlighter

/// Phase 1 — Markdown Editor: "Syntax highlighting".
///
/// Tokenizes Markdown *source* for display in the editor. This is deliberately not the same job as
/// `MarkdownParser`: the parser throws the syntax away to build a document model for the preview,
/// whereas the editor still shows every `#`, `*`, and backtick and only wants them styled. Running
/// the AST parser here would mean mapping nodes back to source offsets that cmark does not reliably
/// report for inline markup.
///
/// The tokenizer is a pure function from `String` to `[Token]` — no text view, no attributes, no
/// UIKit state — so the interesting behaviour (what counts as emphasis, what a fence suppresses) is
/// asserted directly in tests, and `attributedString(for:)` is a thin styling pass on top.
enum MarkdownSyntaxHighlighter {

    // MARK: - TokenStyle

    enum TokenStyle: Equatable {
        case heading(level: Int)
        case emphasis
        case strong
        case strikethrough
        case inlineCode
        case codeBlock
        case link
        case listMarker
        case blockQuote
        case thematicBreak
        case taskMarker(checked: Bool)
    }

    // MARK: - Token

    struct Token: Equatable {
        let range: NSRange
        let style: TokenStyle
    }

    // MARK: - Patterns

    // Anchored per line; the tokenizer feeds one line at a time.
    private static let headingRegex     = regex(#"^(#{1,6})\s+\S"#)
    private static let blockQuoteRegex  = regex(#"^\s{0,3}>\s?"#)
    private static let thematicRegex    = regex(#"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#)
    private static let listMarkerRegex  = regex(#"^(\s*)([-*+]|\d{1,9}[.)])\s+"#)
    private static let taskMarkerRegex  = regex(#"^\s*(?:[-*+]|\d{1,9}[.)])\s+(\[[ xX]\])\s"#)
    private static let fenceRegex       = regex(#"^\s{0,3}(```|~~~)"#)

    // Inline, scanned within a single line.
    private static let inlineCodeRegex  = regex(#"`[^`\n]+`"#)
    private static let linkRegex        = regex(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let strongRegex      = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasisRegex    = regex(#"(?<![*\w])(\*|_)(?=\S)([^*_\n]+?)(?<=\S)\1(?![*\w])"#)
    private static let strikeRegex      = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Every pattern here is a compile-time literal; a failure would be a programming error
        // rather than anything a document could cause.
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: - Tokenizing

    /// Tokenizes `text`, returning every styled range in source order.
    ///
    /// Overlaps are resolved by precedence rather than by nesting: a range already claimed by a
    /// higher-precedence token (code spans first, then links, then strong, emphasis, strikethrough)
    /// is not claimed again. That keeps `**bold**` from also matching the emphasis pattern, and
    /// stops a `*` inside a code span from italicising the rest of the line.
    static func tokens(in text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        var tokens: [Token] = []
        var insideFence = false

        for line in lines(of: text) {
            let content = line.text
            let offset = line.range.location

            // A fence delimiter belongs to the code block on both sides, and flips the state.
            if matches(Self.fenceRegex, content) {
                insideFence.toggle()
                tokens.append(Token(range: line.range, style: .codeBlock))
                continue
            }
            if insideFence {
                tokens.append(Token(range: line.range, style: .codeBlock))
                continue
            }

            // An indented code block (4+ spaces) is code too, and suppresses inline markup.
            if content.hasPrefix("    ") && !content.trimmingCharacters(in: .whitespaces).isEmpty {
                tokens.append(Token(range: line.range, style: .codeBlock))
                continue
            }

            tokens.append(contentsOf: blockTokens(in: content, offset: offset))
            tokens.append(contentsOf: inlineTokens(in: content, offset: offset))
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Block-level

    private static func blockTokens(in content: String, offset: Int) -> [Token] {
        var tokens: [Token] = []
        let full = NSRange(location: 0, length: (content as NSString).length)

        if let match = Self.headingRegex.firstMatch(in: content, range: full) {
            let level = match.range(at: 1).length
            // The whole line carries the heading style — a heading's text is what should look like
            // a heading, not merely its hashes.
            tokens.append(Token(range: shift(full, by: offset), style: .heading(level: level)))
            return tokens
        }

        if matches(Self.thematicRegex, content) {
            tokens.append(Token(range: shift(full, by: offset), style: .thematicBreak))
            return tokens
        }

        if let match = Self.blockQuoteRegex.firstMatch(in: content, range: full) {
            tokens.append(Token(range: shift(match.range, by: offset), style: .blockQuote))
        }

        if let match = Self.taskMarkerRegex.firstMatch(in: content, range: full) {
            let box = (content as NSString).substring(with: match.range(at: 1))
            let checked = box.lowercased() == "[x]"
            tokens.append(Token(range: shift(match.range(at: 1), by: offset),
                                style: .taskMarker(checked: checked)))
        }

        if let match = Self.listMarkerRegex.firstMatch(in: content, range: full) {
            tokens.append(Token(range: shift(match.range(at: 2), by: offset), style: .listMarker))
        }

        return tokens
    }

    // MARK: - Inline

    private static func inlineTokens(in content: String, offset: Int) -> [Token] {
        var claimed: [NSRange] = []
        var tokens: [Token] = []

        // Precedence order. Code spans first so their contents are inert; links before emphasis so
        // an underscore in a URL cannot italicise the line.
        let passes: [(NSRegularExpression, TokenStyle)] = [
            (Self.inlineCodeRegex, .inlineCode),
            (Self.linkRegex,       .link),
            (Self.strongRegex,     .strong),
            (Self.emphasisRegex,   .emphasis),
            (Self.strikeRegex,     .strikethrough),
        ]

        let full = NSRange(location: 0, length: (content as NSString).length)
        for (pattern, style) in passes {
            for match in pattern.matches(in: content, range: full) {
                let range = match.range
                guard !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
                    continue
                }
                claimed.append(range)
                tokens.append(Token(range: shift(range, by: offset), style: style))
            }
        }

        return tokens
    }

    // MARK: - Attributed output

    /// Applies the tokens to `text` as display attributes.
    ///
    /// - Parameters:
    ///   - text: the Markdown source shown in the editor.
    ///   - baseFont: the editor's configured font (face and size come from `AppSettings`).
    ///   - textColor: the colour unstyled body text uses.
    static func attributedString(for text: String,
                                 baseFont: UIFont,
                                 textColor: UIColor = .label) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: textColor,
        ])

        for token in tokens(in: text) {
            // Ranges come from the same string, but a defensive bounds check costs nothing and
            // turns any future off-by-one into a missing highlight rather than a crash.
            guard token.range.location >= 0,
                  NSMaxRange(token.range) <= attributed.length else { continue }
            attributed.addAttributes(attributes(for: token.style, baseFont: baseFont),
                                     range: token.range)
        }

        return attributed
    }

    private static func attributes(for style: TokenStyle, baseFont: UIFont) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            return [
                .font: scaled(baseFont, by: headingScale(for: level), traits: .traitBold),
                .foregroundColor: UIColor.label,
            ]
        case .strong:
            return [.font: scaled(baseFont, by: 1, traits: .traitBold)]
        case .emphasis:
            return [.font: scaled(baseFont, by: 1, traits: .traitItalic)]
        case .strikethrough:
            return [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: UIColor.secondaryLabel,
            ]
        case .inlineCode, .codeBlock:
            return [
                .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                .foregroundColor: UIColor.systemPurple,
            ]
        case .link:
            return [.foregroundColor: UIColor.link]
        case .listMarker:
            return [
                .font: scaled(baseFont, by: 1, traits: .traitBold),
                .foregroundColor: UIColor.systemBlue,
            ]
        case .blockQuote:
            return [.foregroundColor: UIColor.systemTeal]
        case .thematicBreak:
            return [.foregroundColor: UIColor.tertiaryLabel]
        case .taskMarker(let checked):
            return [.foregroundColor: checked ? UIColor.systemGreen : UIColor.systemOrange]
        }
    }

    /// H1 is noticeably larger; by H6 the heading is only distinguished by weight, which is how
    /// Markdown itself treats the deeper levels.
    private static func headingScale(for level: Int) -> CGFloat {
        switch level {
        case 1:  return 1.6
        case 2:  return 1.4
        case 3:  return 1.25
        case 4:  return 1.15
        case 5:  return 1.05
        default: return 1.0
        }
    }

    private static func scaled(_ font: UIFont, by factor: CGFloat,
                               traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let size = font.pointSize * factor
        let combined = font.fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(combined) else {
            return font.withSize(size)
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Line splitting

    private struct Line {
        let text: String
        /// Range of the line's content in the whole string, excluding its newline.
        let range: NSRange
    }

    /// Splits into lines while tracking each line's range in the original string, which
    /// `components(separatedBy:)` alone would lose.
    private static func lines(of text: String) -> [Line] {
        let nsText = text as NSString
        var result: [Line] = []
        var start = 0

        while start <= nsText.length {
            let searchRange = NSRange(location: start, length: nsText.length - start)
            let newline = nsText.range(of: "\n", options: [], range: searchRange)
            let end = newline.location == NSNotFound ? nsText.length : newline.location
            let lineRange = NSRange(location: start, length: end - start)
            result.append(Line(text: nsText.substring(with: lineRange), range: lineRange))
            if newline.location == NSNotFound { break }
            start = newline.location + newline.length
        }

        return result
    }

    // MARK: - Range helpers

    private static func shift(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }
}
