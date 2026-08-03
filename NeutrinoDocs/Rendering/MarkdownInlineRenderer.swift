import Foundation
import SwiftUI

// MARK: - MarkdownInlineRenderer

/// Converts a run of `MarkdownInline` values into a single `AttributedString` suitable for a
/// SwiftUI `Text`. A pure function with no view state, so its output can be asserted directly.
enum MarkdownInlineRenderer {

    static func attributedString(for inlines: [MarkdownInline]) -> AttributedString {
        renderChildren(inlines, intent: [], link: nil)
    }

    // MARK: - Recursive rendering

    private static func render(_ inline: MarkdownInline,
                               intent: InlinePresentationIntent,
                               link: URL?) -> AttributedString {
        switch inline {
        case .text(let string):
            var attributed = AttributedString(string)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .emphasis(let children):
            return renderChildren(children, intent: intent.union(.emphasized), link: link)

        case .strong(let children):
            return renderChildren(children, intent: intent.union(.stronglyEmphasized), link: link)

        case .strikethrough(let children):
            return renderChildren(children, intent: intent.union(.strikethrough), link: link)

        case .code(let code):
            var attributed = AttributedString(code)
            attributed.font = Font.system(.body, design: .monospaced)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .link(let inlines, let destination):
            return renderChildren(inlines, intent: intent, link: URL(string: destination))

        case .image(let alt, _, _):
            // A mid-paragraph image falls back to its alt text — a documented limitation. A
            // paragraph that is *entirely* one image is handled as a block by `MarkdownView`.
            var attributed = AttributedString(alt)
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .footnoteReference(let label, let index):
            // The visible marker is the 1-based index; the link points back at the internal scheme
            // so `MarkdownView` can intercept the tap and scroll rather than open a browser.
            var attributed = AttributedString("\(index)")
            apply(intent: intent,
                  link: URL(string: "\(MarkdownParser.footnoteScheme)\(label)"),
                  to: &attributed)
            return attributed

        case .inlineMath(let source):
            // Phase 2 — Rich Markdown, "Math". `Text` cannot host a laid-out view, so inline math
            // is flattened to Unicode; `$$…$$` gets the real layout in `MathView`.
            var attributed = AttributedString(MathTextRenderer.string(from: source))
            attributed.font = Font.system(.body, design: .serif).italic()
            apply(intent: intent, link: link, to: &attributed)
            return attributed

        case .softBreak:
            // A single newline in the source is a space when rendered, per CommonMark.
            return AttributedString(" ")

        case .lineBreak:
            return AttributedString("\n")
        }
    }

    private static func renderChildren(_ children: [MarkdownInline],
                                       intent: InlinePresentationIntent,
                                       link: URL?) -> AttributedString {
        var result = AttributedString()
        for child in children {
            result += render(child, intent: intent, link: link)
        }
        return result
    }

    private static func apply(intent: InlinePresentationIntent,
                              link: URL?,
                              to attributed: inout AttributedString) {
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        if let link {
            attributed.link = link
        }
    }
}
