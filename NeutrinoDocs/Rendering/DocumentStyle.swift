import Foundation
import UIKit

// MARK: - DocumentStyle

/// How a document looks on screen: the presentation half of a projection.
///
/// Nothing here is ever read back into the document. A heading is bold and large because this type
/// says so, not because anything in the stored node records a font — which is why changing the
/// editor font is a re-projection rather than an edit.
struct DocumentStyle {

    /// The editor's base font, from `AppSettings`.
    var bodyFont: UIFont

    /// One level of container nesting, in points. A quote inside a list indents twice this.
    static let indentWidth: CGFloat = 22

    /// The gap a list marker is drawn into, left of its item's text.
    static let listMarkerWidth: CGFloat = 20

    init(bodyFont: UIFont) {
        self.bodyFont = bodyFont
    }

    // MARK: - Block attributes

    /// The attributes every character of a line carries before its own marks are applied.
    func attributes(for block: DocumentBlock) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: blockFont(for: block),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle(for: block),
        ]

        if DocumentNodeType.isCodeBlock(block.leafType) {
            attributes[.foregroundColor] = UIColor.systemPurple
        }

        return attributes
    }

    /// The font a line starts from — heading sizes, and the monospace of a code block.
    func blockFont(for block: DocumentBlock) -> UIFont {
        if DocumentNodeType.isCodeBlock(block.leafType) {
            return .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        }
        guard DocumentNodeType.isHeading(block.leafType) else { return bodyFont }
        let level = block.attrs?["level"]?.intValue ?? 1
        return Self.scaled(bodyFont, by: Self.headingScale(for: level), traits: .traitBold)
    }

    /// Indentation for nesting, plus the alignment the node asks for.
    ///
    /// A quote and a list both indent, so the depth is counted rather than special-cased: what
    /// matters on screen is how far in the line sits, not which containers put it there.
    func paragraphStyle(for block: DocumentBlock) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = Self.alignment(named: block.attrs?["textAlign"]?.stringValue)

        let indent = Self.indentWidth * CGFloat(block.containerDepth)
        style.firstLineHeadIndent = indent
        style.headIndent = indent

        // A list item's text is inset far enough to leave its marker a column of its own, and the
        // wrapped lines line up under the text rather than under the bullet.
        if block.listItem != nil {
            style.firstLineHeadIndent = indent
            style.headIndent = indent + Self.listMarkerWidth
        }

        style.paragraphSpacing = DocumentNodeType.isHeading(block.leafType)
            ? bodyFont.pointSize * 0.4
            : bodyFont.pointSize * 0.25
        style.lineBreakMode = .byWordWrapping
        return style
    }

    // MARK: - Mark attributes

    /// Applies the inline marks to the attributes a line already carries.
    ///
    /// Marks build on the block's font rather than the body font, so bold inside a heading stays at
    /// heading size instead of snapping back to body.
    func applying(_ marks: DocumentMarks, to attributes: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        var result = attributes
        var font = (attributes[.font] as? UIFont) ?? bodyFont
        var traits: UIFontDescriptor.SymbolicTraits = []

        for mark in marks.marks {
            switch mark.type {
            case DocumentMarkType.bold:
                traits.insert(.traitBold)
            case DocumentMarkType.italic:
                traits.insert(.traitItalic)
            case DocumentMarkType.underline:
                result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case DocumentMarkType.strike:
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case DocumentMarkType.code:
                font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                result[.foregroundColor] = UIColor.systemPurple
            case DocumentMarkType.link:
                result[.foregroundColor] = UIColor.link
                result[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let href = mark.attrs?["href"]?.stringValue, let url = URL(string: href) {
                    result[.link] = url
                }
            case DocumentMarkType.highlight:
                result[.backgroundColor] = Self.color(named: mark.attrs?["color"]?.stringValue)
                    ?? UIColor.systemYellow.withAlphaComponent(0.35)
            case DocumentMarkType.superscript:
                result[.baselineOffset] = font.pointSize * 0.35
                font = font.withSize(font.pointSize * 0.75)
            case DocumentMarkType.subscript:
                result[.baselineOffset] = -font.pointSize * 0.2
                font = font.withSize(font.pointSize * 0.75)
            case DocumentMarkType.textStyle:
                if let color = Self.color(named: mark.attrs?["color"]?.stringValue) {
                    result[.foregroundColor] = color
                }
                if let size = mark.attrs?["fontSize"], let points = Self.points(from: size) {
                    font = font.withSize(points)
                }
                if let family = mark.attrs?["fontFamily"]?.stringValue,
                   let named = UIFont(name: family, size: font.pointSize) {
                    font = named
                }
            default:
                // A mark this app does not model still travels with the text; it simply draws
                // nothing. Tracked changes and comment anchors arrive here.
                break
            }
        }

        result[.font] = traits.isEmpty ? font : Self.scaled(font, by: 1, traits: traits)
        return result
    }

    // MARK: - Scales

    /// Every level is visibly larger than body text, H6 included — the size ladder is the whole
    /// signal that a line is a heading, since there is no syntax on screen saying so.
    static func headingScale(for level: Int) -> CGFloat {
        switch level {
        case 1:  return 1.75
        case 2:  return 1.5
        case 3:  return 1.32
        case 4:  return 1.2
        case 5:  return 1.12
        default: return 1.06
        }
    }

    static func scaled(_ font: UIFont, by factor: CGFloat,
                       traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let size = font.pointSize * factor
        let combined = font.fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(combined) else {
            return font.withSize(size)
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Value parsing

    /// TipTap's `textAlign`, which is the CSS keyword.
    static func alignment(named name: String?) -> NSTextAlignment {
        switch name {
        case "center":  return .center
        case "right":   return .right
        case "justify": return .justified
        default:        return .natural
        }
    }

    static func name(for alignment: NSTextAlignment) -> String? {
        switch alignment {
        case .center:    return "center"
        case .right:     return "right"
        case .justified: return "justify"
        default:         return nil
        }
    }

    /// A CSS colour as the web app writes it: `#rgb`, `#rrggbb`, or a handful of names.
    static func color(named value: String?) -> UIColor? {
        guard var hex = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        guard hex.hasPrefix("#") else { return namedColors[hex] }
        hex.removeFirst()

        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }

        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    private static let namedColors: [String: UIColor] = [
        "black": .black, "white": .white, "red": .systemRed, "green": .systemGreen,
        "blue": .systemBlue, "yellow": .systemYellow, "orange": .systemOrange,
        "purple": .systemPurple, "gray": .systemGray, "grey": .systemGray,
    ]

    /// A font size, which the web app may write as a number or as a `"14px"` string.
    static func points(from value: JSONValue) -> CGFloat? {
        if let number = value.intValue { return CGFloat(number) }
        guard let text = value.stringValue else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        return Double(digits).map { CGFloat($0) }
    }
}
