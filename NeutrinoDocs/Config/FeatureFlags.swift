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

    /// The document editor: WYSIWYG editing of the document tree, auto-save, undo / redo, and
    /// find & replace.
    static let documentEditor: Bool = true

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

    /// Accepting inbound `https://www.getneutrino.app/open/doc/<id>` Universal Links, which is how
    /// Neutrino Drive hands a document to this app.
    ///
    /// When false the link is ignored and the app opens on its usual screen. Turning it off does
    /// not remove the `applinks:` entitlement — that is a bundle property, not a runtime one — so
    /// iOS still launches the app with the URL; `onOpenURL` simply drops it.
    static let appLinks: Bool = true

    // MARK: - Phase 2

    /// The formatting toolbar above the keyboard, and its ⌘ shortcuts.
    static let formattingToolbar: Bool = true

    /// The heading outline: navigation, collapsing, and search.
    static let documentOutline: Bool = true

    // MARK: - Phase 5

    /// Search: the on-device index over titles, content, headings and tags; global search across
    /// Drive with owner / folder / modified / tag filters; and saved searches.
    ///
    /// Switching this off stops the index being written as well as read — `SearchService` checks it
    /// before indexing — so a build without search does not accumulate an index nobody can query.
    static let search: Bool = true
}
