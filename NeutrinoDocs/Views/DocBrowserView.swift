import SwiftUI

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

    // MARK: - State

    @State private var showCreateDocument = false
    @State private var showCreateFolder = false
    @State private var renameTarget: DocItem?
    @State private var moveTarget: DocItem?
    @State private var isWorking = false
    @State private var actionError: String?

    // MARK: - Body

    var body: some View {
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
        .navigationTitle(title ?? section.rawValue)
        .navigationBarTitleDisplayMode(parentID == nil ? .large : .inline)
        .toolbar { toolbarContent }
        .refreshable {
            await driveService.load(section, parentID: parentID)
            if FeatureFlags.offlineMode { await syncEngine.syncNow() }
        }
        .task { await driveService.load(section, parentID: parentID) }
        .overlay {
            if driveService.isLoading && items.isEmpty {
                ProgressView()
            }
        }
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

            if item.type == .file {
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
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create")
            }
        }
    }

    // MARK: - Data

    private var items: [DocItem] {
        // Folders before documents, then by name — the ordering people expect from a file browser,
        // except in Recent, where the server's newest-first order is the point of the listing.
        let raw = driveService.items(in: section, parentID: parentID)
        guard section != .recent else { return raw }
        return raw.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type == .folder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
