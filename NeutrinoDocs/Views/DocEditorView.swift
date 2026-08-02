import SwiftUI
import Sodium

// MARK: - DocEditorView

/// The Markdown editor — Phase 1's "Open", "Edit", and "Save".
///
/// ## Where the text comes from
///
/// Online, from `DocContentService.loadContent`. Offline, from `OfflineStore.readPlaintext`, which
/// is why a cached document opens with no connection at all. Either way the editing session holds
/// the document's DEK, so saving re-encrypts without unsealing again.
///
/// ## How saving works
///
/// Typing schedules a debounced save at the user's configured interval. Online that is an autosave
/// request; offline it is a pending edit written to the cache, queued for `SyncEngine`. A document
/// that is not cached and has no connection cannot be saved — the editor says so rather than
/// accepting keystrokes it will silently lose.
struct DocEditorView: View {

    // MARK: - Input

    let item: DocItem

    // MARK: - Environment

    @EnvironmentObject private var contentService: DocContentService
    @EnvironmentObject private var driveService: DocsDriveService
    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var settings: AppSettings

    // MARK: - State

    @State private var text: String = ""
    @State private var loadedText: String = ""
    @State private var dek: Bytes?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var saveState: SaveState = .saved
    @State private var mode: Mode = .edit
    @State private var role: ShareRole = .owner
    @State private var showVersionHistory = false
    @State private var showSaveVersion = false
    @State private var autosaveTask: Task<Void, Never>?

    @StateObject private var editorController = MarkdownTextEditorController()

    // MARK: - Mode

    enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"

        var id: String { rawValue }
        var iconName: String { self == .edit ? "square.and.pencil" : "eye" }
    }

    // MARK: - SaveState

    enum SaveState: Equatable {
        case saved
        case dirty
        case saving
        /// Saved locally and waiting for the network — the honest state for an offline edit.
        case queued
        case failed(String)

        var message: String {
            switch self {
            case .saved:              return "Saved"
            case .dirty:              return "Unsaved changes"
            case .saving:             return "Saving…"
            case .queued:             return "Saved offline — will sync"
            case .failed(let reason): return "Not saved: \(reason)"
            }
        }

        var iconName: String {
            switch self {
            case .saved:  return "checkmark.circle"
            case .dirty:  return "pencil.circle"
            case .saving: return "arrow.triangle.2.circlepath"
            case .queued: return "clock.arrow.circlepath"
            case .failed: return "exclamationmark.triangle"
            }
        }

        var isError: Bool { if case .failed = self { return true }; return false }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorView(loadError)
            } else {
                content
            }
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { statusBar }
        .task { await load() }
        // Autosave is scheduled from the text itself rather than from the editor's callbacks, so a
        // change made any other way (undo, a restored version) is saved too.
        .onChange(of: text) { newValue in
            guard !isLoading, newValue != loadedText, isEditable else { return }
            saveState = .dirty
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            // Leaving the editor must not strand an edit that was still inside its debounce window.
            if text != loadedText, isEditable {
                Task { await save() }
            }
        }
        .sheet(isPresented: $showVersionHistory) {
            NavigationStack {
                VersionHistoryView(item: item, currentDEK: dek) { restoredText in
                    text = restoredText
                    loadedText = restoredText
                    saveState = .saved
                }
            }
        }
        .sheet(isPresented: $showSaveVersion) {
            SaveVersionSheet(item: item, text: text, dek: dek)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .edit:
            MarkdownTextEditor(
                text: $text,
                isEditable: isEditable,
                font: settings.editorUIFont,
                highlightSyntax: true,
                controller: editorController
            )
            .ignoresSafeArea(.container, edges: .bottom)

        case .preview:
            MarkdownView(text: text)
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableViewCompat(
            title: "Can't open this document",
            message: message,
            systemImage: "doc.questionmark"
        ) {
            Button("Try Again") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(saveState.message, systemImage: saveState.iconName)
                .font(.footnote)
                .foregroundStyle(saveState.isError ? Color.red : Color.secondary)
                .lineLimit(1)

            Spacer()

            if !networkMonitor.isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(DocTextStats.compute(from: text).summaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Image(systemName: mode.iconName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .accessibilityLabel("Editor mode")
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if mode == .edit && isEditable {
                Button {
                    editorController.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo")

                Button {
                    editorController.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .accessibilityLabel("Redo")
            }

            Menu {
                Button {
                    editorController.presentFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .disabled(mode != .edit)

                Button {
                    editorController.presentFindAndReplace()
                } label: {
                    Label("Find and Replace", systemImage: "text.magnifyingglass")
                }
                .disabled(mode != .edit || !isEditable)

                if FeatureFlags.versionHistory {
                    Divider()

                    Button {
                        showSaveVersion = true
                    } label: {
                        Label("Save Version…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canUseServerFeatures)

                    Button {
                        showVersionHistory = true
                    } label: {
                        Label("Version History", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!canUseServerFeatures)
                }

                if FeatureFlags.offlineMode {
                    Divider()
                    Button {
                        Task { await toggleOffline() }
                    } label: {
                        Label(isAvailableOffline ? "Remove Offline Copy" : "Make Available Offline",
                              systemImage: isAvailableOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: - Derived state

    /// A document opens read-only when the server says this account may not edit it. Phase 1 does
    /// not grant permissions, but it must honour them.
    private var isEditable: Bool {
        FeatureFlags.markdownEditor && role.canEdit && loadError == nil
    }

    private var isAvailableOffline: Bool {
        offlineStore.isAvailableOffline(item.id)
    }

    /// Version history and named saves need both the server and the session key.
    private var canUseServerFeatures: Bool {
        networkMonitor.isOnline && dek != nil && !item.isShared
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Prefer the cache when there is no connection — this is the whole point of offline mode.
        if !networkMonitor.isOnline || offlineStore.isAvailableOffline(item.id) {
            if let cached = try? offlineStore.readPlaintext(id: item.id) {
                text = cached.text
                loadedText = cached.text
                dek = cached.dek
                saveState = offlineStore.document(id: item.id)?.pendingEdit == nil ? .saved : .queued
                // Still refresh from the server when there is a connection, so an offline copy
                // does not quietly go stale while being read.
                if networkMonitor.isOnline {
                    await refreshFromServer()
                }
                return
            }
        }

        guard networkMonitor.isOnline else {
            loadError = "This document isn't available offline."
            return
        }

        do {
            let loaded = try await contentService.loadContent(for: item)
            text = loaded.text
            loadedText = loaded.text
            dek = loaded.dek
            saveState = .saved
            await resolveRole()
            await cacheIfWanted()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Pulls the server's copy over a cached one, unless there is unsynced local work — replacing
    /// the text under a pending edit would discard it.
    private func refreshFromServer() async {
        guard offlineStore.document(id: item.id)?.pendingEdit == nil else { return }
        guard let loaded = try? await contentService.loadContent(for: item) else { return }
        text = loaded.text
        loadedText = loaded.text
        dek = loaded.dek
        saveState = .saved
        await resolveRole()
    }

    /// Asks the server what this account may do with the document. Only meaningful for shared
    /// documents — everything else in this app's listings is owner-scoped server-side.
    private func resolveRole() async {
        guard item.isShared else {
            role = .owner
            return
        }
        if let info = try? await contentService.fileInfo(for: item.id) {
            role = info.yourRole
        } else {
            // Unknown permissions open read-only rather than letting the user type into something
            // the server will refuse to save.
            role = .viewer
        }
    }

    /// Phase 1 — Offline Mode, "Cache: open documents". Opening a document caches it, so it is
    /// readable later without a connection.
    private func cacheIfWanted() async {
        guard FeatureFlags.offlineMode, !offlineStore.isAvailableOffline(item.id) else { return }
        try? await offlineStore.download(item, reason: .opened)
    }

    // MARK: - Saving

    /// Debounces at the user's configured interval (Settings — "Auto-save interval"). Each keystroke
    /// replaces the pending task, so a burst of typing produces one save rather than one per
    /// character.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let interval = settings.autoSaveInterval
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard let dek, text != loadedText, isEditable else { return }
        let snapshot = text

        // Offline, or cached with a queue already forming: write the edit to the cache and let the
        // sync engine deliver it. Uploading straight past a queued edit would reorder the user's
        // own changes.
        if !networkMonitor.isOnline {
            guard offlineStore.isAvailableOffline(item.id) else {
                saveState = .failed("This document isn't available offline.")
                return
            }
            do {
                try offlineStore.writePendingEdit(snapshot, id: item.id, dek: dek)
                loadedText = snapshot
                saveState = .queued
            } catch {
                saveState = .failed(error.localizedDescription)
            }
            return
        }

        saveState = .saving
        do {
            let modifiedAt = try await contentService.saveContent(snapshot, for: item, dek: dek)
            loadedText = snapshot
            saveState = .saved
            driveService.documentWasSaved(itemID: item.id,
                                          size: Int64(snapshot.utf8.count),
                                          modifiedAt: modifiedAt)
            // Keep the offline copy in step with what was just uploaded, without re-fetching bytes
            // this device already has.
            if offlineStore.isAvailableOffline(item.id) {
                try? offlineStore.cacheLocalVersion(snapshot, id: item.id, dek: dek,
                                                    serverModifiedAt: modifiedAt)
            }
        } catch {
            // A failed upload falls back to the queue when possible, so the work is not lost.
            if offlineStore.isAvailableOffline(item.id),
               (try? offlineStore.writePendingEdit(snapshot, id: item.id, dek: dek)) != nil {
                loadedText = snapshot
                saveState = .queued
                syncEngine.requestSync()
            } else {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Offline toggle

    private func toggleOffline() async {
        if isAvailableOffline {
            try? offlineStore.remove(id: item.id)
        } else {
            try? await offlineStore.download(item, reason: .pinned)
        }
    }
}

// MARK: - ContentUnavailableViewCompat

/// `ContentUnavailableView` is iOS 17+; this app targets iOS 16, so empty and error states use a
/// small stand-in with the same shape.
struct ContentUnavailableViewCompat<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ContentUnavailableViewCompat where Actions == EmptyView {
    init(title: String, message: String, systemImage: String) {
        self.init(title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}
