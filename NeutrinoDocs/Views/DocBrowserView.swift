import SwiftUI
import NeutrinoCore

// MARK: - DocBrowserView

/// Phase 1 — Drive Integration: "Browse Drive" and the six operations.
///
/// One view serves every section. Home navigates into folders; Recent, Favorites, Shared, and Trash
/// are flat listings (see `DocsSection.supportsFolderNavigation`).
struct DocBrowserView: View {

    // MARK: - Input

    let section: DocsSection
    /// The folder being listed. Always nil outside Home.
    var parentID: String? = nil
    var title: String? = nil

    // MARK: - Environment

    @EnvironmentObject private var driveService: DocsDriveService
    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var searchService: SearchService

    // MARK: - State

    /// The search field on Home, matching Drive's on My Drive. It searches every document, not just
    /// the folder on screen — the same query the Search tab answers, minus its filters.
    @StateObject private var search = LiveSearch()

    @State private var showCreateDocument = false
    @State private var showCreateFolder = false
    @State private var renameTarget: DocItem?
    @State private var moveTarget: DocItem?
    @State private var isWorking = false
    @State private var actionError: String?

    // MARK: - Body

    var body: some View {
        Group {
            if isSearchActive {
                searchResultsList
            } else {
                listing
            }
        }
        .modifier(HomeSearchModifier(isEnabled: isSearchEnabled, query: $search.query))
        .onChange(of: search.query) { _ in
            search.run(using: searchService, isOnline: networkMonitor.isOnline)
        }
        .navigationTitle(title ?? section.rawValue)
        .navigationBarTitleDisplayMode(parentID == nil ? .large : .inline)
        .toolbar { toolbarContent }
        .task { await driveService.load(section, parentID: parentID) }
        .sheet(isPresented: $showCreateDocument) {
            CreateDocumentSheet(parentID: parentID)
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(parentID: parentID)
        }
        .sheet(item: $renameTarget) { item in
            RenameSheet(item: item)
        }
        .sheet(item: $moveTarget) { item in
            MoveSheet(item: item)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Listing

    private var listing: some View {
        List {
            if items.isEmpty && !driveService.isLoading {
                Text(section.emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                    .listRowSeparator(.hidden)
            }

            ForEach(items) { item in
                row(for: item)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await driveService.load(section, parentID: parentID)
            if FeatureFlags.offlineMode { await syncEngine.syncNow() }
        }
        .overlay {
            if driveService.isLoading && items.isEmpty {
                ProgressView()
            }
        }
    }

    // MARK: - Search

    /// Home only, at every folder depth — the same scope Drive gives its field on My Drive.
    private var isSearchEnabled: Bool {
        FeatureFlags.search && section == .home
    }

    private var isSearchActive: Bool {
        isSearchEnabled && !search.isIdle
    }

    private var searchResultsList: some View {
        List {
            if search.results.isEmpty {
                searchEmptyState
            } else {
                ForEach(search.results) { result in
                    SearchResultLink(result: result)
                }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .top) {
            if search.isSearchingDrive {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
                    .accessibilityLabel("Searching Drive")
            }
        }
    }

    @ViewBuilder
    private var searchEmptyState: some View {
        // While the Drive pass is still running there may yet be results, so the spinner speaks
        // for the list instead of a premature "No Results".
        if !search.isSearchingDrive {
            ContentUnavailableViewCompat(
                title: "No Results",
                message: searchEmptyMessage,
                systemImage: "magnifyingglass"
            )
            .padding(.vertical, 32)
            .listRowSeparator(.hidden)
        }
    }

    private var searchEmptyMessage: String {
        let trimmed = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if SearchTokenizer.queryPrefixes(trimmed).isEmpty {
            return "Search terms need at least \(SearchTokenizer.minimumPrefixLength) letters."
        }
        return "No documents match \u{201C}\(trimmed)\u{201D}."
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: DocItem) -> some View {
        if item.type == .folder && section.supportsFolderNavigation {
            NavigationLink {
                DocBrowserView(section: section, parentID: item.id, title: item.name)
            } label: {
                DocRowView(item: item, isAvailableOffline: offlineStore.isAvailableOffline(item.id))
            }
            .contextMenu { contextMenu(for: item) }
        } else if item.type == .file && section != .trash {
            NavigationLink {
                DocEditorView(item: item)
            } label: {
                DocRowView(item: item, isAvailableOffline: offlineStore.isAvailableOffline(item.id))
            }
            .contextMenu { contextMenu(for: item) }
            .swipeActions(edge: .trailing) {
                if !item.isShared {
                    Button(role: .destructive) {
                        driveService.delete(itemID: item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } else {
            DocRowView(item: item, isAvailableOffline: offlineStore.isAvailableOffline(item.id))
                .contextMenu { contextMenu(for: item) }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: DocItem) -> some View {
        if section == .trash {
            Button {
                driveService.restore(itemID: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                driveService.delete(itemID: item.id)
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            // Drive scopes rename, move, star, and trash to the owner; offering them on somebody
            // else's document would only produce a 403.
            if !item.isShared {
                Button {
                    driveService.setStarred(itemID: item.id, isStarred: !item.isStarred)
                } label: {
                    Label(item.isStarred ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: item.isStarred ? "star.slash" : "star")
                }

                Button {
                    renameTarget = item
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    moveTarget = item
                } label: {
                    Label("Move…", systemImage: "folder")
                }
            }

            // Both actions read the document's body, so neither means anything for a folder.
            if item.isEditable {
                Button {
                    duplicate(item)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .disabled(!networkMonitor.isOnline)

                if FeatureFlags.offlineMode {
                    Button {
                        toggleOffline(item)
                    } label: {
                        Label(offlineStore.isAvailableOffline(item.id)
                                ? "Remove Offline Copy" : "Make Available Offline",
                              systemImage: "arrow.down.circle")
                    }
                }
            }

            if !item.isShared {
                Divider()
                Button(role: .destructive) {
                    driveService.delete(itemID: item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Declared first so it sits to the left of the section's own action, which keeps Empty and
        // + where they already are.
        ToolbarItem(placement: .navigationBarTrailing) {
            sortMenu
        }

        if section == .trash {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Empty", role: .destructive) {
                    driveService.emptyTrash()
                }
                .disabled(driveService.trashItems.isEmpty)
            }
        } else if section == .home && FeatureFlags.driveIntegration {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showCreateDocument = true
                    } label: {
                        Label("New Document", systemImage: "doc.badge.plus")
                    }
                    .disabled(!networkMonitor.isOnline)

                    Button {
                        showCreateFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(!networkMonitor.isOnline)

                    Divider()

                    // Deliberately not disabled offline like the two above. Those need the Drive
                    // API; this one opens Safari — and the bug most worth reporting is often the
                    // one that just took the app off the network.
                    ReportBugButton()
                } label: {
                    Image(systemName: "plus")
                }
                // The menu is no longer only about creating things. VoiceOver reads this label
                // instead of the glyph, so leaving it at "Create" would hide the report from
                // exactly the people most likely to have something to file.
                .accessibilityLabel("Create and more")
            }
        }
    }

    // MARK: - Sorting

    /// The order every listing in the app takes, chosen once and remembered. A section that the
    /// user has not sorted keeps its own default — Recent still opens newest-first.
    private var sortOrder: DocSortOrder { settings.sortOrder(for: section) }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { sortOrder },
                                                 set: { settings.sortOrder = $0 })) {
                ForEach(DocSortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }

    // MARK: - Data

    private var items: [DocItem] {
        sortOrder.sorted(driveService.items(in: section, parentID: parentID))
    }

    // MARK: - Actions

    private func duplicate(_ item: DocItem) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await driveService.duplicate(itemID: item.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func toggleOffline(_ item: DocItem) {
        Task {
            do {
                if offlineStore.isAvailableOffline(item.id) {
                    try offlineStore.remove(id: item.id)
                } else {
                    try await offlineStore.download(item, reason: .pinned)
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - HomeSearchModifier

/// Applies `.searchable` only when `isEnabled`, so the field appears on Home and not on Recent,
/// Favorites or Shared, which share this view.
private struct HomeSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $query, prompt: "Search Docs")
        } else {
            content
        }
    }
}

// MARK: - DocRowView

/// One row in a listing.
struct DocRowView: View {
    let item: DocItem
    var isAvailableOffline: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .foregroundStyle(item.type == .folder ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if isAvailableOffline {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Available offline")
            }
            if item.isShared {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shared with you")
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [Self.dateFormatter.localizedString(for: item.modifiedAt, relativeTo: Date())]
        if let size = item.size, item.type == .file {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
