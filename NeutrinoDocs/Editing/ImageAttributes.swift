import UIKit

// MARK: - ImageAttributes

/// How a picture is laid out and painted: everything about an image that is not the picture itself.
///
/// ## Why these particular attributes
///
/// They are the web editor's. `AdvancedImageExtension` adds `width`, `alignment`, `caption`,
/// `border`, `shadow` and `imageFilter` to the ProseMirror image node, and its properties panel is
/// what this app's panel mirrors. Inventing a different set would mean two apps that disagree about
/// the same document.
///
/// Attributes this app does not know about are carried through in ``other`` rather than dropped, so
/// that a future web release can add one without phones quietly deleting it.
struct ImageAttributes: Equatable {

    /// CSS dimension — `300px`, `50%`, `auto`, or nil for the picture's own size.
    var width: String?
    var alignment: ImageAlignment = .none
    /// Shown under the picture. The web stores this but does not yet draw it; this app draws it.
    var caption: String = ""
    /// CSS border shorthand, e.g. `2px solid #333`.
    var border: String?
    var shadow: ImageShadow = .none
    /// CSS filter string, e.g. `brightness(80%) contrast(110%)`.
    var filter: String?
    /// Anything else the document carried, kept so it survives the trip.
    var other: [String: String] = [:]

    static let none = ImageAttributes()

    /// Whether there is anything to write down. A plain image stays plain — no empty braces.
    var isEmpty: Bool {
        width == nil && alignment == .none && caption.isEmpty
            && border == nil && shadow == .none && filter == nil && other.isEmpty
    }

    // MARK: - Keys

    /// What the picture *is* rather than how it is drawn: read and written by
    /// ``EditorImageSelection``, and never part of the styling this type carries.
    static let identityKeys: Set<String> = ["src", "alt", "title"]

    /// The names this type understands, under their ProseMirror spelling.
    static let proseMirrorKeys: Set<String> = [
        "width", "alignment", "caption", "border", "shadow", "imageFilter",
    ]
}

// MARK: - EditorImageDescriptor

/// A whole image as the panel edits it: where it comes from, what it says, and how it is drawn.
///
/// The document's own spelling of a picture is an `image` node — see ``EditorImageSelection`` — and
/// this is the flat form the properties panel works in, so the panel does not have to know how a
/// node is put together.
struct EditorImageDescriptor: Equatable {
    var alt: String = ""
    var source: String = ""
    var title: String?
    var attributes: ImageAttributes = .none

    /// Compared cheapest field first, and through `NSString` for the two that can be enormous.
    ///
    /// The synthesized conformance would do were `source` not routinely a `data:` URI carrying a
    /// whole photograph — hundreds of thousands of characters, compared on every keystroke, because
    /// the editor rebuilds its concealment plan each time and asks whether anything about the
    /// display changed. Swift's `==` on a string bridged out of the text storage walks it a block at
    /// a time; `isEqual(to:)` stays at the `NSString` level, where an unequal length is the answer
    /// and an equal one is a single comparison.
    ///
    /// That makes this an exact comparison where Swift's would treat canonically equivalent
    /// spellings of the same character as equal. The difference can only ever report two images as
    /// differing that Swift would have called the same, and what hangs on the answer is whether the
    /// editor lays a line out again — so the strict reading costs a little work and never a wrong
    /// display. It is also the right reading: these are two spellings of the same document, and a
    /// document is bytes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.attributes == rhs.attributes
            && (lhs.alt as NSString).isEqual(to: rhs.alt)
            && (lhs.source as NSString).isEqual(to: rhs.source)
    }
}

// MARK: - ImageAlignment

/// Where a picture sits in its column.
enum ImageAlignment: String, CaseIterable, Identifiable {
    case none
    case left
    case center
    case right
    case floatLeft = "float-left"
    case floatRight = "float-right"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:       return "Default"
        case .left:       return "Left"
        case .center:     return "Centre"
        case .right:      return "Right"
        case .floatLeft:  return "Float Left"
        case .floatRight: return "Float Right"
        }
    }

    /// Whether the web would have text flowing around the picture.
    ///
    /// This app cannot: an image here is a line of its own, and making text wrap around it would
    /// mean laying the paragraph out around an exclusion path. A float is therefore drawn as the
    /// ordinary alignment on the same side — the picture lands where the user put it, the text below
    /// simply does not come up alongside it. The attribute is preserved either way, so the web still
    /// floats it.
    var isFloat: Bool { self == .floatLeft || self == .floatRight }

    /// How the picture is actually positioned in its line.
    var placement: ImageAlignment {
        switch self {
        case .floatLeft:  return .left
        case .floatRight: return .right
        default:          return self
        }
    }

    static func named(_ raw: String?) -> ImageAlignment {
        guard let raw else { return .none }
        return ImageAlignment(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
            ?? .none
    }
}

// MARK: - ImageShadow

/// The web's four shadow presets, with its exact values so the same document looks the same in both.
enum ImageShadow: String, CaseIterable, Identifiable {
    case none
    case sm
    case md
    case lg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .sm:   return "Small"
        case .md:   return "Medium"
        case .lg:   return "Large"
        }
    }

    /// `0 1px 4px rgba(0,0,0,0.22)` and its siblings, in points.
    var offset: CGSize {
        switch self {
        case .none: return .zero
        case .sm:   return CGSize(width: 0, height: 1)
        case .md:   return CGSize(width: 0, height: 4)
        case .lg:   return CGSize(width: 0, height: 10)
        }
    }

    var blur: CGFloat {
        switch self {
        case .none: return 0
        case .sm:   return 4
        case .md:   return 10
        case .lg:   return 28
        }
    }

    var opacity: CGFloat {
        switch self {
        case .none: return 0
        case .sm:   return 0.22
        case .md:   return 0.28
        case .lg:   return 0.38
        }
    }

    static func named(_ raw: String?) -> ImageShadow {
        guard let raw else { return .none }
        return ImageShadow(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .none
    }
}

// MARK: - ProseMirror

extension ImageAttributes {

    /// These attributes under the names the web's image node gives them.
    ///
    /// Only what is actually set is written. The web's defaults are `alignment: "none"`,
    /// `shadow: "none"` and null for the rest, so an unstyled image produces an unstyled node rather
    /// than one carrying six redundant attributes.
    var proseMirrorAttributes: [String: JSONValue] {
        var attrs: [String: JSONValue] = [:]
        if let width, !width.isEmpty { attrs["width"] = .string(width) }
        if alignment != .none { attrs["alignment"] = .string(alignment.rawValue) }
        if !caption.isEmpty { attrs["caption"] = .string(caption) }
        if let border, !border.isEmpty { attrs["border"] = .string(border) }
        if shadow != .none { attrs["shadow"] = .string(shadow.rawValue) }
        if let filter, !filter.isEmpty { attrs["imageFilter"] = .string(filter) }
        for (key, value) in other { attrs[key] = .string(value) }
        return attrs
    }

    /// Reads a ProseMirror image node's attributes.
    ///
    /// Anything this app does not understand is kept in ``other`` and written back out unchanged,
    /// so a phone editing a document cannot silently delete an attribute added by a later release
    /// of the web app.
    init(proseMirror attrs: [String: JSONValue]?) {
        self.init()
        guard let attrs else { return }

        width = attrs["width"]?.stringValue
        alignment = ImageAlignment.named(attrs["alignment"]?.stringValue)
        caption = attrs["caption"]?.stringValue ?? ""
        border = attrs["border"]?.stringValue
        shadow = ImageShadow.named(attrs["shadow"]?.stringValue)
        filter = attrs["imageFilter"]?.stringValue

        for (key, value) in attrs where !Self.identityKeys.contains(key)
            && !Self.proseMirrorKeys.contains(key) {
            guard let string = value.stringValue, !string.isEmpty else { continue }
            other[key] = string
        }
    }
}

// MARK: - Drawing

extension ImageAttributes {

    /// The width the picture should be drawn at, in points.
    ///
    /// `50%` is of the column, not of the picture: a half-width image means half the width of the
    /// text it sits among, which is what somebody dragging a slider on the web meant by it. `auto`
    /// and an unreadable value both fall back to the natural fit.
    func drawnWidth(naturalWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard let width = width?.trimmingCharacters(in: .whitespaces).lowercased(), !width.isEmpty,
              width != "auto" else {
            return min(naturalWidth, availableWidth)
        }

        let resolved: CGFloat?
        if width.hasSuffix("%") {
            if let percent = Double(String(width.dropLast())) {
                resolved = availableWidth * CGFloat(percent) / 100
            } else {
                resolved = nil
            }
        } else {
            resolved = Self.length(width)
        }

        guard let resolved, resolved > 0 else { return min(naturalWidth, availableWidth) }
        return min(resolved, availableWidth)
    }

    /// The border to stroke, if the CSS shorthand describes one.
    var strokedBorder: Border? { Border(css: border) }

    // MARK: - Border

    struct Border: Equatable {
        var width: CGFloat
        var style: Style
        var color: UIColor

        enum Style: String {
            case solid, dashed, dotted, double, none, hidden

            /// The dash pattern to stroke with, or nil for a continuous line.
            var dashes: [CGFloat]? {
                switch self {
                case .dashed: return [6, 4]
                case .dotted: return [1, 3]
                default:      return nil
                }
            }
        }

        /// Reads `2px solid #333`, in any order, as CSS allows.
        init?(css: String?) {
            guard let css = css?.trimmingCharacters(in: .whitespaces), !css.isEmpty else {
                return nil
            }

            var width: CGFloat?
            var style: Style?
            var color: UIColor?

            for part in css.split(separator: " ").map(String.init) {
                if let parsed = Style(rawValue: part.lowercased()) {
                    style = parsed
                } else if let parsed = ImageAttributes.length(part) {
                    width = parsed
                } else if let parsed = ImageAttributes.color(part) {
                    color = parsed
                }
            }

            let resolvedStyle = style ?? .solid
            guard resolvedStyle != .none, resolvedStyle != .hidden else { return nil }
            self.width = width ?? 1
            self.style = resolvedStyle
            self.color = color ?? .label
            guard self.width > 0 else { return nil }
        }
    }

    // MARK: - Filter

    /// `brightness(90%) contrast(110%) saturate(120%)` as multipliers, where 1 is untouched.
    struct Filter: Equatable {
        var brightness: Double = 1
        var contrast: Double = 1
        var saturation: Double = 1

        var isIdentity: Bool { brightness == 1 && contrast == 1 && saturation == 1 }

        init(brightness: Double = 1, contrast: Double = 1, saturation: Double = 1) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
        }

        init?(css: String?) {
            guard let css, !css.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            brightness = Self.percentage(named: "brightness", in: css) ?? 1
            contrast = Self.percentage(named: "contrast", in: css) ?? 1
            saturation = Self.percentage(named: "saturate", in: css) ?? 1
            if isIdentity { return nil }
        }

        /// The CSS this describes, or nil when it describes nothing — matching what the web writes,
        /// which omits any component left at 100%.
        static func css(brightness: Double, contrast: Double, saturation: Double) -> String? {
            var parts: [String] = []
            if brightness != 1 { parts.append("brightness(\(Int((brightness * 100).rounded()))%)") }
            if contrast != 1 { parts.append("contrast(\(Int((contrast * 100).rounded()))%)") }
            if saturation != 1 { parts.append("saturate(\(Int((saturation * 100).rounded()))%)") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        private static func percentage(named name: String, in css: String) -> Double? {
            guard let range = css.range(of: "\(name)(") else { return nil }
            let rest = css[range.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { return nil }
            var value = String(rest[rest.startIndex..<close])
            let isPercentage = value.hasSuffix("%")
            if isPercentage { value = String(value.dropLast()) }
            guard let number = Double(value) else { return nil }
            return isPercentage ? number / 100 : number
        }
    }

    var appliedFilter: Filter? { Filter(css: filter) }

    // MARK: - CSS scalars

    static func length(_ raw: String) -> CGFloat? {
        var value = raw.lowercased()
        for unit in ["px", "pt"] where value.hasSuffix(unit) {
            value = String(value.dropLast(unit.count))
        }
        guard let number = Double(value) else { return nil }
        return CGFloat(number)
    }

    /// `#333`, `#334455`, `rgb(…)`, `rgba(…)`, or one of the handful of CSS names worth knowing.
    static func color(_ raw: String) -> UIColor? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()

        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            let digits: [String]
            switch hex.count {
            case 3, 4: digits = hex.map { "\($0)\($0)" }
            case 6, 8: digits = stride(from: 0, to: hex.count, by: 2).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                return String(hex[start..<hex.index(start, offsetBy: 2)])
            }
            default: return nil
            }
            let channels = digits.compactMap { UInt8($0, radix: 16) }.map { CGFloat($0) / 255 }
            guard channels.count == digits.count, channels.count >= 3 else { return nil }
            return UIColor(red: channels[0], green: channels[1], blue: channels[2],
                           alpha: channels.count > 3 ? channels[3] : 1)
        }

        if value.hasPrefix("rgb") {
            let inside = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            return UIColor(red: CGFloat(parts[0]) / 255,
                           green: CGFloat(parts[1]) / 255,
                           blue: CGFloat(parts[2]) / 255,
                           alpha: parts.count > 3 ? CGFloat(parts[3]) : 1)
        }

        switch value {
        case "black":       return .black
        case "white":       return .white
        case "gray", "grey": return .gray
        case "red":         return .systemRed
        case "green":       return .systemGreen
        case "blue":        return .systemBlue
        case "orange":      return .systemOrange
        case "yellow":      return .systemYellow
        case "purple":      return .systemPurple
        case "transparent": return .clear
        case "currentcolor": return .label
        default:            return nil
        }
    }
}
