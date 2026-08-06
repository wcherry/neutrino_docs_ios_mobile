import Foundation

// MARK: - SearchField

/// The parts of a document indexed separately, so a match in one can outrank a match in another.
///
/// Phase 5 — Search, "Indexed: Titles, Content, Headings, Tags". The web app indexes only title and
/// content; headings and tags are given their own fields here because the roadmap asks for them by
/// name, and because a heading match is a much stronger signal than a body match — it is how a
/// reader would have found the passage themselves.
enum SearchField: String, Codable, CaseIterable {
    case title
    case heading
    case tag
    case content

    /// Contribution of one occurrence to a document's score.
    var weight: Double {
        switch self {
        case .title:   return 3
        case .heading: return 2
        case .tag:     return 2
        case .content: return 1
        }
    }
}

// MARK: - IndexedDocument

/// What the index remembers about one document, beside its terms.
///
/// The document's text is deliberately *not* kept. An index of terms is already a bag of words and
/// is protected by being encrypted at rest, but storing the prose verbatim would make the index a
/// second, complete copy of every document the user can read — a much larger thing to lose. What is
/// kept is a short opening preview for the result row.
struct IndexedDocument: Codable, Equatable {

    let id: String
    var title: String
    /// Shown under the title in a result. Bounded by ``previewLimit``.
    var preview: String
    var tags: [String]
    /// `nil` for a document at the root of the drive.
    var folderID: String?
    /// True when the document is owned by somebody else — Phase 5's "Owner" filter.
    var isShared: Bool
    var modifiedAt: Date
    /// When this entry was built, so a stale entry can be found without re-reading the document.
    var indexedAt: Date

    static let previewLimit = 240
}

// MARK: - SearchPosting

/// One term's occurrences in one field of one document.
struct SearchPosting: Codable, Equatable {
    let documentID: String
    let field: SearchField
    let frequency: Int
}

// MARK: - SearchFilters

/// Phase 5 — Global Search, "Filters: Owner, Folder, Modified, Tags".
///
/// `folderIDs` is a set rather than a single id because choosing a folder means searching everything
/// beneath it; expanding the subtree needs the Drive tree, which is `SearchService`'s business
/// rather than the index's.
struct SearchFilters: Equatable, Codable {

    enum Ownership: String, CaseIterable, Identifiable, Codable {
        case any
        case mine
        case shared

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .any:    return "Anyone"
            case .mine:   return "Me"
            case .shared: return "Shared with me"
            }
        }
    }

    var ownership: Ownership = .any
    /// `nil` searches the whole drive; a set restricts to a folder and its descendants.
    var folderIDs: Set<String>?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var tags: Set<String> = []

    static let unfiltered = SearchFilters()

    var isActive: Bool { self != .unfiltered }

    func matches(_ document: IndexedDocument) -> Bool {
        switch ownership {
        case .any:    break
        case .mine:   if document.isShared { return false }
        case .shared: if !document.isShared { return false }
        }

        if let folderIDs {
            // A document at the drive root has no folder, so it is only in scope when the search is
            // not restricted to a folder at all.
            guard let folderID = document.folderID, folderIDs.contains(folderID) else { return false }
        }
        if let modifiedAfter, document.modifiedAt < modifiedAfter { return false }
        if let modifiedBefore, document.modifiedAt > modifiedBefore { return false }

        if !tags.isEmpty {
            let documentTags = Set(document.tags.map { $0.lowercased() })
            guard tags.map({ $0.lowercased() }).allSatisfy(documentTags.contains) else { return false }
        }
        return true
    }
}

// MARK: - SearchResult

struct SearchResult: Identifiable, Equatable {
    let documentID: String
    let title: String
    let preview: String
    /// Which fields the query matched, so a result can say *why* it is a result.
    let matchedFields: Set<SearchField>
    let score: Double
    let modifiedAt: Date
    let isShared: Bool

    var id: String { documentID }
}

// MARK: - SearchIndex

/// The inverted index behind local search — Phase 5, "Local Search".
///
/// Pure value semantics and no I/O, so the tokenizing, the prefix matching, the scoring and the
/// filters are all asserted directly in tests. `SearchIndexStore` persists it and `SearchService`
/// decides what goes into it.
///
/// ## How a query is matched
///
/// Query terms are treated as *prefixes* and combined with AND: "mod bud" finds a document
/// containing both a word starting with "mod" and a word starting with "bud", which is the same
/// rule the web app's engine uses so the two clients agree on what a query means. Terms shorter
/// than ``SearchTokenizer/minimumPrefixLength`` are dropped.
struct SearchIndex: Codable, Equatable {

    // MARK: - Storage

    private(set) var documents: [String: IndexedDocument] = [:]

    /// term -> the documents and fields it occurs in.
    private(set) var postings: [String: [SearchPosting]] = [:]

    /// `postings.keys` in sorted order, so a prefix is a contiguous range rather than a full scan.
    /// Rebuilt lazily because indexing writes in bursts and querying reads in bursts.
    private var sortedTerms: [String]?

    private enum CodingKeys: String, CodingKey {
        case documents, postings
    }

    // MARK: - Init

    init() {}

    var isEmpty: Bool { documents.isEmpty }

    var documentCount: Int { documents.count }

    /// Every tag in the index, in the order a filter list should offer them.
    ///
    /// Lowercased rather than shown as the author typed it. Two documents can tag themselves
    /// `Swift` and `swift`, and those are the same tag as far as the filter is concerned — but
    /// which spelling won would otherwise depend on dictionary iteration order, so the list would
    /// change between launches for no reason the user could see.
    var allTags: [String] {
        Set(documents.values.flatMap(\.tags).map { $0.lowercased() })
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func document(id: String) -> IndexedDocument? { documents[id] }

    // MARK: - Writing

    /// Adds or replaces a document's entry. Re-indexing is a remove followed by an add, so a term
    /// the document no longer contains stops matching it.
    mutating func index(_ document: IndexedDocument, fields: [SearchField: String]) {
        remove(documentID: document.id)

        documents[document.id] = document
        for (field, text) in fields {
            for (term, positions) in SearchTokenizer.tokenize(text) {
                postings[term, default: []].append(
                    SearchPosting(documentID: document.id, field: field, frequency: positions.count)
                )
            }
        }
        sortedTerms = nil
    }

    mutating func remove(documentID: String) {
        guard documents.removeValue(forKey: documentID) != nil else { return }

        for (term, entries) in postings {
            let kept = entries.filter { $0.documentID != documentID }
            if kept.isEmpty {
                postings.removeValue(forKey: term)
            } else if kept.count != entries.count {
                postings[term] = kept
            }
        }
        sortedTerms = nil
    }

    /// Drops everything — used when the user signs out, since the index holds decrypted text.
    mutating func removeAll() {
        documents.removeAll()
        postings.removeAll()
        sortedTerms = nil
    }

    // MARK: - Querying

    func search(_ query: String,
                filters: SearchFilters = .unfiltered,
                limit: Int = 50) -> [SearchResult] {
        let prefixes = SearchTokenizer.queryPrefixes(query)
        guard !prefixes.isEmpty else { return [] }

        var scores: [String: Double] = [:]
        var matchedFields: [String: Set<SearchField>] = [:]
        var candidates: Set<String>?

        for prefix in prefixes {
            var matchedHere = Set<String>()
            for term in terms(startingWith: prefix) {
                for posting in postings[term] ?? [] {
                    matchedHere.insert(posting.documentID)
                    scores[posting.documentID, default: 0] += Double(posting.frequency) * posting.field.weight
                    matchedFields[posting.documentID, default: []].insert(posting.field)
                }
            }
            // AND across query terms: a document has to satisfy every prefix.
            candidates = candidates.map { $0.intersection(matchedHere) } ?? matchedHere
            if candidates?.isEmpty == true { return [] }
        }

        return (candidates ?? [])
            .compactMap { id -> SearchResult? in
                guard let document = documents[id], filters.matches(document) else { return nil }
                return SearchResult(
                    documentID: id,
                    title: document.title,
                    preview: document.preview,
                    matchedFields: matchedFields[id] ?? [],
                    score: scores[id] ?? 0,
                    modifiedAt: document.modifiedAt,
                    isShared: document.isShared
                )
            }
            // Ties break on recency: two equally relevant documents are not equally interesting.
            .sorted { ($0.score, $0.modifiedAt) > ($1.score, $1.modifiedAt) }
            .prefix(limit)
            .map { $0 }
    }

    /// Documents matching the filters alone, for browsing by tag or folder with no query typed.
    func browse(filters: SearchFilters, limit: Int = 50) -> [SearchResult] {
        documents.values
            .filter(filters.matches)
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map {
                SearchResult(documentID: $0.id, title: $0.title, preview: $0.preview,
                             matchedFields: [], score: 0, modifiedAt: $0.modifiedAt,
                             isShared: $0.isShared)
            }
    }

    // MARK: - Prefix lookup

    /// The indexed terms starting with `prefix`, found by binary-searching the sorted term list
    /// rather than scanning every term in the index.
    private func terms(startingWith prefix: String) -> ArraySlice<String> {
        let sorted = sortedTerms ?? postings.keys.sorted()
        let start = sorted.partitioningIndex { $0 >= prefix }
        guard start < sorted.count else { return [] }
        let end = sorted[start...].partitioningIndex { !$0.hasPrefix(prefix) }
        return sorted[start..<end]
    }

    /// Rebuilds the sorted term list. Called by the store after loading and after a batch of
    /// indexing, so a query does not pay for the sort.
    mutating func prepareForQuerying() {
        sortedTerms = postings.keys.sorted()
    }
}

// MARK: - Array + partitioningIndex

private extension Array where Element == String {

    /// Index of the first element satisfying `belongsInSecondPartition`, assuming the array is
    /// partitioned by it. Standard binary search; the collection is sorted, so every predicate used
    /// here is monotonic over it.
    func partitioningIndex(where belongsInSecondPartition: (String) -> Bool) -> Int {
        self[...].partitioningIndex(where: belongsInSecondPartition)
    }
}

private extension ArraySlice where Element == String {

    func partitioningIndex(where belongsInSecondPartition: (String) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if belongsInSecondPartition(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
