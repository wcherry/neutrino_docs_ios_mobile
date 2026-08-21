import SwiftUI
import Sodium

// MARK: - DocEditorView

/// The document editor — Phase 1's "Open", "Edit", and "Save".
///
/// ## One view of the document
///
/// There is no edit mode and no preview mode, because there is nothing to switch between: the
/// editing surface already shows the document as it reads. What this view holds is the document
/// itself — the ProseMirror tree, the same one stored on the server — and `DocumentTextEditor`
/// projects it into styled text and reads it back. A `# ` or a `- ` is a way of *typing* a heading
/// or a list, and is consumed the moment it has done its work.
///
/// ## Where the document comes from
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
    @EnvironmentObject private var searchService: SearchService

    // MARK: - State

    /// The document being edited, and the document as it was last loaded or saved. Autosave is the
    /// difference between the two.
    @State private var document: ProseMirrorNode = DocumentBody.empty.doc
    @State private var loadedDocument: ProseMirrorNode = DocumentBody.empty.doc
    @State private var dek: Bytes?
    /// The document's web-only page setup, kept for the length of the session and written back with
    /// every save. Losing it between load and save would reset the document's header, footer,
    /// watermark and theme for everyone.
    @State private var layout: JSONValue?
    /// The server's `contentVersion` for the copy currently on screen. Sent back with each save so
    /// the server rejects the write if another device got there first, and refreshed from every
    /// response so a long editing session stays guarded rather than only the first save.
    @State private var contentVersion: Int?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var saveState: SaveState = .saved
    @State private var role: ShareRole = .owner
    @State private var showVersionHistory = false
    @State private var showSaveVersion = false
    @State private var autosaveTask: Task<Void, Never>?

    // MARK: - Phase 2 state

    @State private var showOutline = false
    @State private var showInsertImage = false

    @StateObject private var editorController = DocumentEditorController()

    /// A phone puts every editor control in the style bar; anything wider keeps them in the
    /// navigation bar, where there is room for them.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

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
                editor
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // A document takes the whole screen. The tab bar is for choosing what to open, and once
        // something is open it is five destinations' worth of chrome between the last line of the
        // document and the bottom of the display — under, on an iPhone, the row the style bar and
        // the keyboard want. Back is how you leave.
        //
        // Set here rather than on each navigation destination because the editor is pushed from
        // three places: Home's deep-link destination, the browser's rows, and Search.
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBars }
        .task { await load() }
        // Autosave is scheduled from the document itself rather than from the editor's callbacks, so
        // a change made any other way (undo, a restored version) is saved too.
        .onChange(of: document) { newValue in
            guard !isLoading, newValue != loadedDocument, isEditable else { return }
            saveState = .dirty
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            // Leaving the editor must not strand an edit that was still inside its debounce window.
            if document != loadedDocument, isEditable {
                Task { await save() }
            }
        }
        .sheet(isPresented: $showVersionHistory) {
            NavigationStack {
                VersionHistoryView(item: item, currentDEK: dek) { restored in
                    document = restored.doc
                    loadedDocument = restored.doc
                    layout = restored.layout
                    saveState = .saved
                }
            }
        }
        .sheet(isPresented: $showSaveVersion) {
            SaveVersionSheet(item: item,
                             documentBody: editedBody(),
                             dek: dek)
        }
        // Phase 3 — Attachments, "Images: insert from camera roll, Files, or Drive".
        .sheet(isPresented: $showInsertImage) {
            NavigationStack {
                InsertImageSheet { alt, source in
                    editorController.insertImage(alt: alt, source: source)
                }
            }
        }
        // Phase 3 — Attachments, "Image properties". Opened by tapping the picture itself, which in
        // a tree document is the whole of what an image is on screen.
        .sheet(item: $editorController.selectedImage) { image in
            NavigationStack {
                ImagePropertiesSheet(
                    image: image,
                    onApply: { editorController.updateSelectedImage($0) },
                    onRemove: { editorController.removeSelectedImage() }
                )
            }
        }
        // Phase 2 — Document Outline.
        .sheet(isPresented: $showOutline) {
            NavigationStack {
                DocumentOutlineView(outline: outline, onSelect: go(to:))
            }
        }
        // Phase 2 — Editor Improvements, "Keyboard shortcuts".
        .editorKeyboardShortcuts(
            controller: editorController,
            isEnabled: isEditable,
            onToggleOutline: { showOutline.toggle() }
        )
    }

    // MARK: - Phase 2 actions

    /// Heading navigation — the caret moves and the text scrolls to it.
    private func go(to heading: DocumentOutline.Heading) {
        editorController.moveCaret(toCharacterOffset: heading.characterOffset)
    }

    // MARK: - Content

    private var editor: some View {
        DocumentTextEditor(
            document: $document,
            isEditable: isEditable,
            font: settings.editorUIFont,
            inputRules: settings.inputRuleOptions,
            // Phase 2 — Formatting Toolbar. This copy rides with the keyboard; `bottomBars` shows
            // the same bar docked when the keyboard is down.
            showsStyleBar: FeatureFlags.formattingToolbar,
            barActions: barActions,
            resolveAttachment: { [contentService] fileID in
                try await contentService.attachmentData(forFileID: fileID)
            },
            controller: editorController
        )
    }

    /// The outline is built from the document as the editor is showing it, so selecting a heading
    /// moves the caret to exactly where that heading is.
    private var outline: DocumentOutline {
        DocumentOutline.outline(of: document, style: DocumentStyle(bodyFont: settings.editorUIFont))
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

    // MARK: - Bottom bars

    /// The style bar above the save status, when the keyboard is not already carrying the bar.
    ///
    /// Two copies of the same view, never both on screen: the keyboard's is an `inputAccessoryView`
    /// and tracks the keyboard exactly, and this one covers the rest of the time — which on a phone
    /// includes the moment a document opens, before anyone has tapped into it. Without it, Outline
    /// and Version History would be reachable only by first starting to type.
    @ViewBuilder
    private var bottomBars: some View {
        VStack(spacing: 0) {
            if isCompact, FeatureFlags.formattingToolbar, !editorController.isEditing, !isLoading {
                Divider()
                EditorFormattingToolbar(controller: editorController,
                                        isEditable: isEditable,
                                        actions: barActions)
            }
            statusBar
        }
    }

    /// What the style bar's `⋯` menu can do. Rebuilt with the view so the offline label and the
    /// server-dependent items reflect where the document actually stands.
    private var barActions: EditorBarActions {
        EditorBarActions(
            insertImage: { showInsertImage = true },
            showOutline: { showOutline = true },
            saveVersion: { showSaveVersion = true },
            showVersionHistory: { showVersionHistory = true },
            toggleOffline: { Task { await toggleOffline() } },
            isAvailableOffline: isAvailableOffline,
            canUseServerFeatures: canUseServerFeatures,
            offersOutline: FeatureFlags.documentOutline,
            offersVersionHistory: FeatureFlags.versionHistory,
            offersOfflineToggle: FeatureFlags.offlineMode
        )
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

            Text(DocTextStats.compute(from: document.plainText).summaryText)
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

    /// Only on a regular width. A phone's controls all live in the style bar, which leaves the
    /// navigation bar to the document's name and the way back — and leaves the four items that used
    /// to be crowded in beside a truncated title with room to be themselves.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isCompact {
                EmptyView()
            } else {
                regularWidthToolbarItems
            }
        }
    }

    @ViewBuilder
    private var regularWidthToolbarItems: some View {
        Group {
            // Phase 2 — Document Outline.
            if FeatureFlags.documentOutline {
                Button {
                    showOutline = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .accessibilityLabel("Outline")
            }

            if isEditable {
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

                Button {
                    editorController.presentFindAndReplace()
                } label: {
                    Label("Find and Replace", systemImage: "text.magnifyingglass")
                }
                .disabled(!isEditable)

                // Phase 2 — Editor Improvements, "Code folding".
                Divider()

                Button {
                    editorController.foldAll()
                } label: {
                    Label("Fold All", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(editorController.foldableRegions.isEmpty)

                Button {
                    editorController.unfoldAll()
                } label: {
                    Label("Unfold All", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(editorController.foldedStartLines.isEmpty)

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
        FeatureFlags.documentEditor && role.canEdit && loadError == nil
    }

    private var isAvailableOffline: Bool {
        offlineStore.isAvailableOffline(item.id)
    }

    /// Version history and named saves need both the server and the session key.
    private var canUseServerFeatures: Bool {
        networkMonitor.isOnline && dek != nil && !item.isShared
    }

    // MARK: - The editing surface

    /// The document as it stands, with the page setup it was loaded with. The editor holds the same
    /// tree that is stored, so there is no conversion here — only the `_meta` block riding along.
    private func editedBody() -> DocumentBody {
        DocumentBody(doc: document, layout: layout)
    }

    /// Takes a loaded body as the document being edited.
    private func adopt(_ body: DocumentBody) {
        document = body.doc
        loadedDocument = body.doc
        layout = body.layout
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Prefer the cache when there is no connection — this is the whole point of offline mode.
        if !networkMonitor.isOnline || offlineStore.isAvailableOffline(item.id) {
            if let cached = try? offlineStore.readPlaintext(id: item.id) {
                adopt(cached.body)
                dek = cached.dek
                searchService.indexDocument(item: item, document: cached.body.doc)
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
            adopt(loaded.body)
            dek = loaded.dek
            saveState = .saved
            // Phase 5 — the plaintext is already in hand, so indexing it here costs a tokenize
            // pass and no network at all.
            searchService.indexDocument(item: item, document: loaded.body.doc)
            // One `/info` read answers both questions the session needs: the version to guard
            // saves with, and — for a shared document — what this account may do with it.
            let info = try? await contentService.fileInfo(for: item.id)
            contentVersion = info?.contentVersion ?? item.contentVersion
            resolveRole(from: info)
            await cacheIfWanted()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Pulls the server's copy over a cached one, unless there is unsynced local work — replacing
    /// the document under a pending edit would discard it.
    private func refreshFromServer() async {
        guard offlineStore.document(id: item.id)?.pendingEdit == nil else { return }
        guard let loaded = try? await contentService.loadContent(for: item) else { return }
        adopt(loaded.body)
        dek = loaded.dek
        saveState = .saved
        let info = try? await contentService.fileInfo(for: item.id)
        // The refresh pulled the server's copy, so the guard must move to the version that copy
        // is at — leaving it behind would make the next save conflict against what we just read.
        contentVersion = info?.contentVersion ?? contentVersion
        resolveRole(from: info)
    }

    /// Asks the server what this account may do with the document. Only meaningful for shared
    /// documents — everything else in this app's listings is owner-scoped server-side.
    private func resolveRole(from info: DocFileInfo?) {
        guard item.isShared else {
            role = .owner
            return
        }
        if let info {
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
        guard let dek, document != loadedDocument, isEditable else { return }
        let snapshot = document
        let body = editedBody()

        // Offline, or cached with a queue already forming: write the edit to the cache and let the
        // sync engine deliver it. Uploading straight past a queued edit would reorder the user's
        // own changes.
        if !networkMonitor.isOnline {
            guard offlineStore.isAvailableOffline(item.id) else {
                saveState = .failed("This document isn't available offline.")
                return
            }
            do {
                try offlineStore.writePendingEdit(body, id: item.id, dek: dek)
                loadedDocument = snapshot
                saveState = .queued
                // An edit made offline is searchable straight away; the index is local anyway.
                searchService.indexDocument(item: item, document: snapshot)
            } catch {
                saveState = .failed(error.localizedDescription)
            }
            return
        }

        saveState = .saving
        do {
            let saved = try await contentService.saveContent(body, for: item, dek: dek,
                                                             expectedContentVersion: contentVersion)
            let modifiedAt = saved.updatedAt
            contentVersion = saved.contentVersion
            loadedDocument = snapshot
            saveState = .saved
            // The listing shows what the server holds, which is the encoded document.
            driveService.documentWasSaved(itemID: item.id,
                                          size: Int64(NeutrinoDocumentCodec.encode(body).utf8.count),
                                          modifiedAt: modifiedAt)
            searchService.indexDocument(item: item, document: snapshot, modifiedAt: modifiedAt)
            // Keep the offline copy in step with what was just uploaded, without re-fetching bytes
            // this device already has.
            if offlineStore.isAvailableOffline(item.id) {
                try? offlineStore.cacheLocalVersion(body, id: item.id, dek: dek,
                                                    serverModifiedAt: modifiedAt,
                                                    serverContentVersion: saved.contentVersion)
            }
        } catch DocContentError.contentVersionConflict {
            // Someone else saved while this document was open. Queueing would only replay the
            // same losing write later, so surface it and let the user decide.
            saveState = .failed(DocContentError.contentVersionConflict(current: nil).localizedDescription)
        } catch {
            // A failed upload falls back to the queue when possible, so the work is not lost.
            if offlineStore.isAvailableOffline(item.id),
               (try? offlineStore.writePendingEdit(body, id: item.id, dek: dek)) != nil {
                loadedDocument = snapshot
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
