import SwiftUI
import UIKit
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI

// MARK: - SettingsView

/// Phase 1 — Settings: theme, font size, editor font, auto-save interval, and sync settings, plus
/// the encryption-key, app-lock, and registered-device controls the other Phase 1 sections imply.
struct SettingsView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var biometricService: BiometricAuthService
    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var searchService: SearchService
    @EnvironmentObject private var keyProvisioningService: KeyProvisioningService

    @State private var hasKeys = KeyImportService.hasStoredKeys()
    /// Only true for an account that has published no key at all. Minting one for an account that
    /// already has an identity would retire it and orphan every document sealed to it, so the
    /// button is not offered on a guess — see `KeyProvisioningService`.
    @State private var canProvisionKey = false
    @State private var showEncryptionSetup = false
    @State private var showKitRestore = false
    @State private var showKeyImport = false
    @State private var showVaultUnlock = false
    @State private var showRemoveKeysConfirmation = false
    @State private var showSignOutConfirmation = false

    var body: some View {
        List {
            appearanceSection
            editorSection
            syncSection
            offlineSection
            encryptionSection
            securitySection
            accountSection
        }
        .navigationTitle("Settings")
        // One request, and only while this device has no key — an account that publishes one never
        // sees the button, so there is nothing to re-check.
        .task {
            if !hasKeys { canProvisionKey = await keyProvisioningService.canProvision() }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
        }
    }

    // MARK: - Editor

    /// Two sections: how the text looks, then how typing behaves.
    @ViewBuilder
    private var editorSection: some View {
        Section {
            Picker("Editor Font", selection: $settings.editorFont) {
                ForEach(EditorFont.allCases) { font in
                    Text(font.displayName)
                        .font(.system(.body, design: font.design))
                        .tag(font)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.fontSize,
                       in: AppSettings.fontSizeRange,
                       step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }

                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: settings.fontSize, design: settings.editorFont.design))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }

            Picker("Auto-Save", selection: $settings.autoSaveInterval) {
                ForEach(AppSettings.autoSaveIntervalOptions, id: \.self) { interval in
                    Text(AppSettings.autoSaveLabel(for: interval)).tag(interval)
                }
            }
        } header: {
            Text("Editor")
        } footer: {
            Text("Headings, quotes, and code scale with the size you choose here, and Dynamic Type still scales the editor on top of it. Auto-save runs this long after you stop typing.")
        }

        writingSection
    }

    // MARK: - Writing (Phase 2)

    /// Phase 2 — Editor Improvements. Kept in its own section so the Editor section stays about
    /// how the text *looks* and this one about how typing *behaves*.
    private var writingSection: some View {
        Section {
            Toggle("Continue Lists", isOn: $settings.smartLists)
            Toggle("Close Brackets", isOn: $settings.closeBrackets)

            Stepper(value: $settings.indentWidth, in: AppSettings.indentWidthRange) {
                HStack {
                    Text("Indent Width")
                    Spacer()
                    Text("\(settings.indentWidth) spaces")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Writing")
        } footer: {
            Text("Continue Lists carries a bullet, number, or checkbox onto the next line when you press Return, and ends the list when you press it on an empty item.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Toggle("Auto-Sync", isOn: $settings.autoSyncEnabled)
            Toggle("Sync on Cellular", isOn: $settings.syncOnCellular)
                .disabled(!settings.autoSyncEnabled)
        } header: {
            Text("Synchronization")
        } footer: {
            Text(settings.autoSyncEnabled
                 ? "Changes sync automatically when you reconnect and in the background."
                 : "Changes stay on this device until you sync manually from the Offline tab.")
        }
    }

    // MARK: - Offline

    private var offlineSection: some View {
        Section {
            Toggle("Cache Recent Documents", isOn: $settings.cacheRecents)
            Toggle("Cache Favorites", isOn: $settings.cacheFavorites)

            LabeledContent("Storage Used",
                           value: ByteCountFormatter.string(fromByteCount: offlineStore.totalBytesOnDisk,
                                                            countStyle: .file))

            Button("Clear Automatic Cache") {
                try? offlineStore.evictAutomaticEntries()
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Clearing keeps documents you chose to make available offline, and anything with unsynced changes.")
        }
    }

    // MARK: - Encryption

    private var encryptionSection: some View {
        Section {
            if hasKeys {
                Label("Encryption key imported", systemImage: "key.fill")
                    .foregroundStyle(.primary)

                Button("Remove Keys", role: .destructive) {
                    showRemoveKeysConfirmation = true
                }
                .alert("Remove Encryption Keys?", isPresented: $showRemoveKeysConfirmation) {
                    Button("Remove", role: .destructive) {
                        Task {
                            // Removing keys makes every cached document unreadable, so it sits
                            // behind the same gate as unlocking the app.
                            guard await biometricService.authenticateForKeyAccess() else { return }
                            KeyImportService.removeKeys()
                            hasKeys = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your documents stay encrypted on the server. You'll need to import your key again to read them on this device.")
                }
            } else {
                // Offered only to an account with nothing published — a new one, or one whose
                // first-run setup was skipped. Every other account needs its existing key brought
                // here, which is what the three options below are for.
                if canProvisionKey {
                    Button {
                        showEncryptionSetup = true
                    } label: {
                        Label("Set Up Encryption Key", systemImage: "checkmark.shield")
                    }
                    .fullScreenCover(isPresented: $showEncryptionSetup) {
                        EncryptionSetupView(service: keyProvisioningService) {
                            showEncryptionSetup = false
                            hasKeys = KeyImportService.hasStoredKeys()
                            Task { canProvisionKey = await keyProvisioningService.canProvision() }
                        }
                    }
                }

                // Preferred path: the key is already on the server, wrapped.
                // Unlocking with the encryption password fetches it here, so
                // no file has to be moved between devices.
                Button {
                    showVaultUnlock = true
                } label: {
                    Label("Unlock with Password", systemImage: "lock.open")
                }
                .sheet(isPresented: $showVaultUnlock) {
                    hasKeys = KeyImportService.hasStoredKeys()
                } content: {
                    VaultUnlockView(isPresented: $showVaultUnlock) {
                        hasKeys = KeyImportService.hasStoredKeys()
                    }
                }

                // The route that needs nothing but what the user wrote down: no other device, no
                // web app in front of them, no server-side copy of anything.
                Button {
                    showKitRestore = true
                } label: {
                    Label("Restore From Recovery Kit", systemImage: "text.book.closed")
                }
                .sheet(isPresented: $showKitRestore) {
                    RecoveryKitRestoreView(service: keyProvisioningService,
                                           isPresented: $showKitRestore) {
                        hasKeys = KeyImportService.hasStoredKeys()
                        canProvisionKey = false
                    }
                }

                // Manual import stays for accounts created before the vault,
                // and for moving a key between accounts.
                Button {
                    showKeyImport = true
                } label: {
                    Label("Import Key File", systemImage: "key")
                }
                .sheet(isPresented: $showKeyImport) {
                    hasKeys = KeyImportService.hasStoredKeys()
                } content: {
                    KeyImportView(isPresented: $showKeyImport)
                }
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Your key is stored in the Keychain on this device only, and is never sent to the server.")
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section("Security") {
            NavigationLink {
                BiometricSettingsView(biometricService: biometricService)
            } label: {
                Label("App Lock", systemImage: "lock")
            }

            NavigationLink {
                DevicesView()
            } label: {
                Label("Registered Devices", systemImage: "iphone")
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showSignOutConfirmation = true
            }
            .alert("Sign Out?", isPresented: $showSignOutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    // The search index holds text decrypted from this account's documents, so it
                    // is destroyed with the session rather than left for whoever signs in next.
                    searchService.signOut()
                    authService.logout()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(offlineStore.totalPendingCount > 0
                     ? "You have \(offlineStore.totalPendingCount) unsynced change(s). Signing out keeps them on this device but they can't sync until you sign back in."
                     : "Your offline documents and encryption key stay on this device.")
            }

            Button("Reset Settings to Defaults") {
                settings.resetToDefaults()
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Neutrino Docs \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
        }
    }
}

// MARK: - BiometricSettingsView

/// Phase 1 — Encryption: "Unlock using Face ID", "Unlock using Touch ID".
struct BiometricSettingsView: View {

    @ObservedObject var biometricService: BiometricAuthService

    @State private var gracePeriod: TimeInterval = BiometricAuthService.defaultGracePeriod
    @State private var showUnavailableAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("Require \(biometricService.biometryName)", isOn: $biometricService.isEnabled)
                    .disabled(!availability.canEnable && !biometricService.isEnabled)
                    .onChange(of: biometricService.isEnabled) { newValue in
                        // The service reverts the toggle itself when biometrics are unusable;
                        // surface the reason rather than letting it silently flip back.
                        if !newValue, biometricService.lastError != nil, !availability.canEnable {
                            showUnavailableAlert = true
                        }
                    }
            } footer: {
                Text(footerText)
            }

            if biometricService.isEnabled {
                Section {
                    Picker("Lock After", selection: $gracePeriod) {
                        ForEach(BiometricAuthService.gracePeriodOptions, id: \.self) { seconds in
                            Text(Self.label(for: seconds)).tag(seconds)
                        }
                    }
                    .onChange(of: gracePeriod) { newValue in
                        biometricService.gracePeriod = newValue
                    }
                } header: {
                    Text("Grace Period")
                } footer: {
                    Text("How long the app may stay in the background before it locks again. Your documents are hidden from the app switcher immediately, regardless of this setting.")
                }
            }

            if !availability.canEnable {
                Section {
                    Label(availability.explanation, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { gracePeriod = biometricService.gracePeriod }
        .alert("Cannot Enable", isPresented: $showUnavailableAlert) {
            Button("OK") {}
        } message: {
            Text(availability.explanation)
        }
    }

    private var availability: BiometricAvailability { biometricService.availability() }

    private var footerText: String {
        biometricService.isEnabled
            ? "Neutrino Docs asks for \(biometricService.biometryName) — or your device passcode — before showing your documents, and before your encryption key can be removed."
            : "When on, Neutrino Docs asks for \(biometricService.biometryName) before showing your documents. Your device passcode always works as a fallback, so a locked-out sensor never strands you."
    }

    private static func label(for seconds: TimeInterval) -> String {
        switch seconds {
        case 0:   return "Immediately"
        case 60:  return "After 1 minute"
        case 300: return "After 5 minutes"
        case 900: return "After 15 minutes"
        default:  return "After \(Int(seconds))s"
        }
    }
}

// MARK: - DevicesView

/// Phase 1 — Authentication: "Device registration". Lists the devices registered against this
/// account and revokes them.
struct DevicesView: View {

    @EnvironmentObject private var deviceService: DeviceSessionService

    @State private var revokeTarget: DeviceSession?

    var body: some View {
        List {
            Section {
                if deviceService.sessions.isEmpty && !deviceService.isLoading {
                    Text("No registered devices found.")
                        .foregroundStyle(.secondary)
                }

                ForEach(deviceService.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.displayName).lineLimit(1)
                            if session.isCurrentDevice {
                                Text("This device")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(session.lastUsedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            revokeTarget = session
                        } label: {
                            Label("Revoke", systemImage: "xmark.circle")
                        }
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("This device registered as \u{201C}\(DeviceIdentity.deviceName)\u{201D} when you signed in. Revoking signs that device out.")
            }
        }
        .navigationTitle("Registered Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await deviceService.load() }
        .task { await deviceService.load() }
        .overlay {
            if deviceService.isLoading && deviceService.sessions.isEmpty { ProgressView() }
        }
        .alert("Revoke this device?", isPresented: Binding(
            get: { revokeTarget != nil },
            set: { if !$0 { revokeTarget = nil } }
        )) {
            Button("Revoke", role: .destructive) {
                if let target = revokeTarget {
                    Task { await deviceService.revoke(sessionID: target.id) }
                }
                revokeTarget = nil
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: {
            Text(revokeTarget?.isCurrentDevice == true
                 ? "This is the device you're using. Revoking it signs you out here."
                 : "That device will need to sign in again.")
        }
    }
}
