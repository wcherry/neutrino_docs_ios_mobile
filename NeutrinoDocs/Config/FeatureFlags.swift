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

    /// `BGTaskScheduler`-driven background upload and download. Requires the
    /// `com.neutrino.docs.sync` identifier in `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundSync: Bool = true
}
