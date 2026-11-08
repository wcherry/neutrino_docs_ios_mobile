import Foundation

// MARK: - LiveSearch

/// The as-you-type search behind every search field in the app: the Search tab and the field on the
/// Home list. Both answer a query the same way, so they share this rather than each keeping a copy.
///
/// Local results are set synchronously so the list tracks the keystroke — the index is in memory and
/// answering costs nothing. The Drive-wide pass runs after a short debounce and appends the documents
/// the index has not read yet, which can only be matched on their names.
@MainActor
final class LiveSearch: ObservableObject {

    @Published var query = ""
    @Published var filters = SearchFilters.unfiltered
    @Published private(set) var results: [SearchResult] = []
    /// True while the debounced Drive-wide request is in flight.
    @Published private(set) var isSearchingDrive = false

    private var searchTask: Task<Void, Never>?

    /// How long the typing has to settle before the Drive-wide search runs.
    static let debounce: Duration = .milliseconds(350)

    /// True when nothing is typed and no filter is set: there is no search to show.
    var isIdle: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filters.isActive
    }

    /// Re-runs the search for the current query and filters. Call it whenever either changes.
    func run(using searchService: SearchService, isOnline: Bool) {
        searchTask?.cancel()
        results = searchService.searchLocally(query, filters: filters)

        guard !isIdle, isOnline else {
            isSearchingDrive = false
            return
        }

        let query = query
        let filters = filters
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }

            self?.isSearchingDrive = true
            let combined = await searchService.searchEverywhere(query, filters: filters)
            // The field may have moved on while the request was in flight; the newer run owns the
            // spinner and the results then.
            guard !Task.isCancelled, let self else { return }
            self.isSearchingDrive = false
            self.results = combined
        }
    }

    /// Drops any in-flight Drive request, e.g. when the field is dismissed.
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearchingDrive = false
    }
}
