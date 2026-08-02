import SwiftUI
import UniformTypeIdentifiers

// MARK: - KeyImportView

/// Phase 1 — Encryption: "Import user key", "Store in Keychain".
///
/// Accepts the JSON key file the Neutrino web app exports, either picked from Files or pasted, and
/// stores the validated pair in the Keychain.
struct KeyImportView: View {

    @Binding var isPresented: Bool

    @State private var showFilePicker = false
    @State private var pastedText = ""
    @State private var errorMessage: String?
    @State private var importedVersion: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your encryption key never leaves this device. It is stored in the Keychain and used to decrypt your documents locally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Import From File") {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose Key File…", systemImage: "folder")
                    }
                }

                Section("Or Paste Key JSON") {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Import Pasted Key") {
                        importPasted()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let importedVersion {
                    Section {
                        Label("Key imported (version \(importedVersion))", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Import Encryption Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .plainText],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
        }
    }

    // MARK: - Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        do {
            guard let url = try result.get().first else { return }
            // A file picked from Files is outside the app's sandbox until this is granted, and the
            // read fails silently without it.
            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try store(data)
        } catch let error as KeyImportError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPasted() {
        errorMessage = nil
        do {
            try store(Data(pastedText.utf8))
        } catch let error as KeyImportError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func store(_ data: Data) throws {
        let bundle = try KeyImportService.importKey(from: data)
        KeyImportService.storeKeys(bundle)
        importedVersion = bundle.keyVersion
        pastedText = ""
        // Left on screen for a moment so the confirmation is actually seen before the sheet goes.
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            isPresented = false
        }
    }
}

#Preview {
    KeyImportView(isPresented: .constant(true))
}
