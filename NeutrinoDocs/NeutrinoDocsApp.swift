import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI

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

    // Every one of these is built in `init()` rather than given a default value here.
    //
    // Default values are evaluated before the initializer's body runs, and the shared services
    // resolve their Keychain namespace through `NeutrinoApp.current` the moment they are
    // constructed — which traps when nothing has configured it yet. Constructing them in the body,
    // after `NeutrinoApp.configure(_:)`, is what makes the ordering enforceable rather than a
    // convention someone has to remember.
    @StateObject private var authService: AuthService
    @StateObject private var settings: AppSettings
    @StateObject private var biometricService: BiometricAuthService
    @StateObject private var deviceSessionService: DeviceSessionService
    @StateObject private var keyProvisioningService: KeyProvisioningService
    @StateObject private var keyVaultService: KeyVaultService
    @StateObject private var driveService: DocsDriveService
    @StateObject private var contentService: DocContentService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var offlineStore: OfflineStore
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var versionService: VersionHistoryService
    @StateObject private var searchService: SearchService
    @StateObject private var deepLinkRouter: DeepLinkRouter

    /// Built in `init()`, not lazily: `BGTaskScheduler` raises an exception for a handler
    /// registered after the app has finished launching, and anything created from a view's `.task`
    /// is by definition too late. On iOS 17 and later that exception is fatal at launch.
    private let backgroundSync: BackgroundSyncService

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        // Before anything else. Every shared service resolves its Keychain namespace, OAuth client
        // id and default host through this, and `NeutrinoApp.current` traps if one is built first.
        // `ndoc.*` is what previous builds wrote, so this reads the existing session and the
        // already-imported encryption key rather than starting cold.
        NeutrinoApp.configure(.docs)
        NeutrinoBrand.use(.docs)

        let contentService = DocContentService()
        let networkMonitor = NetworkMonitor()
        let offlineStore = OfflineStore()
        let syncEngine = SyncEngine(store: offlineStore, monitor: networkMonitor,
                                    content: contentService)
        _contentService = StateObject(wrappedValue: contentService)
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _offlineStore = StateObject(wrappedValue: offlineStore)
        _syncEngine = StateObject(wrappedValue: syncEngine)

        let settings = AppSettings()
        backgroundSync = BackgroundSyncService(syncEngine: syncEngine, store: offlineStore,
                                               settings: settings)
        // Registration, and only registration: scheduling a request is ordinary work and happens
        // once the app is wired up, in `configure()`.
        backgroundSync.register()

        _authService = StateObject(wrappedValue: AuthService())
        _settings = StateObject(wrappedValue: settings)
        _biometricService = StateObject(wrappedValue: BiometricAuthService(
            isFeatureEnabled: FeatureFlags.biometricLock
        ))
        _deviceSessionService = StateObject(wrappedValue: DeviceSessionService())
        _keyProvisioningService = StateObject(wrappedValue: KeyProvisioningService())
        _keyVaultService = StateObject(wrappedValue: KeyVaultService())
        _driveService = StateObject(wrappedValue: DocsDriveService())
        _versionService = StateObject(wrappedValue: VersionHistoryService())
        _searchService = StateObject(wrappedValue: SearchService())
        _deepLinkRouter = StateObject(wrappedValue: DeepLinkRouter())
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(settings)
                .environmentObject(biometricService)
                .environmentObject(deviceSessionService)
                .environmentObject(keyProvisioningService)
                .environmentObject(keyVaultService)
                .environmentObject(driveService)
                .environmentObject(contentService)
                .environmentObject(networkMonitor)
                .environmentObject(offlineStore)
                .environmentObject(syncEngine)
                .environmentObject(versionService)
                .environmentObject(searchService)
                .environmentObject(deepLinkRouter)
                .preferredColorScheme(settings.theme.colorScheme)
                .onOpenURL { url in
                    guard FeatureFlags.appLinks else { return }
                    deepLinkRouter.handle(url)
                }
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

        keyProvisioningService.authService = authService

        keyVaultService.authService = authService

        // Top up this device's retired keys from the account's key file. Enrolment already does
        // this, so on a healthy install it finds nothing; it is here for the device enrolled
        // before the key file existed, and for the one that was offline when its key arrived.
        // One request, and a failure is not worth surfacing — the next launch tries again.
        KeyFileService.shared.authService = authService
        if authService.isAuthenticated && KeyImportService.hasStoredKeys() {
            Task { try? await KeyFileService.shared.restoreArchivedKeys() }
        }

        searchService.contentService = contentService
        searchService.driveService = driveService
        searchService.offlineStore = offlineStore
        searchService.networkMonitor = networkMonitor
        // The index is sealed with a Keychain key that is only reachable once the device is
        // unlocked and the user is signed in, so loading it waits for a session.
        if authService.isAuthenticated { searchService.start() }

        syncEngine.attach(drive: driveService)
        syncEngine.start()

        backgroundSync.schedule()

        biometricService.lockOnLaunch()

        if authService.isAuthenticated {
            await authService.refreshTokenIfNeeded()
            // Whether this device still holds the account's key. One GET, and the answer is what
            // turns "No encryption key found" on the first document the user opens into a prompt
            // for the encryption password now — see `RootView`.
            await keyVaultService.refresh()
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
            backgroundSync.schedule()
            // Anything indexed since the last write would otherwise sit in memory until the next
            // debounce fires, which may be after the process is gone.
            searchService.flushSave()
        @unknown default:
            break
        }
    }
}

// MARK: - RootView

/// Chooses between the login screen, the app, first-run encryption setup, and the lock overlay,
/// and owns the prompt that asks a newly signed-in device for the account's encryption key.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var biometricService: BiometricAuthService
    @EnvironmentObject private var keyProvisioningService: KeyProvisioningService
    @EnvironmentObject private var keyVaultService: KeyVaultService

    @State private var showsUnlock = false
    /// Offered once per launch. Somebody who dismissed it gets back through
    /// Settings › Encryption, and every document that needs the key still says so when opened.
    @State private var hasOfferedUnlock = false

    var body: some View {
        ZStack {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }

            // A layer rather than a sheet, so the lock overlay below still covers it: a recovery
            // kit must not reach the app-switcher snapshot. Owned here rather than by the sign-up
            // sheet because that sheet's host — the login screen — is gone by the time a session
            // exists.
            if authService.didRegisterThisSession {
                EncryptionSetupView(service: keyProvisioningService) {
                    authService.encryptionSetupFinished()
                    // The key this flow just minted is in the Keychain; say so without a round
                    // trip, so the prompt above never fires on the account that has only this
                    // second ago set one up.
                    keyVaultService.refreshFromKeychain()
                }
                .transition(.opacity)
            }

            // Drawn over everything, including the login screen: the switcher snapshot is taken
            // regardless of which one is showing.
            if biometricService.shouldPresentOverlay {
                LockScreenView(biometricService: biometricService)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: biometricService.shouldPresentOverlay)
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView()
                .environmentObject(keyVaultService)
        }
        // Prompted rather than blocked, matching the other Neutrino apps. The browser still lists
        // documents and Settings still opens — which matters, because the key file and recovery kit
        // routes live there — so a hard gate would lock the user out of their own way back in. Only
        // `.locked` prompts: `.unreachable` means the server never answered, which is no evidence
        // that this device has the wrong key.
        .onChange(of: keyVaultService.status) { status in
            guard status == .locked, !hasOfferedUnlock else { return }
            // Not over first-run setup: that flow is minting this device's key already, and the
            // vault it would be measured against does not exist yet.
            guard !authService.didRegisterThisSession else { return }
            hasOfferedUnlock = true
            showsUnlock = true
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            guard isAuthenticated else {
                // The next account to sign in here must be asked about its own vault rather than
                // judged against the one that just left.
                keyVaultService.reset()
                return
            }
            // The launch-time refresh in `configure()` is skipped for a signed-out start, so this
            // is the only one a fresh sign-in gets.
            hasOfferedUnlock = false
            Task { await keyVaultService.refresh() }
        }
    }
}
