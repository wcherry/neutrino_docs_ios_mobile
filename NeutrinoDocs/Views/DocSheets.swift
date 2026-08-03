import SwiftUI
import Sodium

// MARK: - CreateDocumentSheet

/// Phase 1 — Drive Integration, Operations: "Create document".
struct CreateDocumentSheet: View {

    let parentID: String?

    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Document name", text: $name)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Saved as Markdown. A \u{201C}.md\u{201D} extension is added if you leave it off.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                _ = try await driveService.createDocument(name: trimmed, parentID: parentID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - CreateFolderSheet

struct CreateFolderSheet: View {

    let parentID: String?

    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(create)
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        driveService.createFolder(name: trimmed, parentID: parentID)
        dismiss()
    }
}

// MARK: - RenameSheet

/// Phase 1 — Drive Integration, Operations: "Rename".
struct RenameSheet: View {

    let item: DocItem

    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(rename)
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = item.name }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: rename)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else {
            dismiss()
            return
        }
        driveService.rename(itemID: item.id, to: trimmed)
        dismiss()
    }
}

// MARK: - MoveSheet

/// Phase 1 — Drive Integration, Operations: "Move".
///
/// Only folders the item can legally land in are offered: its own subtree is excluded, since moving
/// a folder inside itself would detach it from the drive entirely.
struct MoveSheet: View {

    let item: DocItem

    @EnvironmentObject private var driveService: DocsDriveService
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: nil, name: "Drive", icon: "externaldrive", indent: 0)
                    ForEach(destinations, id: \.item.id) { destination in
                        row(id: destination.item.id,
                            name: destination.item.name,
                            icon: "folder",
                            indent: destination.depth + 1)
                    }
                } header: {
                    Text("Move \u{201C}\(item.displayName)\u{201D} to")
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { selection = item.parentID }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        driveService.move(itemID: item.id, to: selection)
                        dismiss()
                    }
                    .disabled(selection == item.parentID)
                }
            }
        }
    }

    private func row(id: String?, name: String, icon: String, indent: Int) -> some View {
        Button {
            selection = id
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(indent) * 16)
        }
    }

    /// The folder tree, depth-first, minus the item itself and anything beneath it.
    private var destinations: [(item: DocItem, depth: Int)] {
        var result: [(DocItem, Int)] = []

        func walk(parentID: String?, depth: Int) {
            let folders = driveService.allItems
                .filter { $0.type == .folder && $0.parentID == parentID && !$0.isTrashed }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for folder in folders {
                guard folder.id != item.id else { continue }
                guard !driveService.isDescendant(potentialChildID: folder.id, ofFolderID: item.id) else {
                    continue
                }
                result.append((folder, depth))
                walk(parentID: folder.id, depth: depth + 1)
            }
        }

        walk(parentID: nil, depth: 0)
        return result
    }
}

// MARK: - SaveVersionSheet

/// Saves a named snapshot. Autosave deliberately does not create versions server-side, so this is
/// how a document accumulates history.
struct SaveVersionSheet: View {

    let item: DocItem
    /// The body as the editor currently holds it, layout metadata included — a named version is
    /// also the document's new current content, so it has to carry everything a save carries.
    let documentBody: DocumentBody
    let dek: Bytes?

    @EnvironmentObject private var versionService: VersionHistoryService
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Version name (optional)", text: $label)
                } footer: {
                    Text("Named versions are kept indefinitely. This also saves the document's current content.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || dek == nil)
                }
            }
        }
    }

    private func save() {
        guard let dek, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let trimmed = label.trimmingCharacters(in: .whitespaces)
                _ = try await versionService.saveVersion(documentBody, for: item, dek: dek,
                                                         label: trimmed.isEmpty ? nil : trimmed)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
