import UIKit

// MARK: - DocumentImageAttachment

/// The picture an `image` node stands for, laid out by the text system.
///
/// In a tree document an image is one atomic node, and ``DocumentProjection`` gives it exactly one
/// character — `U+FFFC`. That is what an `NSTextAttachment` character *is*, so the text system can
/// size and place a picture the same way it sizes and places a glyph, and nothing has to keep a
/// separate overlay in step with the words around it.
///
/// The composite — filter, border, shadow, caption — is rendered into a single image rather than
/// drawn in pieces, so the whole picture is one glyph to TextKit and cannot come apart from its
/// caption when the line wraps.
final class DocumentImageAttachment: NSTextAttachment {

    /// Where the picture comes from: a `neutrino-drive:` reference, an `http(s):` URL, or a `data:`
    /// URI. See ``DriveImageReference``.
    let source: String

    /// How the document says to draw it.
    let attributes: ImageAttributes

    /// The pictures already in hand. Unowned-ish by design: the store belongs to the text view, and
    /// an attachment never outlives the text it is in.
    private weak var store: EditorImageStore?

    /// The picture, already loaded and filtered, for an attachment that must not reach the store —
    /// a printed page, which the print system may draw off the main thread. See
    /// ``init(source:attributes:resolvedImage:)``.
    private let resolvedImage: UIImage?
    private let isResolved: Bool

    /// Room a picture is given while it is still loading, and the most it may ever take. One that
    /// filled the screen would push the text after it out of sight.
    static let maximumHeight: CGFloat = 260
    private static let loadingHeight: CGFloat = 120

    init(source: String, attributes: ImageAttributes, store: EditorImageStore?) {
        self.source = source
        self.attributes = attributes
        self.store = store
        self.resolvedImage = nil
        self.isResolved = false
        super.init(data: nil, ofType: nil)
    }

    /// An attachment holding its picture outright, or holding that it has none: `nil` draws the
    /// failed placeholder. Safe to lay out and draw on any thread.
    init(source: String, attributes: ImageAttributes, resolvedImage: UIImage?) {
        self.source = source
        self.attributes = attributes
        self.store = nil
        self.resolvedImage = resolvedImage
        self.isResolved = true
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        let available = max(1, lineFrag.width)
        let size = renderedSize(availableWidth: available)
        return CGRect(origin: .zero, size: size)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> UIImage? {
        render(size: imageBounds.size)
    }

    // MARK: - Reaching the store

    /// The store belongs to the text view and is bound to the main actor along with it, but
    /// `NSTextAttachment`'s hooks — `attachmentBounds(…)` and `image(forBounds:…)` — are declared
    /// nonisolated even though the text system only ever calls them while laying out and drawing on
    /// the main thread. Reading the cache through these accessors states that guarantee where the
    /// compiler cannot see it; the alternative, keeping a copy of the pictures off the actor, would
    /// mean two caches to keep in step for no gain.

    private var storedImage: UIImage? {
        if isResolved { return resolvedImage }
        return MainActor.assumeIsolated { store?.image(for: source) }
    }

    private var filteredImage: UIImage? {
        if isResolved { return resolvedImage }
        return MainActor.assumeIsolated { store?.image(for: source, filter: attributes.appliedFilter) }
    }

    private var sourceHasFailed: Bool {
        if isResolved { return resolvedImage == nil }
        return MainActor.assumeIsolated { store?.hasFailed(source) ?? true }
    }

    // MARK: - Sizing

    /// The space the picture and its caption need, given the width of the column.
    func renderedSize(availableWidth: CGFloat) -> CGSize {
        let picture = pictureSize(availableWidth: availableWidth)
        let caption = captionSize(width: picture.width)
        return CGSize(width: max(picture.width, caption.width),
                      height: picture.height + caption.height)
    }

    private func pictureSize(availableWidth: CGFloat) -> CGSize {
        guard let image = storedImage else {
            // Nothing to measure yet: a placeholder the width of the column, so the line does not
            // jump by much when the picture lands.
            return CGSize(width: availableWidth, height: Self.loadingHeight)
        }

        let natural = image.size
        guard natural.width > 0, natural.height > 0 else {
            return CGSize(width: availableWidth, height: Self.loadingHeight)
        }

        var width = attributes.drawnWidth(naturalWidth: natural.width,
                                          availableWidth: availableWidth)
        var height = natural.height * (width / natural.width)

        // The cap is on height, because that is what pushes the document down.
        if height > Self.maximumHeight {
            height = Self.maximumHeight
            width = natural.width * (height / natural.height)
        }

        return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }

    // MARK: - Caption

    private var captionFont: UIFont { .preferredFont(forTextStyle: .caption1) }

    private var captionAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: captionFont,
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph]
    }

    private func captionSize(width: CGFloat) -> CGSize {
        guard !attributes.caption.isEmpty, width > 0 else { return .zero }
        let bounding = (attributes.caption as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: captionAttributes,
            context: nil
        )
        return CGSize(width: width, height: ceil(bounding.height) + 6)
    }

    // MARK: - Drawing

    /// Renders the picture, its border, its shadow and its caption into one image.
    private func render(size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let picture = filteredImage
        let captionHeight = captionSize(width: size.width).height
        let pictureRect = CGRect(x: 0, y: 0,
                                 width: size.width,
                                 height: max(0, size.height - captionHeight))

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            if let picture {
                draw(picture, in: pictureRect, context: context.cgContext)
            } else {
                drawPlaceholder(in: pictureRect,
                                failed: sourceHasFailed,
                                context: context.cgContext)
            }

            guard captionHeight > 0 else { return }
            (attributes.caption as NSString).draw(
                with: CGRect(x: 0, y: pictureRect.maxY + 4,
                             width: size.width, height: captionHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: captionAttributes,
                context: nil
            )
        }
    }

    private func draw(_ picture: UIImage, in frame: CGRect, context: CGContext) {
        context.saveGState()

        if attributes.shadow != .none {
            context.setShadow(offset: attributes.shadow.offset,
                              blur: attributes.shadow.blur,
                              color: UIColor.black.withAlphaComponent(attributes.shadow.opacity).cgColor)
        }
        picture.draw(in: frame)
        context.restoreGState()

        guard let border = attributes.strokedBorder else { return }
        context.saveGState()
        context.setStrokeColor(border.color.cgColor)
        context.setLineWidth(border.width)
        if let dashes = border.style.dashes {
            context.setLineDash(phase: 0, lengths: dashes)
        }
        context.stroke(frame.insetBy(dx: border.width / 2, dy: border.width / 2))
        context.restoreGState()
    }

    /// A picture that has not arrived, or cannot.
    private func drawPlaceholder(in frame: CGRect, failed: Bool, context: CGContext) {
        context.setFillColor(UIColor.secondarySystemBackground.cgColor)
        UIBezierPath(roundedRect: frame, cornerRadius: 6).fill()

        let name = failed ? "photo.badge.exclamationmark" : "photo"
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .light)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return }

        let tinted = symbol.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        tinted.draw(at: CGPoint(x: frame.midX - tinted.size.width / 2,
                                y: frame.midY - tinted.size.height / 2))
    }
}

// MARK: - Installing attachments

extension DocumentImageAttachment {

    /// Puts an attachment on every image atom in `text`.
    ///
    /// `.attachment` is presentation, not document: ``DocumentBuilder`` reads only the three
    /// document keys, so hanging an attachment on a run cannot change what is saved. That is what
    /// lets the editor and the read-only version preview share one projection and differ only in
    /// whether they can be typed into.
    static func install(in text: NSMutableAttributedString, store: EditorImageStore?) {
        text.enumerateAttribute(.documentNode,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let atom = value as? DocumentAtom,
                  atom.node.type == DocumentNodeType.image,
                  let source = atom.node.attribute("src")?.stringValue else { return }

            let attachment = DocumentImageAttachment(
                source: source,
                attributes: ImageAttributes(proseMirror: atom.node.attrs),
                store: store
            )
            text.addAttribute(.attachment, value: attachment, range: range)
        }
    }

    /// The same, on an immutable string.
    static func installing(in text: NSAttributedString,
                           store: EditorImageStore?) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        install(in: mutable, store: store)
        return mutable
    }
}

// MARK: - Resolved attachments

extension DocumentImageAttachment {

    /// The source of every image atom in `text`, in document order.
    static func imageSources(in text: NSAttributedString) -> [String] {
        var sources: [String] = []
        text.enumerateAttribute(.documentNode,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, _, _ in
            guard let atom = value as? DocumentAtom,
                  atom.node.type == DocumentNodeType.image,
                  let source = atom.node.attribute("src")?.stringValue else { return }
            sources.append(source)
        }
        return sources
    }

    /// The same as ``install(in:store:)``, but each attachment takes its picture out of `store`
    /// now — filter applied — instead of asking for it at draw time. What printing needs: the
    /// pages may be drawn off the main thread, where the store cannot be reached.
    ///
    /// A picture the store does not have draws the failed placeholder, so load them first with
    /// ``EditorImageStore/preload(_:)``.
    @MainActor
    static func installingResolved(in text: NSAttributedString,
                                   from store: EditorImageStore) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        mutable.enumerateAttribute(.documentNode,
                                   in: NSRange(location: 0, length: mutable.length),
                                   options: []) { value, range, _ in
            guard let atom = value as? DocumentAtom,
                  atom.node.type == DocumentNodeType.image,
                  let source = atom.node.attribute("src")?.stringValue else { return }

            let attributes = ImageAttributes(proseMirror: atom.node.attrs)
            let attachment = DocumentImageAttachment(
                source: source,
                attributes: attributes,
                resolvedImage: store.image(for: source, filter: attributes.appliedFilter)
            )
            mutable.addAttribute(.attachment, value: attachment, range: range)
        }
        return mutable
    }
}
