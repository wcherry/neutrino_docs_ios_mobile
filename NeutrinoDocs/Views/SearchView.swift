import SwiftUI

// MARK: - SearchView

/// Phase 5 — Search. The Search tab: a query field over the local index, Drive-wide results, the
/// filter sheet, and the user's saved searches.
///
/// Local results appear as the user types, because the index is in memory and answering does not
/// need the network. The Drive-wide pass runs after a short debounce and appends the documents the
/// index has not read yet — those can only be matched on their names, and the rows say so.
struct SearchView: View {

    // MARK: - Environment

    @EnvironmentObject private var searchService: SearchService
    @EnvironmentObject private var driveService: DocsDriveService
    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    // MARK: - State

    @State private var query = ""
    @State private var filters = SearchFilters.unfiltered
    @State private var results: [SearchResult] = []
    @State private var isSearchingDrive = false
    @State private var showFilters = false
    @State private var showSaveSearch = false
    @State private var searchTask: Task<Void, Never>?

    /// How long the typing has to settle before the Drive-wide search runs. Local results are not
    /// debounced at all — they cost nothing.
    private static let debounce: Duration = .milliseconds(350)

    // MARK: - Body

    var body: some View {
        List {
            if let progress = searchService.crawlProgress {
                crawlSection(progress)
            }

            if isBrowsingSavedSearches {
                savedSearchesSection
                indexSection
            } else {
                resultsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search titles, headings, tags, and text")
        .toolbar { toolbarContent }
        .onChange(of: query) { _ in runSearch() }
        .onChange(of: filters) { _ in runSearch() }
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                SearchFiltersView(filters: $filters, availableTags: searchService.allTags)
            }
        }
        .alert("Save this search", isPresented: $showSaveSearch) {
            SaveSearchAlert(query: query, filters: filters)
        } message: {
            Text("Saved searches keep the query and its filters together.")
        }
    }

    /// With nothing typed and no filter set, the screen is a home for saved searches rather than an
    /// empty result list.
    private var isBrowsingSavedSearches: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && !filters.isActive
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if results.isEmpty {
                emptyResults
            } else {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
        } header: {
            HStack {
                Text(results.isEmpty ? "Results" : "\(results.count) result\(results.count == 1 ? "" : "s")")
                Spacer()
                if isSearchingDrive {
                    ProgressView().controlSize(.small)
                }
            }
        } footer: {
            if filters.isActive {
                Text("Filters are on. Documents that haven't been indexed yet can only be matched by name, so they're left out while a tag or folder filter is set.")
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        if let item = item(for: result) {
            NavigationLink {
                DocEditorView(item: item)
            } label: {
                SearchResultRow(result: result,
                                isAvailableOffline: offlineStore.isAvailableOffline(result.documentID))
            }
        } else {
            // A result whose Drive item is not loaded in this session still shows; tapping it is
            // what would need the item, so the row is simply not a link.
            SearchResultRow(result: result,
                            isAvailableOffline: offlineStore.isAvailableOffline(result.documentID))
        }
    }

    /// The Drive item behind a result. Server hits and indexed documents both need one to open, and
    /// a document indexed in an earlier session may not be in any loaded listing.
    private func item(for result: SearchResult) -> DocItem? {
        driveService.item(id: result.documentID)
    }

    @ViewBuilder
    private var emptyResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }

    private var emptyMessage: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, SearchTokenizer.queryPrefixes(trimmed).isEmpty {
            return "Search terms need at least \(SearchTokenizer.minimumPrefixLength) letters."
        }
        if searchService.indexedDocumentCount == 0 {
            return "Nothing is indexed yet. Index your documents to search inside them."
        }
        return "No documents matched."
    }

    // MARK: - Saved searches

    @ViewBuilder
    private var savedSearchesSection: some View {
        if searchService.savedSearches.isEmpty {
            Section {
                Text("Save a search to keep its query and filters together.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Saved Searches")
            }
        } else {
            Section("Saved Searches") {
                ForEach(searchService.savedSearches) { saved in
                    Button {
                        apply(saved)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name)
                                .foregroundStyle(.primary)
                            Text(saved.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            searchService.deleteSavedSearch(id: saved.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func apply(_ saved: SavedSearch) {
        query = saved.query
        filters = saved.filters
        searchService.markUsed(savedSearchID: saved.id)
    }

    // MARK: - Index status

    private var indexSection: some View {
        Section {
            LabeledContent("Documents indexed", value: "\(searchService.indexedDocumentCount)")

            Button {
                searchService.indexEverything()
            } label: {
                Label(searchService.indexedDocumentCount == 0 ? "Index My Documents" : "Update Index",
                      systemImage: "arrow.clockwise")
            }
            .disabled(searchService.crawlProgress != nil || !networkMonitor.isOnline)
        } header: {
            Text("Index")
        } footer: {
            Text("Searching inside documents needs them decrypted on this device, so the index is built here rather than on the server. Indexing downloads every document you can read; documents you open or edit are indexed as you go.")
        }
    }

    @ViewBuilder
    private func crawlSection(_ progress: SearchService.CrawlProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fractionComplete)
                HStack {
                    Text("Indexed \(progress.indexed) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { searchService.cancelCrawl() }
                        .font(.caption)
                }
                if progress.failed > 0 {
                    Text("\(progress.failed) couldn't be read")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showFilters = true
            } label: {
                Label("Filters", systemImage: filters.isActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showSaveSearch = true
            } label: {
                Label("Save Search", systemImage: "bookmark")
            }
            .disabled(isBrowsingSavedSearches)
        }
    }

    // MARK: - Running the search

    /// Local results are set synchronously so the list tracks the keystroke; the Drive-wide pass is
    /// debounced and appends to them.
    private func runSearch() {
        searchTask?.cancel()
        results = searchService.searchLocally(query, filters: filters)

        guard !isBrowsingSavedSearches, networkMonitor.isOnline else {
            isSearchingDrive = false
            return
        }

        let query = query
        let filters = filters
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }

            isSearchingDrive = true
            defer { isSearchingDrive = false }

            let combined = await searchService.searchEverywhere(query, filters: filters)
            // The field may have moved on while the request was in flight.
            guard !Task.isCancelled else { return }
            results = combined
        }
    }
}

// MARK: - SaveSearchAlert

/// The name field inside the "Save this search" alert. Split out so the alert's builder stays a
/// plain list of controls.
private struct SaveSearchAlert: View {

    let query: String
    let filters: SearchFilters

    @EnvironmentObject private var searchService: SearchService
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
        Button("Save") {
            searchService.addSavedSearch(name: name, query: query, filters: filters)
            name = ""
        }
        Button("Cancel", role: .cancel) { name = "" }
    }
}

// MARK: - SearchResultRow

struct SearchResultRow: View {

    let result: SearchResult
    let isAvailableOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.title)
                    .font(.body)
                    .lineLimit(1)
                if result.isShared {
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isAvailableOffline {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !result.preview.isEmpty {
                Text(result.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                ForEach(orderedMatchedFields, id: \.self) { field in
                    Text(Self.label(for: field))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(result.modifiedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Stable order, so the badges do not shuffle between rows.
    private var orderedMatchedFields: [SearchField] {
        SearchField.allCases.filter(result.matchedFields.contains)
    }

    private static func label(for field: SearchField) -> String {
        switch field {
        case .title:   return "Title"
        case .heading: return "Heading"
        case .tag:     return "Tag"
        case .content: return "Text"
        }
    }
}
