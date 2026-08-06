import SwiftUI

// MARK: - SearchFiltersView

/// Phase 5 — Global Search, "Filters: Owner, Folder, Modified, Tags".
///
/// Edits a binding rather than its own copy, so the results behind the sheet update as filters are
/// changed instead of only when it is dismissed.
struct SearchFiltersView: View {

    @Binding var filters: SearchFilters
    let availableTags: [String]

    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    /// Bound separately from `filters.modifiedAfter`/`Before`, because a date picker needs a
    /// non-optional date and "no date set" has to stay distinguishable from "today".
    @State private var isModifiedAfterEnabled = false
    @State private var isModifiedBeforeEnabled = false
    @State private var modifiedAfter = Date().addingTimeInterval(-30 * 24 * 3600)
    @State private var modifiedBefore = Date()

    // MARK: - Body

    var body: some View {
        Form {
            ownerSection
            folderSection
            modifiedSection
            tagsSection
        }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear") { clear() }
                    .disabled(!filters.isActive)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: syncDateToggles)
        .onChange(of: isModifiedAfterEnabled) { _ in applyDates() }
        .onChange(of: isModifiedBeforeEnabled) { _ in applyDates() }
        .onChange(of: modifiedAfter) { _ in applyDates() }
        .onChange(of: modifiedBefore) { _ in applyDates() }
    }

    // MARK: - Owner

    private var ownerSection: some View {
        Section("Owner") {
            Picker("Owned by", selection: $filters.ownership) {
                ForEach(SearchFilters.Ownership.allCases) { ownership in
                    Text(ownership.displayName).tag(ownership)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section {
            Picker("Folder", selection: folderSelection) {
                Text("Anywhere").tag(String?.none)
                ForEach(folders, id: \.id) { folder in
                    Text(folder.name).tag(String?.some(folder.id))
                }
            }
        } header: {
            Text("Folder")
        } footer: {
            Text("Searching a folder includes everything inside it.")
        }
    }

    /// Reads and writes `filters.folderIDs` as a single folder choice, expanding the choice to the
    /// folder's whole subtree — "in this folder" reasonably means "in here somewhere".
    private var folderSelection: Binding<String?> {
        Binding(
            get: {
                guard let ids = filters.folderIDs else { return nil }
                // The chosen folder is the one in the set whose parent is not also in it.
                return folders.first { ids.contains($0.id) && !ids.contains($0.parentID ?? "") }?.id
            },
            set: { newValue in
                guard let newValue else {
                    filters.folderIDs = nil
                    return
                }
                filters.folderIDs = subtree(of: newValue)
            }
        )
    }

    /// A folder and every folder beneath it.
    private func subtree(of folderID: String) -> Set<String> {
        var result: Set<String> = [folderID]
        var pending = [folderID]
        while let current = pending.popLast() {
            for folder in folders where folder.parentID == current && result.insert(folder.id).inserted {
                pending.append(folder.id)
            }
        }
        return result
    }

    private var folders: [DocItem] {
        driveService.allItems
            .filter { $0.type == .folder && !$0.isTrashed }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Modified

    private var modifiedSection: some View {
        Section("Modified") {
            Toggle("After", isOn: $isModifiedAfterEnabled)
            if isModifiedAfterEnabled {
                DatePicker("On or after", selection: $modifiedAfter, displayedComponents: .date)
            }
            Toggle("Before", isOn: $isModifiedBeforeEnabled)
            if isModifiedBeforeEnabled {
                DatePicker("On or before", selection: $modifiedBefore, displayedComponents: .date)
            }
        }
    }

    private func applyDates() {
        // The pickers give a time of day; the bounds are widened to whole days so "before the 5th"
        // includes documents edited during the 5th rather than only before midnight.
        filters.modifiedAfter = isModifiedAfterEnabled
            ? Calendar.current.startOfDay(for: modifiedAfter)
            : nil
        filters.modifiedBefore = isModifiedBeforeEnabled
            ? Calendar.current.date(byAdding: .day, value: 1,
                                    to: Calendar.current.startOfDay(for: modifiedBefore))
            : nil
    }

    private func syncDateToggles() {
        isModifiedAfterEnabled = filters.modifiedAfter != nil
        isModifiedBeforeEnabled = filters.modifiedBefore != nil
        if let after = filters.modifiedAfter { modifiedAfter = after }
        if let before = filters.modifiedBefore { modifiedBefore = before }
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsSection: some View {
        Section {
            if availableTags.isEmpty {
                Text("No tags yet. Add a `tags:` line to a document's front matter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableTags, id: \.self) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        HStack {
                            Text("#\(tag)")
                                .foregroundStyle(.primary)
                            Spacer()
                            if filters.tags.contains(tag) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Tags")
        } footer: {
            if filters.tags.count > 1 {
                Text("A document has to carry every selected tag.")
            }
        }
    }

    private func toggle(_ tag: String) {
        if filters.tags.contains(tag) {
            filters.tags.remove(tag)
        } else {
            filters.tags.insert(tag)
        }
    }

    // MARK: - Clear

    private func clear() {
        filters = .unfiltered
        syncDateToggles()
    }
}
