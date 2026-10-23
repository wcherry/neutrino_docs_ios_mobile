import UIKit

// MARK: - DocumentDecorationPainter

/// Draws a document's decorations — bullets, list numbers, checkboxes, quote bars, rules, and the
/// panel behind a code block — wherever its lines have been laid out.
///
/// Shared by the editor and by printing, so a printed list numbers and indents exactly as it does
/// on screen. What differs between the two is only where a line *is*: the editor has one text
/// container in a scrolling view, a printed document one container per page. That is the
/// ``lineGeometry`` closure; everything about how a decoration looks is here.
struct DocumentDecorationPainter {

    /// Where one projected line sits in the drawing's coordinates.
    struct LineGeometry {
        /// The line's glyphs — on a page, only the ones that fell on it.
        var rect: CGRect
        /// Whether the line begins here. A list item broken across two pages is numbered on the
        /// first, and only continues on the second.
        var startsHere: Bool
    }

    var decorations: [DocumentDecoration]

    /// The document's base font, which markers are sized from.
    var font: UIFont

    /// Left and right edges of the text column, in drawing coordinates.
    var columnMinX: CGFloat
    var columnMaxX: CGFloat

    /// The tint of a ticked checkbox — the view's `tintColor` on screen.
    var checkedTint: UIColor = .systemBlue

    /// The geometry of a line by index, or `nil` when it is not laid out here.
    var lineGeometry: (Int) -> LineGeometry?

    // MARK: - Colours

    private var decorationTint: UIColor { .secondaryLabel }
    private var codeBlockBackground: UIColor { .secondarySystemBackground }
    private var ruleColor: UIColor { .separator }

    // MARK: - Drawing

    /// The rounded panel behind each code block. Drawn before the text, so it sits under it.
    func drawPanels(in rect: CGRect, context: CGContext) {
        let padding = DocumentDecorations.codeBlockPadding

        for decoration in decorations where decoration.kind == .codeBlock {
            guard let fragment = visibleGeometry(ofLine: decoration.line, in: rect)?.rect else {
                continue
            }

            let panel = CGRect(x: columnMinX - padding / 2,
                               y: fragment.minY - padding / 2,
                               width: columnMaxX - columnMinX + padding,
                               height: fragment.height + padding)

            context.setFillColor(codeBlockBackground.cgColor)
            UIBezierPath(roundedRect: panel,
                         cornerRadius: DocumentDecorations.codeBlockCornerRadius).fill()
        }
    }

    /// Bullets, list numbers, checkboxes, quote bars, and thematic rules.
    func drawMarkers(in rect: CGRect, context: CGContext) {
        for decoration in decorations where decoration.kind != .codeBlock {
            guard let geometry = visibleGeometry(ofLine: decoration.line, in: rect) else { continue }
            let fragment = geometry.rect

            switch decoration.kind {
            case .bullet(let depth):
                guard geometry.startsHere else { continue }
                draw(marker: "\u{2022}", at: depth, in: fragment)

            case .orderedMarker(let label, let depth):
                guard geometry.startsHere else { continue }
                draw(marker: label, at: depth, in: fragment)

            case .checkbox(let checked, let depth):
                guard geometry.startsHere else { continue }
                drawCheckbox(checked: checked, at: depth, in: fragment)

            case .quoteBar(let depth):
                // One bar per level, so a quote inside a quote reads as two rather than as one
                // that happens to be indented.
                context.setFillColor(decorationTint.withAlphaComponent(0.45).cgColor)
                for level in 0..<max(1, depth) {
                    let x = columnMinX + DocumentStyle.indentWidth * CGFloat(level)
                    context.fill(CGRect(x: x, y: fragment.minY, width: 3, height: fragment.height))
                }

            case .thematicBreak:
                let y = fragment.midY.rounded()
                context.setStrokeColor(ruleColor.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: columnMinX, y: y))
                context.addLine(to: CGPoint(x: columnMaxX, y: y))
                context.strokePath()

            case .codeBlock:
                break
            }
        }
    }

    // MARK: - Pieces

    private func visibleGeometry(ofLine line: Int, in rect: CGRect) -> LineGeometry? {
        guard let geometry = lineGeometry(line) else { return nil }
        let fragment = geometry.rect
        return fragment.maxY >= rect.minY && fragment.minY <= rect.maxY ? geometry : nil
    }

    /// Draws a bullet or a list number in the margin the paragraph indent opened for it, trailing
    /// against the text so `9.` and `10.` still line their text up.
    private func draw(marker: String, at depth: Int, in fragment: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: decorationTint,
        ]
        let size = (marker as NSString).size(withAttributes: attributes)
        let slotStart = columnMinX + DocumentDecorations.markerIndent(depth: depth)
        let slotWidth = DocumentStyle.listMarkerWidth
        // Right-aligned in the slot, with a little air before the text begins.
        let x = slotStart + max(0, slotWidth - size.width - font.pointSize * 0.35)

        (marker as NSString).draw(at: CGPoint(x: x, y: fragment.minY), withAttributes: attributes)
    }

    private func drawCheckbox(checked: Bool, at depth: Int, in fragment: CGRect) {
        let name = checked ? "checkmark.square.fill" : "square"
        let configuration = UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.95)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return }

        let tint = checked ? checkedTint : decorationTint
        let x = columnMinX + DocumentDecorations.markerIndent(depth: depth)
        // Sits on the text's baseline rather than the fragment's top, so it reads as part of the line.
        let y = fragment.minY + max(0, (font.lineHeight - symbol.size.height) / 2)

        symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
            .draw(at: CGPoint(x: x, y: y))
    }
}
