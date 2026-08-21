import SwiftUI
import UIKit

// MARK: - AppTheme

/// Phase 1 — Settings, "Theme".
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// What to hand SwiftUI's `.preferredColorScheme`. `nil` follows the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - EditorFont

/// Phase 1 — Settings, "Editor font".
enum EditorFont: String, Codable, CaseIterable, Identifiable {
    /// The system's monospaced face — the default, because a document's code blocks and its
    /// alignment (tables, code fences, indented lists) only reads correctly in a fixed pitch.
    case monospaced
    /// The system UI face, for people who would rather write prose in it.
    case system
    case serif
    case rounded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monospaced: return "Monospaced"
        case .system:     return "System"
        case .serif:      return "Serif"
        case .rounded:    return "Rounded"
        }
    }

    var design: Font.Design {
        switch self {
        case .monospaced: return .monospaced
        case .system:     return .default
        case .serif:      return .serif
        case .rounded:    return .rounded
        }
    }

    /// The UIKit design, for the `UITextView` behind the editor.
    var uiFontDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .monospaced: return .monospaced
        case .system:     return .default
        case .serif:      return .serif
        case .rounded:    return .rounded
        }
    }
}

// MARK: - AppSettings

/// The user's Phase 1 preferences, persisted in `UserDefaults`.
///
/// `@Published` rather than `@AppStorage` so that a single observable object can be injected into
/// the view tree and, more importantly, constructed against a throwaway `UserDefaults` suite in
/// tests — `@AppStorage` reads `.standard` unconditionally.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Keys

    enum Keys {
        static let theme               = "settings.theme"
        static let fontSize            = "settings.fontSize"
        static let editorFont          = "settings.editorFont"
        static let autoSaveInterval     = "settings.autoSaveIntervalSeconds"
        static let autoSyncEnabled     = "settings.autoSyncEnabled"
        static let syncOnCellular      = "settings.syncOnCellular"
        static let cacheRecents        = "settings.cacheRecents"
        static let cacheFavorites      = "settings.cacheFavorites"
        // Phase 2 — Editor Improvements.
        static let smartLists          = "settings.smartLists"
        static let closeBrackets       = "settings.closeBrackets"
        static let indentWidth         = "settings.indentWidth"
    }

    // MARK: - Allowed values

    /// Editor body size in points. Dynamic Type scales on top of this, so the range is deliberately
    /// narrow — it adjusts the base, it does not replace accessibility sizing.
    static let fontSizeRange: ClosedRange<Double> = 11...24
    static let defaultFontSize: Double = 17

    /// Selectable auto-save intervals, in seconds. Phase 1 — Settings, "Auto-save interval".
    static let autoSaveIntervalOptions: [TimeInterval] = [1, 2, 5, 10, 30]
    static let defaultAutoSaveInterval: TimeInterval = 2

    /// Phase 2 — Editor Improvements, "Smart indentation".
    static let indentWidthRange: ClosedRange<Int> = 2...8
    static let defaultIndentWidth = 2

    // MARK: - Published settings

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var fontSize: Double {
        didSet {
            // Clamped on write rather than trusted from the caller: the value also arrives from
            // `UserDefaults`, where a stale build or a synced preference could have left anything.
            let clamped = fontSize.clamped(to: Self.fontSizeRange)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Keys.fontSize)
        }
    }

    @Published var editorFont: EditorFont {
        didSet { defaults.set(editorFont.rawValue, forKey: Keys.editorFont) }
    }

    @Published var autoSaveInterval: TimeInterval {
        didSet { defaults.set(autoSaveInterval, forKey: Keys.autoSaveInterval) }
    }

    /// Phase 1 — Synchronization, "Auto-sync". When off, the queue drains only when the user asks
    /// (pull to refresh, or the Offline tab's Sync Now).
    @Published var autoSyncEnabled: Bool {
        didSet { defaults.set(autoSyncEnabled, forKey: Keys.autoSyncEnabled) }
    }

    /// When off, syncing waits for Wi-Fi.
    @Published var syncOnCellular: Bool {
        didSet { defaults.set(syncOnCellular, forKey: Keys.syncOnCellular) }
    }

    /// Phase 1 — Offline Mode, "Cache: recently viewed".
    @Published var cacheRecents: Bool {
        didSet { defaults.set(cacheRecents, forKey: Keys.cacheRecents) }
    }

    /// Phase 1 — Offline Mode, "Cache: favorites".
    @Published var cacheFavorites: Bool {
        didSet { defaults.set(cacheFavorites, forKey: Keys.cacheFavorites) }
    }

    /// Phase 2 — Editor Improvements: "Auto bullets", "Auto numbering", and the Return-continues-a
    /// -list behaviour they imply.
    @Published var smartLists: Bool {
        didSet { defaults.set(smartLists, forKey: Keys.smartLists) }
    }

    /// Phase 2 — Editor Improvements, "Auto closing brackets".
    @Published var closeBrackets: Bool {
        didSet { defaults.set(closeBrackets, forKey: Keys.closeBrackets) }
    }

    /// Phase 2 — Editor Improvements, "Smart indentation": spaces inserted per indent level.
    @Published var indentWidth: Int {
        didSet {
            let clamped = indentWidth.clamped(to: Self.indentWidthRange)
            if clamped != indentWidth {
                indentWidth = clamped
                return
            }
            defaults.set(indentWidth, forKey: Keys.indentWidth)
        }
    }

    // MARK: - Private

    private let defaults: UserDefaults

    // MARK: - Init

    /// - Parameter defaults: injected in tests so a run cannot disturb the real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        let storedSize = defaults.object(forKey: Keys.fontSize) as? Double
        self.fontSize = (storedSize ?? Self.defaultFontSize).clamped(to: Self.fontSizeRange)
        self.editorFont = EditorFont(rawValue: defaults.string(forKey: Keys.editorFont) ?? "") ?? .monospaced
        let storedInterval = defaults.object(forKey: Keys.autoSaveInterval) as? Double
        self.autoSaveInterval = storedInterval ?? Self.defaultAutoSaveInterval
        self.autoSyncEnabled = defaults.object(forKey: Keys.autoSyncEnabled) as? Bool ?? true
        self.syncOnCellular = defaults.object(forKey: Keys.syncOnCellular) as? Bool ?? true
        self.cacheRecents = defaults.object(forKey: Keys.cacheRecents) as? Bool ?? true
        self.cacheFavorites = defaults.object(forKey: Keys.cacheFavorites) as? Bool ?? true
        self.smartLists = defaults.object(forKey: Keys.smartLists) as? Bool ?? true
        self.closeBrackets = defaults.object(forKey: Keys.closeBrackets) as? Bool ?? true
        let storedIndent = defaults.object(forKey: Keys.indentWidth) as? Int
        self.indentWidth = (storedIndent ?? Self.defaultIndentWidth)
            .clamped(to: Self.indentWidthRange)
    }

    // MARK: - Derived

    /// The editor's base font, honouring both the chosen face and size. Dynamic Type scales it.
    var editorUIFont: UIFont {
        let base = UIFont.systemFont(ofSize: fontSize)
        let descriptor = base.fontDescriptor.withDesign(editorFont.uiFontDesign) ?? base.fontDescriptor
        let font = UIFont(descriptor: descriptor, size: fontSize)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }

    /// The as-you-type rules the editor should apply, assembled from the user's preferences.
    var inputRuleOptions: DocumentInputRules.Options {
        DocumentInputRules.Options(continueLists: smartLists,
                                   closeBrackets: closeBrackets)
    }

    /// Label for an auto-save interval, e.g. "Every 2 seconds".
    static func autoSaveLabel(for seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return whole == 1 ? "Every second" : "Every \(whole) seconds"
    }

    // MARK: - Reset

    /// Restores every Phase 1 setting to its default. Used by Settings' "Reset to Defaults".
    func resetToDefaults() {
        theme = .system
        fontSize = Self.defaultFontSize
        editorFont = .monospaced
        autoSaveInterval = Self.defaultAutoSaveInterval
        autoSyncEnabled = true
        syncOnCellular = true
        cacheRecents = true
        cacheFavorites = true
        smartLists = true
        closeBrackets = true
        indentWidth = Self.defaultIndentWidth
    }
}

// MARK: - Comparable + clamped

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
