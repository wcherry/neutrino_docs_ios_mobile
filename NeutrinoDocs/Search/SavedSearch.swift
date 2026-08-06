import Foundation

// MARK: - SavedSearch

/// A named query with its filters — Phase 5, "Saved Searches".
///
/// Saved searches are stored beside the index and under the same key rather than in
/// `UserDefaults`: a query is a statement about what the user is looking for in their own
/// documents ("severance terms", "medication"), which is not something to leave in a plist that any
/// backup picks up.
struct SavedSearch: Identifiable, Codable, Equatable {

    let id: UUID
    var name: String
    var query: String
    var filters: SearchFilters
    let createdAt: Date
    /// Bumped whenever the search is run, so the list can lead with what the user actually uses.
    var lastUsedAt: Date

    init(id: UUID = UUID(),
         name: String,
         query: String,
         filters: SearchFilters = .unfiltered,
         createdAt: Date = Date(),
         lastUsedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.query = query
        self.filters = filters
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// What the row shows under the name: the filters, in words, so a saved search is legible
    /// without being opened.
    var summary: String {
        var parts: [String] = []
        if !query.isEmpty { parts.append("\"\(query)\"") }
        if filters.ownership != .any { parts.append(filters.ownership.displayName) }
        if filters.folderIDs != nil { parts.append("in a folder") }
        if !filters.tags.isEmpty { parts.append(filters.tags.sorted().map { "#\($0)" }.joined(separator: " ")) }
        if filters.modifiedAfter != nil || filters.modifiedBefore != nil { parts.append("by date") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }
}
