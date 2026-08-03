// MARK: - FeatureFlags

/// Compile-time switches for the Phase 1 feature set (see `agent_docs/mvp.md`).
///
/// Every flag here defaults to `true` — Phase 1 is complete. They exist so a feature can be
/// switched off in a build without unpicking its wiring, which is how the sibling Neutrino apps
/// shipped their epics.
enum FeatureFlags {

    /// Drive integration: browsing Home / Recent / Favorites / Shared, folder navigation, and the
    /// open / create / rename / delete / move / duplicate operations.
    static let driveIntegration: Bool = true

    /// The Markdown editor: plain-text editing, syntax highlighting, live preview, auto-save,
    /// undo / redo, and find & replace.
    static let markdownEditor: Bool = true

    /// Offline mode: caching documents for offline reading and editing, plus the pending
    /// save / delete / move queue that drains when connectivity returns.
    static let offlineMode: Bool = true

    /// Version history: listing previous versions with their timestamps, and restoring one.
    static let versionHistory: Bool = true

    /// Face ID / Touch ID unlock for the app and for encryption-key access.
    static let biometricLock: Bool = true

    /// Importing the encryption key by scanning the PIN-protected QR code the web app shows,
    /// alongside the key-file and paste paths. Requires `NSCameraUsageDescription`.
    static let qrKeyScan: Bool = true

    /// `BGTaskScheduler`-driven background upload and download. Requires the
    /// `com.neutrino.docs.sync` identifier in `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundSync: Bool = true

    // MARK: - Phase 2

    /// Rich Markdown: callouts, front matter, natively rendered Mermaid flowcharts, and TeX-subset
    /// math. Tables, footnotes, and task lists shipped in Phase 1.
    static let richMarkdown: Bool = true

    /// The formatting toolbar above the keyboard, and its ⌘ shortcuts.
    static let formattingToolbar: Bool = true

    /// The heading outline: navigation, collapsing, and search.
    static let documentOutline: Bool = true

    /// Side-by-side editor and preview on a regular-width iPad.
    static let splitView: Bool = true
}
