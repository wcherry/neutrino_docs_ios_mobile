import Foundation

// MARK: - DocSortOrder

/// How a listing in the Drive browser is ordered.
///
/// The order is the user's, chosen from the browser's toolbar and remembered across launches (see
/// ``AppSettings/sortOrder``), so it is stored as a stable `rawValue` rather than a case position.
enum DocSortOrder: String, Codable, CaseIterable, Identifiable {
    /// Most recently modified first — Recent's own order, and the one people reach for to find
    /// what they were just working on.
    case newest
    case oldest
    case nameAscending
    case nameDescending

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .newest:         return "Newest First"
        case .oldest:         return "Oldest First"
        case .nameAscending:  return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        }
    }

    // MARK: - Sorting

    /// Applies this order to a listing.
    ///
    /// Folders stay ahead of documents in every order: that is what a file browser does, and a
    /// folder's modification date says nothing a reader would want to rank a document against.
    /// Sorting is by ``DocItem/displayName`` — the title the row actually shows — so the hidden
    /// `.docx` cannot decide where a document lands.
    func sorted(_ items: [DocItem]) -> [DocItem] {
        items.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type == .folder }

            switch self {
            case .newest where lhs.modifiedAt != rhs.modifiedAt:
                return lhs.modifiedAt > rhs.modifiedAt
            case .oldest where lhs.modifiedAt != rhs.modifiedAt:
                return lhs.modifiedAt < rhs.modifiedAt
            default:
                break
            }

            // The name orders the two name cases, and breaks a tie in the two date ones — items
            // modified in the same second read as a list rather than as an arbitrary order.
            let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if byName != .orderedSame {
                return self == .nameDescending
                    ? byName == .orderedDescending
                    : byName == .orderedAscending
            }
            // Two documents can share a name; `sorted(by:)` is not stable, so the id decides and
            // a reload cannot shuffle them.
            return lhs.id < rhs.id
        }
    }
}
