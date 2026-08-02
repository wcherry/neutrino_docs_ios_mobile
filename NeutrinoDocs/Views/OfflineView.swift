import SwiftUI

// MARK: - OfflineView

/// Phase 1 — Offline Mode and Synchronization.
///
/// Shows what is cached, what is waiting to sync, and anything that conflicted, and offers the
/// manual sync that Phase 1 asks for alongside auto-sync.
struct OfflineView: View {

    @EnvironmentObject private var offlineStore: OfflineStore
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var driveService: DocsDriveService

    @State private var actionError: String?

    var body: some View {
        List {
            syncSection

            if !conflicts.isEmpty {
                conflictSection
            }

            if !offlineStore.pendingMutations.isEmpty {
                mutationQueueSection
            }

            cachedSection
        }
        .navigationTitle("Offline")
        .refreshable { await syncEngine.syncNow() }
        .alert("Something went wrong",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            HStack {
                Label(syncEngine.state.message, systemImage: syncIcon)
                    .foregroundStyle(syncEngine.state == .idle ? Color.secondary : Color.primary)
                Spacer()
                if case .syncing = syncEngine.state {
                    ProgressView()
                }
            }

            if let lastSyncedAt = syncEngine.lastSyncedAt {
                LabeledContent("Last synced",
                               value: lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
            }

            Button {
                Task { await syncEngine.syncNow() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!networkMonitor.isOnline)
        } header: {
            Text("Synchronization")
        } footer: {
            Text(networkMonitor.isOnline
                 ? "Changes sync automatically. \(offlineStore.totalPendingCount) item(s) waiting."
                 : "You're offline. Changes are saved on this device and will sync when you reconnect.")
        }
    }

    private var syncIcon: String {
        switch syncEngine.state {
        case .idle:    return "checkmark.circle"
        case .offline: return "wifi.slash"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed:  return "exclamationmark.triangle"
        }
    }

    // MARK: - Conflicts

    private var conflicts: [OfflineDoc] {
        offlineStore.documents.filter { $0.conflict != nil }
    }

    private var conflictSection: some View {
        Section {
            ForEach(conflicts) { doc in
                VStack(alignment: .leading, spacing: 8) {
                    Text(doc.name).font(.headline)
                    Text("This document changed on the server while you were editing it offline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Keep Mine") {
                            do {
                                try offlineStore.resolveKeepingLocal(id: doc.id)
                                syncEngine.requestSync()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Use Server's") {
                            Task {
                                do {
                                    try await offlineStore.resolveKeepingServer(id: doc.id)
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("Nothing is uploaded until you choose — a queued edit never overwrites somebody else's work.")
        }
    }

    // MARK: - Queued mutations

    private var mutationQueueSection: some View {
        Section {
            ForEach(offlineStore.pendingMutations) { mutation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(mutation.summary)
                    Text(name(for: mutation.itemID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = mutation.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Button("Discard Queued Changes", role: .destructive) {
                offlineStore.clearMutationQueue()
            }
        } header: {
            Text("Queued Changes")
        } footer: {
            Text("Deletes, moves, and renames made offline. They replay in order when you reconnect.")
        }
    }

    private func name(for itemID: String) -> String {
        offlineStore.document(id: itemID)?.name
            ?? driveService.item(id: itemID)?.name
            ?? itemID
    }

    // MARK: - Cached documents

    private var cachedSection: some View {
        Section {
            if offlineStore.documents.isEmpty {
                Text("No documents are stored on this device yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(offlineStore.documents) { doc in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(doc.cacheReason.displayName)
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: doc.sizeBytes, countStyle: .file))
                            if doc.pendingEdit != nil {
                                Text("·")
                                Text("Unsynced").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions {
                    Button(role: .destructive) {
                        do {
                            try offlineStore.remove(id: doc.id)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Stored On This Device")
        } footer: {
            Text("\(ByteCountFormatter.string(fromByteCount: offlineStore.totalBytesOnDisk, countStyle: .file)) used. Documents are stored encrypted — reading them needs your key.")
        }
    }
}
