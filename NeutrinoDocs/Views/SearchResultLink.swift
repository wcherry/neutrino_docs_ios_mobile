import SwiftUI
import NeutrinoCore

// MARK: - SearchResultLink

/// One search result as a row that opens the document.
///
/// A result often names a document no listing in this session has loaded — one indexed in an earlier
/// session, or a Drive name match from a folder never opened — so when the item is not cached the
/// link opens a loader that fetches it first instead of leaving the row dead.
struct SearchResultLink: View {

    let result: SearchResult

    @EnvironmentObject private var driveService: DocsDriveService
    @EnvironmentObject private var offlineStore: OfflineStore

    var body: some View {
        NavigationLink {
            if let item = driveService.item(id: result.documentID) {
                DocEditorView(item: item)
            } else {
                ResolvingDocEditor(documentID: result.documentID, title: result.title)
            }
        } label: {
            SearchResultRow(result: result,
                            isAvailableOffline: offlineStore.isAvailableOffline(result.documentID))
        }
    }
}

// MARK: - ResolvingDocEditor

/// Fetches a document's Drive metadata, then shows the editor for it.
private struct ResolvingDocEditor: View {

    let documentID: String
    let title: String

    @EnvironmentObject private var driveService: DocsDriveService

    @State private var item: DocItem?
    @State private var failure: String?

    var body: some View {
        Group {
            if let item {
                DocEditorView(item: item)
            } else if let failure {
                ContentUnavailableViewCompat(
                    title: "Can't open \u{201C}\(title)\u{201D}",
                    message: failure,
                    systemImage: "doc.questionmark"
                ) {
                    Button("Try Again") { Task { await resolve() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard item == nil else { return }
        failure = nil
        do {
            item = try await driveService.fetchItem(id: documentID)
        } catch {
            failure = error.localizedDescription
        }
    }
}
