import SwiftUI
import UIKit

// MARK: - SettingsView

/// Phase 1 — Settings: theme, font size, editor font, auto-save interval, and sync settings, plus
/// the encryption-key, app-lock, and registered-device controls the other Phase 1 sections imply.
struct SettingsView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var biometricService: BiometricAuthService
    @EnvironmentObject private var offlineStore: OfflineStore

    @State private var hasKeys = KeyImportService.hasStoredKeys()
    @State private var showKeyImport = false
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
            Text("Auto-save runs this long after you stop typing. Dynamic Type still scales the editor on top of the size you choose.")
        }

        writingSection
    }

    // MARK: - Writing (Phase 2)

    /// Phase 2 — Editor Improvements. Kept in its own section so the Editor section stays about
    /// how the text *looks* and this one about how typing *behaves*.
    private var writingSection: some View {
        Section {
            Toggle("Line Numbers", isOn: $settings.showLineNumbers)
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
                Button {
                    showKeyImport = true
                } label: {
                    Label("Import Encryption Key", systemImage: "key")
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
                Button("Sign Out", role: .destructive) { authService.logout() }
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
