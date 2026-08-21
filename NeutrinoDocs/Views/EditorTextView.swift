import UIKit

// MARK: - EditorTextView

/// The `UITextView` behind the editor: code folding, and the decorations a tree document needs
/// drawn beside its lines.
///
/// ## Why there is so little here
///
/// This view used to hide document syntax as it was typed — nulling glyphs, collapsing the
/// fragments they left behind, and anchoring each picture to a control glyph because an image was
/// a line of `data:` URI hundreds of thousands of characters long. None of that exists any more.
/// The document is a tree, the text is its projection, and an image is one `U+FFFC` character with
/// an `NSTextAttachment` on it — so the text system sizes and places a picture the same way it
/// sizes a glyph, and there is no second representation to keep in step.
///
/// What is left is what a tree cannot express on its own: a bullet is drawn because the line's
/// block says it is a list item, not because there is a `-` to show.
///
/// Deliberately built on TextKit 1 (`usingTextLayoutManager: false`). Folding needs to suppress
/// glyphs and collapse line fragments, and the decorations need per-line fragment geometry;
/// `NSLayoutManager` exposes both through delegate callbacks that TextKit 2 has no equivalent for.
final class EditorTextView: UITextView {

    // MARK: - Configuration

    /// Start lines of the regions currently folded, in the document's line numbering.
    var foldedStartLines: Set<Int> = [] {
        didSet {
            guard foldedStartLines != oldValue else { return }
            refreshFolding()
        }
    }

    /// The foldable regions of the current document, supplied by the owning view.
    var foldableRegions: [FoldableRegion] = [] {
        didSet { setNeedsDisplay() }
    }

    /// What to draw beside the lines, supplied by the owning view on every change.
    var decorations: [DocumentDecoration] = [] {
        didSet {
            guard decorations != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// The editor's base font, for sizing and placing the drawn decorations.
    ///
    /// Not `font`: on a text view holding an attributed string that property reports the *first
    /// character's* font, so a document opening with an H1 would size every bullet to the heading.
    var decorationFont: UIFont? {
        didSet {
            guard decorationFont != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// Called when a fold chevron is tapped, with the region's start line.
    var onToggleFold: ((Int) -> Void)?

    /// Called when a picture is tapped, with the character range of the atom under the finger.
    var onTapImage: ((NSRange) -> Void)?

    // MARK: - Private state

    private let foldingDelegate = FoldingLayoutManagerDelegate()

    /// The pictures the document is showing. Owned by the text view so they are released with it.
    let imageStore = EditorImageStore()

    /// Retained because `UIGestureRecognizer.delegate` is weak.
    private let gutterTaps = GutterTapDelegate()
    private let imageTaps = ImageTapDelegate()

    /// Colours for the decorations, resolved against the current traits.
    private var gutterText: UIColor { .tertiaryLabel }
    private var decorationTint: UIColor { .secondaryLabel }
    private var codeBlockBackground: UIColor { .secondarySystemBackground }
    private var ruleColor: UIColor { .separator }

    /// Line start offsets (UTF-16) for the current text, recomputed on every change.
    private var lineStartOffsets: [Int] = [0]

    // MARK: - Init

    init() {
        // Building the TextKit 1 stack by hand is what forces `layoutManager` to exist: a
        // `UITextView` created any other way on iOS 16+ uses TextKit 2, where the gutter's
        // per-fragment geometry and the folding delegate have no equivalent.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: textContainer)

        layoutManager.delegate = foldingDelegate
        addGutterTapRecognizer()
        addImageTapRecognizer()
        updateInsets()

        // Everything this view draws itself — code panels, bullets, quote bars, fold chevrons —
        // goes into its own layer, and a text view is a scroll view: scrolling moves the bounds
        // over the content and does not, by default, repaint. The text keeps up because UIKit draws
        // that in a subview of its own; ours would stay where it was first painted, sliding out of
        // step with the words it belongs to.
        layer.needsDisplayOnBoundsChange = true

        // A picture that finishes loading changes how much room its line needs, so the layout has
        // to be done again rather than merely redrawn.
        imageStore.onLoad = { [weak self] in
            self?.invalidateImageLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    /// Width of the fold gutter, left of the text.
    var gutterWidth: CGFloat { 16 }

    private func updateInsets() {
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 24, right: 12)
    }

    // MARK: - Text changes

    /// Called by the owning view whenever the text changed under it, so the line index and the
    /// folds are recomputed against what is actually there now.
    func textDidChangeExternally() {
        recomputeLineOffsets()
        refreshFolding()
        setNeedsDisplay()
    }

    private func recomputeLineOffsets() {
        let text = self.text as NSString
        var offsets: [Int] = [0]
        var index = 0

        while index < text.length {
            let range = text.range(of: DocumentProjection.blockSeparator,
                                   options: [],
                                   range: NSRange(location: index, length: text.length - index))
            guard range.location != NSNotFound else { break }
            offsets.append(NSMaxRange(range))
            index = NSMaxRange(range)
        }

        lineStartOffsets = offsets
    }

    private func characterRange(ofLine line: Int) -> NSRange? {
        guard line >= 0, line < lineStartOffsets.count else { return nil }
        let start = lineStartOffsets[line]
        let end = line + 1 < lineStartOffsets.count
            ? lineStartOffsets[line + 1]
            : (text as NSString).length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A picture arriving changes how tall its line is, which is layout rather than drawing.
    private func invalidateImageLayout() {
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: full)
        setNeedsDisplay()
    }

    // MARK: - Folding

    private func refreshFolding() {
        var ranges: [NSRange] = []
        let hidden = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)

        for line in hidden.sorted() {
            guard let range = characterRange(ofLine: line) else { continue }
            ranges.append(range)
        }

        guard ranges != foldingDelegate.hiddenRanges else { return }
        foldingDelegate.hiddenRanges = ranges

        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        setNeedsDisplay()
    }

    // MARK: - Fragment geometry

    private func lineFragmentRect(ofLine line: Int) -> CGRect? {
        guard let range = characterRange(ofLine: line), range.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard rect.height > 0 else { return nil }
        return rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    private func isVisible(_ fragment: CGRect, in rect: CGRect) -> Bool {
        fragment.maxY >= rect.minY && fragment.minY <= rect.maxY
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        // Panels go under the text; UIKit draws the glyphs in a subview above this layer, so
        // anything painted here is behind the words either way.
        drawCodeBlockPanels(in: rect)
        drawDecorations(in: rect)
        super.draw(rect)
        drawGutter(in: rect)
    }

    /// The rounded panel behind a code block.
    private func drawCodeBlockPanels(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let padding = DocumentDecorations.codeBlockPadding

        for decoration in decorations where decoration.kind == .codeBlock {
            guard let fragment = lineFragmentRect(ofLine: decoration.line),
                  isVisible(fragment, in: rect) else { continue }

            let panel = CGRect(x: textContainerInset.left - padding / 2,
                               y: fragment.minY - padding / 2,
                               width: bounds.width - textContainerInset.left
                                   - textContainerInset.right + padding,
                               height: fragment.height + padding)

            context.setFillColor(codeBlockBackground.cgColor)
            UIBezierPath(roundedRect: panel,
                         cornerRadius: DocumentDecorations.codeBlockCornerRadius).fill()
        }
    }

    /// Bullets, list numbers, checkboxes, quote bars, and thematic rules.
    private func drawDecorations(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let baseFont = decorationFont ?? font ?? .preferredFont(forTextStyle: .body)

        for decoration in decorations {
            guard decoration.kind != .codeBlock,
                  let fragment = lineFragmentRect(ofLine: decoration.line),
                  isVisible(fragment, in: rect) else { continue }

            switch decoration.kind {
            case .bullet(let depth):
                draw(marker: "\u{2022}", at: depth, in: fragment, font: baseFont)

            case .orderedMarker(let label, let depth):
                draw(marker: label, at: depth, in: fragment, font: baseFont)

            case .checkbox(let checked, let depth):
                drawCheckbox(checked: checked, at: depth, in: fragment, font: baseFont)

            case .quoteBar(let depth):
                // One bar per level, so a quote inside a quote reads as two rather than as one
                // that happens to be indented.
                context.setFillColor(decorationTint.withAlphaComponent(0.45).cgColor)
                for level in 0..<max(1, depth) {
                    let x = textContainerInset.left + DocumentStyle.indentWidth * CGFloat(level)
                    context.fill(CGRect(x: x, y: fragment.minY, width: 3, height: fragment.height))
                }

            case .thematicBreak:
                let y = fragment.midY.rounded()
                context.setStrokeColor(ruleColor.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: textContainerInset.left, y: y))
                context.addLine(to: CGPoint(x: bounds.width - textContainerInset.right, y: y))
                context.strokePath()

            case .codeBlock:
                break
            }
        }
    }

    /// Draws a bullet or a list number in the margin the paragraph indent opened for it, trailing
    /// against the text so `9.` and `10.` still line their text up.
    private func draw(marker: String, at depth: Int, in fragment: CGRect, font baseFont: UIFont) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: decorationTint,
        ]
        let size = (marker as NSString).size(withAttributes: attributes)
        let slotStart = textContainerInset.left + DocumentDecorations.markerIndent(depth: depth)
        let slotWidth = DocumentStyle.listMarkerWidth
        // Right-aligned in the slot, with a little air before the text begins.
        let x = slotStart + max(0, slotWidth - size.width - baseFont.pointSize * 0.35)

        (marker as NSString).draw(at: CGPoint(x: x, y: fragment.minY), withAttributes: attributes)
    }

    private func drawCheckbox(checked: Bool, at depth: Int, in fragment: CGRect, font baseFont: UIFont) {
        let name = checked ? "checkmark.square.fill" : "square"
        let configuration = UIImage.SymbolConfiguration(pointSize: baseFont.pointSize * 0.95)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return }

        let tint = checked ? tintColor ?? .systemBlue : decorationTint
        let x = textContainerInset.left + DocumentDecorations.markerIndent(depth: depth)
        // Sits on the text's baseline rather than the fragment's top, so it reads as part of the line.
        let y = fragment.minY + max(0, (baseFont.lineHeight - symbol.size.height) / 2)

        symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
            .draw(at: CGPoint(x: x, y: y))
    }

    // MARK: - Gutter

    private func drawGutter(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !foldableRegions.isEmpty else { return }
        let hidden = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)

        for region in foldableRegions where !hidden.contains(region.startLine) {
            guard let fragment = lineFragmentRect(ofLine: region.startLine),
                  isVisible(fragment, in: rect) else { continue }

            let centre = CGPoint(x: gutterWidth / 2,
                                 y: fragment.minY + min(fragment.height, 20) / 2)
            drawFoldChevron(at: centre,
                            isFolded: foldedStartLines.contains(region.startLine),
                            in: context)
        }
    }

    private func drawFoldChevron(at center: CGPoint, isFolded: Bool, in context: CGContext) {
        let name = isFolded ? "chevron.right" : "chevron.down"
        let configuration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return }

        symbol.withTintColor(gutterText, renderingMode: .alwaysOriginal)
            .draw(at: CGPoint(x: center.x - symbol.size.width / 2,
                              y: center.y - symbol.size.height / 2))
    }

    // MARK: - Gutter taps

    /// Whether a point belongs to the fold gutter rather than to the text.
    ///
    /// The recognizer asks before it claims a tap, so this is what keeps it out of the way of
    /// ordinary editing.
    func isInGutter(_ point: CGPoint) -> Bool {
        point.x <= gutterWidth
    }

    /// The recognizer added below, kept so a test can assert it is delegated — the whole point of
    /// it, and invisible from the outside otherwise.
    private(set) var gutterTapRecognizer: UITapGestureRecognizer?

    private func addGutterTapRecognizer() {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleGutterTap(_:)))
        recognizer.cancelsTouchesInView = false
        // Without a delegate this recognizer quietly takes every tap in the document. Gesture
        // recognizers on one view are mutually exclusive by default, and the one it beats is
        // UIKit's own — the one that puts the caret where you tapped and raises the keyboard.
        // `cancelsTouchesInView` does not help: that governs touch delivery to the view, not which
        // recognizer wins.
        gutterTaps.isInGutter = { [weak self] point in self?.isInGutter(point) ?? false }
        recognizer.delegate = gutterTaps
        addGestureRecognizer(recognizer)
        gutterTapRecognizer = recognizer
    }

    @objc private func handleGutterTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard isInGutter(point) else { return }

        let hidden = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)

        for region in foldableRegions where !hidden.contains(region.startLine) {
            guard let fragment = lineFragmentRect(ofLine: region.startLine) else { continue }
            if point.y >= fragment.minY, point.y <= fragment.maxY {
                onToggleFold?(region.startLine)
                return
            }
        }
    }

    // MARK: - Tapping a picture

    /// The recognizer that opens an image's properties, kept for the same reason as the gutter's:
    /// so a test can ask what it does with a tap that is not on a picture.
    private(set) var imageTapRecognizer: UITapGestureRecognizer?

    private func addImageTapRecognizer() {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:)))
        recognizer.cancelsTouchesInView = false
        // Same bargain as the gutter's: refusing to begin anywhere but on a picture leaves every
        // other tap to UIKit's own recognizer, which is what places the caret and raises the
        // keyboard.
        imageTaps.isOnImage = { [weak self] point in self?.imageRange(at: point) != nil }
        recognizer.delegate = imageTaps
        addGestureRecognizer(recognizer)
        imageTapRecognizer = recognizer
    }

    @objc private func handleImageTap(_ recognizer: UITapGestureRecognizer) {
        // A document opened read-only — someone else's, or an old version — has properties to look
        // at but nothing to change, and a panel whose Done button cannot write is worse than none.
        guard isEditable, let range = imageRange(at: recognizer.location(in: self)) else { return }
        onTapImage?(range)
    }

    /// The character range of the picture under `point`, if there is one.
    ///
    /// An attachment occupies exactly one character, so this is the ordinary hit test the text
    /// system already does — no separate geometry to keep in step with the layout.
    func imageRange(at point: CGPoint) -> NSRange? {
        guard textStorage.length > 0 else { return nil }

        let inText = CGPoint(x: point.x - textContainerInset.left,
                             y: point.y - textContainerInset.top)
        let index = layoutManager.characterIndex(for: inText, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index >= 0, index < textStorage.length else { return nil }

        let range = NSRange(location: index, length: 1)
        guard textStorage.attribute(.attachment, at: index, effectiveRange: nil)
                is DocumentImageAttachment else { return nil }

        // The hit test snaps to the nearest character, so a tap in the empty column beside a
        // narrow picture would otherwise open its panel. Only a tap inside the drawn glyph counts.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        return bounds.contains(point) ? range : nil
    }

    // MARK: - Traits

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // The decorations are drawn with resolved colours, so a light/dark switch has to repaint.
        setNeedsDisplay()
    }
}

// MARK: - ImageTapDelegate

/// Keeps the image-properties tap recognizer to the pictures.
///
/// A recognizer that refuses to begin is out of the contest for the tap, which leaves UIKit's own
/// free to place the caret.
private final class ImageTapDelegate: NSObject, UIGestureRecognizerDelegate {

    var isOnImage: (CGPoint) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view = recognizer.view else { return false }
        return isOnImage(recognizer.location(in: view))
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - GutterTapDelegate

/// Keeps the fold gutter's tap recognizer to the gutter.
///
/// Refusing to begin outside it takes the recognizer out of the contest for a tap on the text
/// altogether, which is what leaves UIKit's own recognizer free to place the caret and show the
/// keyboard. Inside the gutter it recognizes alongside whatever else wants the tap rather than
/// instead of it — a fold chevron is next to the text, not on top of it.
private final class GutterTapDelegate: NSObject, UIGestureRecognizerDelegate {

    var isInGutter: (CGPoint) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view = recognizer.view else { return false }
        return isInGutter(recognizer.location(in: view))
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - FoldingLayoutManagerDelegate

/// Suppresses the glyphs of folded lines, and collapses the fragments they leave behind.
///
/// This is what lets folding leave the text storage completely alone: the editor's document, the
/// autosave, and undo all still see every line, and only the *display* changes. Folding a section
/// therefore cannot corrupt the document.
///
/// Much smaller than it was. Concealment used the same mechanism to hide syntax as it was typed, and
/// images used it again to anchor a picture to a control glyph; neither exists now, so all that is
/// left is the one job the name describes.
private final class FoldingLayoutManagerDelegate: NSObject, NSLayoutManagerDelegate {

    /// Folded away: no glyphs, no line.
    var hiddenRanges: [NSRange] = []

    private func isHidden(_ characterIndex: Int) -> Bool {
        hiddenRanges.contains { NSLocationInRange(characterIndex, $0) }
    }

    // MARK: - Glyph suppression

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: UIFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }

        // `.null` gives a glyph zero advance and no drawing, which is exactly what a hidden
        // character needs — without removing it from the text storage.
        let adjusted = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(
            capacity: glyphRange.length
        )
        defer { adjusted.deallocate() }

        var changed = false
        for offset in 0..<glyphRange.length {
            if isHidden(characterIndexes[offset]) {
                adjusted[offset] = .null
                changed = true
            } else {
                adjusted[offset] = properties[offset]
            }
        }

        guard changed else { return 0 }

        layoutManager.setGlyphs(glyphs,
                                properties: adjusted,
                                characterIndexes: characterIndexes,
                                font: font,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: - Fragment collapsing

    /// Nulled glyphs still occupy a line fragment, which would leave a blank row per folded line.
    ///
    /// Fragments are identified by their **first character**, looked up per glyph.
    /// `characterRange(forGlyphRange:)` over-reports on a line of nulled glyphs, returning a range
    /// that runs past the fragment and into the ones after it.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard !hiddenRanges.isEmpty, glyphRange.length > 0 else { return false }

        let first = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard isHidden(first) else { return false }

        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        // Nothing visible sits on these lines, so the baseline only has to be inside the fragment
        // for the caret to be drawn at a sensible height.
        baselineOffset.pointee = 0
        return true
    }
}
