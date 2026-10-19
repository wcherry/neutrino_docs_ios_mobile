import SwiftUI
import NeutrinoCore
import NeutrinoUI

// MARK: - ContentView

/// The signed-in app shell: a tab per Phase 1 browse section, plus Offline and Settings.
///
/// Each tab keeps its own `NavigationStack` so pushing into a folder or a document in one tab does
/// not disturb the others.
struct ContentView: View {

    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var driveService: DocsDriveService
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var syncEngine: SyncEngine

    @State private var selectedTab: Tab = .home
    /// Home's navigation stack, owned here rather than by `DocBrowserView` so a Universal Link can
    /// push an editor onto it from outside the browser.
    @State private var homePath = NavigationPath()
    @State private var linkError: String?

    enum Tab: Hashable {
        case home, recent, search, favorites, shared, offline, settings
    }

    var body: some View {
        tabs
            .connectivityBanner(isOnline: networkMonitor.isOnline,
                                pendingChanges: syncablePendingCount,
                                activity: syncEngine.state.activity,
                                keepsChangesOffline: FeatureFlags.offlineMode,
                                onRetry: { syncEngine.requestSync() })
            // A document link has to land on Home whatever the user was last looking at: that is
            // the stack the editor is pushed onto.
            .onChange(of: deepLinkRouter.pending?.id) { pendingID in
                if pendingID != nil { selectedTab = .home }
            }
            .task(id: deepLinkRouter.pending?.id) { await openPendingLink() }
            .alert("Couldn\u{2019}t Open Document", isPresented: Binding(
                get: { linkError != nil },
                set: { if !$0 { linkError = nil } }
            )) {
                Button("OK") { linkError = nil }
            } message: {
                Text(linkError ?? "")
            }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                DocBrowserView(section: .home)
                    // Only the deep link pushes by value; the browser's own rows push their
                    // destination view directly.
                    .navigationDestination(for: DocItem.self) { item in
                        DocEditorView(item: item)
                    }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(Tab.home)

            NavigationStack {
                DocBrowserView(section: .recent)
            }
            .tabItem { Label("Recent", systemImage: "clock") }
            .tag(Tab.recent)

            if FeatureFlags.search {
                NavigationStack {
                    SearchView()
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            }

            NavigationStack {
                DocBrowserView(section: .favorites)
            }
            .tabItem { Label("Favorites", systemImage: "star") }
            .tag(Tab.favorites)

            NavigationStack {
                DocBrowserView(section: .shared)
            }
            .tabItem { Label("Shared", systemImage: "person.2") }
            .tag(Tab.shared)

            NavigationStack {
                OfflineView()
            }
            .tabItem { Label("Offline", systemImage: "arrow.down.circle") }
            .badge(offlineBadgeCount)
            .tag(Tab.offline)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
    }

    /// Everything waiting to reach the server. `.badge(0)` hides the badge, so this is a no-op when
    /// the queue is empty or offline mode is off.
    private var offlineBadgeCount: Int {
        FeatureFlags.offlineMode ? offlineStore.totalPendingCount : 0
    }

    /// What a sync can still send. A conflicted document is waiting on the user, not the network,
    /// and is left to the Offline tab — offering "Sync Now" for it would do nothing.
    private var syncablePendingCount: Int {
        guard FeatureFlags.offlineMode else { return 0 }
        let edits = offlineStore.documents.filter { $0.pendingEdit != nil && $0.conflict == nil }.count
        return edits + offlineStore.pendingMutations.count
    }

    // MARK: - Universal Links

    /// Opens the document an inbound `…/open/doc/<id>` link named.
    ///
    /// The stack is reset before the push so a link followed while three folders deep does not
    /// bury the editor under a back trail the user never walked.
    private func openPendingLink() async {
        guard FeatureFlags.appLinks, FeatureFlags.driveIntegration else { return }
        guard deepLinkRouter.pending != nil, let destination = deepLinkRouter.consume() else { return }

        // A link can name a document in a folder this session never opened, or one shared by
        // another account, so the cache is an optimisation and the server is the fallback.
        if let cached = driveService.item(id: destination.fileID), cached.type == .file {
            push(cached)
            return
        }
        do {
            push(try await driveService.fetchItem(id: destination.fileID))
        } catch {
            linkError = error.localizedDescription
        }
    }

    private func push(_ item: DocItem) {
        homePath = NavigationPath()
        homePath.append(item)
    }
}
