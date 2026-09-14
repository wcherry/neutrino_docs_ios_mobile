import Foundation

// MARK: - DocsSection

/// The top-level sections of the Drive browser (Phase 1 — "Browse Drive").
enum DocsSection: String, CaseIterable, Identifiable {
    /// The user's own documents, navigable by folder. Phase 1's "Home".
    case home     = "Home"
    /// `GET /api/v1/drive/recent` — most recently modified documents, newest first.
    case recent   = "Recent"
    /// `GET /api/v1/drive/starred` — Drive's `isStarred` flag.
    case favorites = "Favorites"
    /// `GET /api/v1/drive/shared-with-me` — documents other people own.
    case shared   = "Shared"
    case trash    = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display

    /// SF Symbol representing this section.
    var iconName: String {
        switch self {
        case .home:      return "house"
        case .recent:    return "clock"
        case .favorites: return "star"
        case .shared:    return "person.2"
        case .trash:     return "trash"
        }
    }

    /// Whether this section navigates into folders.
    ///
    /// Only Home does. Recent and Favorites are flat server-side listings that deliberately cut
    /// across the folder tree, and Shared is flat by necessity: Drive's folder listings are
    /// owner-scoped, so the contents of somebody else's folder cannot be enumerated at all.
    var supportsFolderNavigation: Bool { self == .home }

    /// The order this section lists in until the user picks one of their own.
    ///
    /// Recent is a newest-first listing by definition — that ordering is the point of the section,
    /// and it is the order the server sends. Everywhere else a file browser reads A–Z.
    var defaultSortOrder: DocSortOrder { self == .recent ? .newest : .nameAscending }

    /// Copy shown when the section has nothing in it.
    var emptyMessage: String {
        switch self {
        case .home:      return "No documents yet. Tap + to create one."
        case .recent:    return "Documents you open or edit will appear here."
        case .favorites: return "Star a document to keep it here."
        case .shared:    return "Documents other people share with you will appear here."
        case .trash:     return "Trash is empty."
        }
    }
}
