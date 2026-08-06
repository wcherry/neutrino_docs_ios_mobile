import SwiftUI

// MARK: - ContentView

/// The signed-in app shell: a tab per Phase 1 browse section, plus Offline and Settings.
///
/// Each tab keeps its own `NavigationStack` so pushing into a folder or a document in one tab does
/// not disturb the others.
struct ContentView: View {

    @EnvironmentObject private var offlineStore: OfflineStore

    @State private var selectedTab: Tab = .home

    enum Tab: Hashable {
        case home, recent, search, favorites, shared, offline, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DocBrowserView(section: .home)
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
}
