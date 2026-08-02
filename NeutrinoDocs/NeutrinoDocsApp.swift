import SwiftUI

// MARK: - NeutrinoDocsApp

/// Composition root. Every service is constructed once here and injected into the view tree;
/// nothing reaches for a singleton.
///
/// The wiring is deliberately explicit rather than hidden behind a container: the services form a
/// small graph with genuine cycles — the drive service needs the offline store, the sync engine
/// needs the drive service — and writing it out is what makes those cycles visible and their
/// ownership (`weak`) obvious.
@main
struct NeutrinoDocsApp: App {

    // MARK: - Services

    @StateObject private var authService = AuthService()
    @StateObject private var settings = AppSettings()
    @StateObject private var biometricService = BiometricAuthService()
    @StateObject private var deviceSessionService = DeviceSessionService()
    @StateObject private var driveService = DocsDriveService()
    @StateObject private var contentService: DocContentService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var offlineStore: OfflineStore
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var versionService = VersionHistoryService()

    @State private var backgroundSync: BackgroundSyncService?

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        let contentService = DocContentService()
        let networkMonitor = NetworkMonitor()
        let offlineStore = OfflineStore()
        _contentService = StateObject(wrappedValue: contentService)
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _offlineStore = StateObject(wrappedValue: offlineStore)
        _syncEngine = StateObject(wrappedValue: SyncEngine(
            store: offlineStore, monitor: networkMonitor, content: contentService
        ))
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(settings)
                .environmentObject(biometricService)
                .environmentObject(deviceSessionService)
                .environmentObject(driveService)
                .environmentObject(contentService)
                .environmentObject(networkMonitor)
                .environmentObject(offlineStore)
                .environmentObject(syncEngine)
                .environmentObject(versionService)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await configure() }
        }
        .onChange(of: scenePhase) { phase in
            handle(phase)
        }
    }

    // MARK: - Wiring

    @MainActor
    private func configure() async {
        // Idempotent: `.task` can run again if the scene is rebuilt, and every assignment here is
        // a plain reference write.
        contentService.authService = authService

        driveService.authService = authService
        driveService.offlineStore = offlineStore
        driveService.contentService = contentService
        driveService.networkMonitor = networkMonitor

        offlineStore.contentService = contentService

        versionService.authService = authService
        versionService.contentService = contentService

        deviceSessionService.authService = authService

        syncEngine.attach(drive: driveService)
        syncEngine.start()

        if backgroundSync == nil {
            let service = BackgroundSyncService(syncEngine: syncEngine,
                                                store: offlineStore,
                                                settings: settings)
            service.register()
            service.schedule()
            backgroundSync = service
        }

        biometricService.lockOnLaunch()

        if authService.isAuthenticated {
            await authService.refreshTokenIfNeeded()
        }
    }

    // MARK: - Lifecycle

    @MainActor
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            biometricService.sceneDidBecomeActive()
            if settings.autoSyncEnabled { syncEngine.requestSync() }
        case .inactive:
            // Fires *before* `.background`, and is when iOS takes the app-switcher snapshot.
            biometricService.sceneDidBecomeInactive()
        case .background:
            biometricService.sceneDidEnterBackground()
            backgroundSync?.schedule()
        @unknown default:
            break
        }
    }
}

// MARK: - RootView

/// Chooses between the login screen, the app, and the lock overlay.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var biometricService: BiometricAuthService

    var body: some View {
        ZStack {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }

            // Drawn over everything, including the login screen: the switcher snapshot is taken
            // regardless of which one is showing.
            if biometricService.shouldPresentOverlay {
                LockScreenView(biometricService: biometricService)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: biometricService.shouldPresentOverlay)
    }
}
