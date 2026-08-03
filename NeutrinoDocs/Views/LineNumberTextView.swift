import UIKit

// MARK: - LineNumberTextView

/// The `UITextView` behind the editor, with a gutter — Phase 2 — Editor Improvements: "Line
/// numbers" and "Code folding".
///
/// Deliberately built on TextKit 1 (`usingTextLayoutManager: false`). The gutter needs per-line
/// fragment geometry and folding needs to suppress glyphs, and `NSLayoutManager` exposes both
/// through delegate callbacks that TextKit 2 has no direct equivalent for.
final class LineNumberTextView: UITextView {

    // MARK: - Configuration

    /// Whether the gutter is drawn at all.
    var showsLineNumbers = true {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            updateInsets()
            setNeedsDisplay()
        }
    }

    /// Start lines of the regions currently folded, in the source's line numbering.
    var foldedStartLines: Set<Int> = [] {
        didSet {
            guard foldedStartLines != oldValue else { return }
            refreshFolding()
        }
    }

    /// The foldable regions of the current text, supplied by the owning view.
    var foldableRegions: [FoldableRegion] = [] {
        didSet { setNeedsDisplay() }
    }

    /// Called when a fold chevron is tapped, with the region's start line.
    var onToggleFold: ((Int) -> Void)?

    /// Colours, resolved against the current trait collection so the gutter follows Dark Mode.
    private var gutterBackground: UIColor { .secondarySystemBackground }
    private var gutterText: UIColor { .tertiaryLabel }

    // MARK: - Private state

    private let foldingDelegate = FoldingLayoutManagerDelegate()

    /// Character ranges hidden by the current folds, cached so drawing does not recompute them.
    private var hiddenCharacterRanges: [NSRange] = []

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
        updateInsets()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    /// Wide enough for the highest line number plus the fold chevron.
    var gutterWidth: CGFloat {
        guard showsLineNumbers else { return 0 }
        let digits = max(2, String(max(1, lineStartOffsets.count)).count)
        return CGFloat(digits) * gutterDigitWidth + 22
    }

    private var gutterDigitWidth: CGFloat { gutterFont.pointSize * 0.62 }

    private var gutterFont: UIFont {
        let size = max(9, (font?.pointSize ?? 17) * 0.75)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Keeps the text clear of the gutter.
    private func updateInsets() {
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 12, right: 12)
    }

    // MARK: - Text changes

    /// Recomputes line offsets and folding. Called by the coordinator whenever the text changes.
    func textDidChangeExternally() {
        recomputeLineOffsets()
        updateInsets()
        refreshFolding()
        setNeedsDisplay()
    }

    private func recomputeLineOffsets() {
        let nsText = text as NSString? ?? ""
        var offsets: [Int] = [0]
        var index = 0
        while index < nsText.length {
            let range = nsText.range(of: "\n",
                                     options: [],
                                     range: NSRange(location: index, length: nsText.length - index))
            guard range.location != NSNotFound else { break }
            offsets.append(range.location + 1)
            index = range.location + 1
        }
        lineStartOffsets = offsets
    }

    /// The character range of a 0-based source line, excluding its newline.
    private func characterRange(ofLine line: Int) -> NSRange? {
        guard line >= 0, line < lineStartOffsets.count else { return nil }
        let start = lineStartOffsets[line]
        let end = line + 1 < lineStartOffsets.count
            ? lineStartOffsets[line + 1] - 1
            : (text as NSString).length
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Folding

    /// Recomputes which characters the current folds hide and asks TextKit to re-lay them out.
    private func refreshFolding() {
        let hiddenLines = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)

        var ranges: [NSRange] = []
        for line in hiddenLines.sorted() {
            guard line < lineStartOffsets.count else { continue }
            let start = lineStartOffsets[line]
            // Include the newline so the hidden line's fragment collapses entirely.
            let end = line + 1 < lineStartOffsets.count
                ? lineStartOffsets[line + 1]
                : (text as NSString).length
            guard end > start else { continue }
            ranges.append(NSRange(location: start, length: end - start))
        }

        hiddenCharacterRanges = ranges
        foldingDelegate.hiddenRanges = ranges

        // Force a fresh glyph generation pass so the delegate is consulted again.
        let full = NSRange(location: 0, length: (text as NSString).length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        setNeedsDisplay()
    }

    /// A caret inside folded text would be invisible, so selection is nudged out of it.
    override var selectedRange: NSRange {
        didSet {
            guard !hiddenCharacterRanges.isEmpty, selectedRange.length == 0 else { return }
            for range in hiddenCharacterRanges where NSLocationInRange(selectedRange.location, range) {
                super.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
                return
            }
        }
    }

    // MARK: - Gutter drawing

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard showsLineNumbers, let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(gutterBackground.cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: gutterText,
        ]

        let hiddenLines = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)
        let foldableStarts = Set(foldableRegions.map(\.startLine))

        for line in 0..<lineStartOffsets.count {
            if hiddenLines.contains(line) { continue }
            guard let characterRange = characterRange(ofLine: line) else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange,
                                                      actualCharacterRange: nil)
            var fragment = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                      in: textContainer)
            fragment.origin.y += textContainerInset.top

            // Only draw what is on screen — a long document would otherwise cost a full pass.
            guard fragment.maxY >= rect.minY, fragment.minY <= rect.maxY else { continue }

            let number = "\(line + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(
                at: CGPoint(x: gutterWidth - size.width - 14, y: fragment.minY),
                withAttributes: attributes
            )

            if foldableStarts.contains(line) {
                drawFoldChevron(at: CGPoint(x: gutterWidth - 11, y: fragment.minY + size.height / 2),
                                isFolded: foldedStartLines.contains(line),
                                in: context)
            }
        }
    }

    private func drawFoldChevron(at center: CGPoint, isFolded: Bool, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(gutterText.cgColor)
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let size: CGFloat = 3.2
        if isFolded {
            // Pointing right: the region is collapsed.
            context.move(to: CGPoint(x: center.x - size / 2, y: center.y - size))
            context.addLine(to: CGPoint(x: center.x + size / 2, y: center.y))
            context.addLine(to: CGPoint(x: center.x - size / 2, y: center.y + size))
        } else {
            // Pointing down: the region is open.
            context.move(to: CGPoint(x: center.x - size, y: center.y - size / 2))
            context.addLine(to: CGPoint(x: center.x, y: center.y + size / 2))
            context.addLine(to: CGPoint(x: center.x + size, y: center.y - size / 2))
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Gutter taps

    private func addGutterTapRecognizer() {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleGutterTap(_:)))
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
    }

    @objc private func handleGutterTap(_ recognizer: UITapGestureRecognizer) {
        guard showsLineNumbers else { return }
        let point = recognizer.location(in: self)
        guard point.x <= gutterWidth else { return }

        let hiddenLines = CodeFolding.hiddenLines(folding: foldedStartLines, regions: foldableRegions)

        for region in foldableRegions where !hiddenLines.contains(region.startLine) {
            guard let characterRange = characterRange(ofLine: region.startLine) else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange,
                                                      actualCharacterRange: nil)
            var fragment = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            fragment.origin.y += textContainerInset.top

            if point.y >= fragment.minY, point.y <= fragment.maxY {
                onToggleFold?(region.startLine)
                return
            }
        }
    }

    // MARK: - Traits

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // The gutter is drawn with resolved colours, so a light/dark switch has to repaint it.
        setNeedsDisplay()
    }
}

// MARK: - FoldingLayoutManagerDelegate

/// Collapses folded text by suppressing its glyphs and zeroing its line fragments.
///
/// This is what lets folding leave the text storage completely alone: the editor's binding, the
/// autosave, and undo all still see the full source, and only the *display* is folded. Editing a
/// document with folds active therefore cannot corrupt it.
private final class FoldingLayoutManagerDelegate: NSObject, NSLayoutManagerDelegate {

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

    /// Nulled glyphs still occupy a line fragment, which would leave a blank row per hidden line.
    /// A fragment whose characters are entirely hidden is given zero height.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard !hiddenRanges.isEmpty else { return false }

        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                          actualGlyphRange: nil)
        guard characterRange.length > 0 else { return false }

        let fullyHidden = hiddenRanges.contains { NSIntersectionRange($0, characterRange).length
            == characterRange.length }
        guard fullyHidden else { return false }

        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }
}
