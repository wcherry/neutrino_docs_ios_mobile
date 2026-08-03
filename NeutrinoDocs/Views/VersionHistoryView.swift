import SwiftUI
import Sodium

// MARK: - VersionHistoryView

/// Phase 1 — Version History: "Previous versions", "Restore version", "View timestamps".
struct VersionHistoryView: View {

    // MARK: - Input

    let item: DocItem
    /// The editing session's DEK. Needed to preview a snapshot; a file's DEK never rotates, so the
    /// one the editor already holds decrypts every version.
    let currentDEK: Bytes?
    /// Called with the restored body so the editor can adopt it without reloading. The whole body
    /// travels, not just the text: a restore puts back the snapshot's page setup too.
    let onRestore: (DocumentBody) -> Void

    // MARK: - Environment

    @EnvironmentObject private var versionService: VersionHistoryService
    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var versions: [DocVersion] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var previewing: DocVersion?
    @State private var previewText: String?
    @State private var restoringID: String?

    // MARK: - Body

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if versions.isEmpty && !isLoading {
                Text("No previous versions yet. Automatic saves don't create versions — use \u{201C}Save Version…\u{201D} to keep one.")
                    .foregroundStyle(.secondary)
            }

            ForEach(versions) { version in
                row(for: version)
            }
        }
        .navigationTitle("Version History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .overlay {
            if isLoading { ProgressView() }
        }
        .task { await load() }
        .sheet(item: $previewing) { version in
            NavigationStack {
                Group {
                    if let previewText {
                        MarkdownView(text: previewText)
                    } else {
                        ProgressView()
                    }
                }
                .navigationTitle(version.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { previewing = nil; previewText = nil }
                    }
                }
                .task { await loadPreview(version) }
            }
        }
    }

    // MARK: - Row

    private func row(for version: DocVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(version.displayTitle)
                    .font(.headline)
                if version.isNamed {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Named version")
                }
                Spacer()
                if restoringID == version.id {
                    ProgressView()
                }
            }
            Text(version.timestampText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: version.sizeBytes, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Preview") { previewing = version }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentDEK == nil)

                Button("Restore") {
                    Task { await restore(version) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(restoringID != nil)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            versions = try await versionService.listVersions(fileID: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPreview(_ version: DocVersion) async {
        guard let currentDEK else { return }
        previewText = nil
        do {
            previewText = try await versionService.versionBody(fileID: item.id,
                                                               versionID: version.id,
                                                               dek: currentDEK).markdown
        } catch {
            previewText = "Couldn't load this version: \(error.localizedDescription)"
        }
    }

    private func restore(_ version: DocVersion) async {
        restoringID = version.id
        defer { restoringID = nil }
        do {
            let result = try await versionService.restore(versionID: version.id, fileID: item.id)
            driveService.documentWasSaved(itemID: item.id,
                                          size: result.sizeBytes,
                                          modifiedAt: result.modifiedAt)
            // Hand the restored text back so the open editor shows it immediately. Restoring is
            // itself snapshotted server-side first, so this is undoable from the same list.
            if let currentDEK {
                let body = try await versionService.versionBody(fileID: item.id,
                                                                versionID: version.id,
                                                                dek: currentDEK)
                onRestore(body)
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
