import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - InsertImageSheet

/// Picks a picture to put in the document, from wherever it is.
///
/// ## Every source ends up a Drive file
///
/// A document stores `neutrino-drive:<fileId>` and nothing else — see ``DriveImageReference`` — so
/// the job here is to turn whatever was picked into a Drive file id. One source already is one: a
/// picture chosen from Drive is referenced where it stands, with no upload and no re-encode, so
/// using the same photograph in ten documents stores it once. A photo, a local file, or a linked
/// address is uploaded into the account's Attachments folder first, at its original resolution.
///
/// The upload happens on Insert rather than on preview. A picture staged and then abandoned would
/// otherwise leave a file in Attachments that no document mentions, and a sheet is a place people
/// back out of.
///
/// ## The wait is the interface
///
/// Pictures are stored at their original resolution, so Insert sends megabytes over whatever
/// connection the phone has. That is too long to spend behind a spinner that says nothing, so the
/// upload reports the bytes it has sent, can be stopped, and — when it fails — leaves everything
/// staged so the button becomes "Try Again" rather than sending somebody back to the photo library
/// for a picture they already chose.
///
/// Cancelling costs nothing on the server: a file record is only written by the request that
/// carries the bytes, so an upload that never finishes leaves nothing behind to clean up.
struct InsertImageSheet: View {

    /// Called with the finished pieces of the picture: its alt text, and the `neutrino-drive:`
    /// reference the document should store.
    let onInsert: (_ alt: String, _ source: String) -> Void

    @EnvironmentObject private var contentService: DocContentService
    @Environment(\.dismiss) private var dismiss

    @State private var source: Source = .photos
    @State private var altText = ""
    @State private var linkURL = ""
    @State private var photoSelection: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isWorking = false
    @State private var failure: String?

    /// The picture that has been chosen but not yet inserted. Nothing reaches the document until
    /// this has been looked at: a filename is not enough to tell one photograph from another, and
    /// an image is not a thing anybody can pick sight unseen.
    ///
    /// Deliberately kept when an upload fails. Making somebody find the same photograph again
    /// because the network dropped is the app losing their work, so a failure leaves everything
    /// staged and the button becomes "Try Again".
    @State private var pending: Pending?

    /// The upload in flight, so it can be stopped. Nil whenever nothing is being sent.
    @State private var upload: Task<Void, Never>?

    /// Bytes sent so far, as a fraction. Nil while nothing is uploading, and also for the first
    /// moment of one — `URLSession` reports nothing until the first chunk goes out.
    @State private var progress: Double?

    // MARK: - Pending

    struct Pending {
        /// How the picture becomes a Drive file when Insert is tapped.
        let outcome: Outcome
        /// What to show in the sheet.
        let preview: UIImage?
        let caption: String

        /// A document only ever stores a reference, so every source has to end up as a Drive file.
        /// One of them already is.
        enum Outcome {
            /// Already in Drive: the document can reference it where it stands, with no upload and
            /// no re-encode. Picking the same picture into ten documents stores it once.
            case driveFile(id: String)
            /// Bytes that have to be uploaded into Attachments first — a photo, a local file, or
            /// something copied from a link. Carried as they will be stored, so what is previewed
            /// and what is uploaded cannot drift apart.
            case upload(EditorImage.Prepared, name: String)
        }
    }

    // MARK: - Source

    enum Source: String, CaseIterable, Identifiable {
        case photos = "Photos"
        case link = "Link"
        case drive = "Drive"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .photos: return "photo.on.rectangle"
            case .link:   return "link"
            case .drive:  return "folder"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        Form {
            if let pending {
                previewSection(pending)
            } else {
                Section {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { source in
                            Label(source.rawValue, systemImage: source.systemImage).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch source {
                case .photos: photosSection
                case .link:   linkSection
                case .drive:  driveSection
                }
            }

            Section {
                TextField("Description", text: $altText)
                    .textInputAutocapitalization(.sentences)
            } header: {
                Text("Alt Text")
            } footer: {
                Text("Read aloud by VoiceOver, and shown if the image can't be loaded.")
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .disabled(isWorking)
        .navigationTitle("Insert Image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // Off while the sheet is busy, so stopping an upload is the overlay's Cancel and
                // only that. Whether a toolbar inherits `disabled` from the view it is attached to
                // is not something to leave to inference when the two buttons say different things.
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(failure == nil ? "Insert" : "Try Again") { insert() }
                    .disabled(pending == nil || isWorking)
            }
        }
        // Outside `disabled`, so its Cancel button still answers while the form behind it does not.
        .overlay { workingOverlay }
    }

    // MARK: - Working

    /// What the sheet shows while it is busy.
    ///
    /// An upload of a full-resolution photograph is megabytes over whatever connection the phone
    /// has, which is long enough that a blank spinner reads as a hang. Staging a picture — decoding
    /// it, fetching one from Drive to preview — is quick and has no measurable fraction, so that
    /// keeps the spinner.
    @ViewBuilder
    private var workingOverlay: some View {
        if isWorking {
            ZStack {
                Color(uiColor: .systemBackground).opacity(0.6).ignoresSafeArea()

                VStack(spacing: 12) {
                    if let uploading = pendingUploadBytes {
                        Text("Uploading…").font(.headline)
                        ProgressView(value: progress ?? 0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                        Text(sentDescription(of: uploading))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { upload?.cancel() }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    /// The size of the picture being uploaded, or nil when nothing is being uploaded — staging, or
    /// a Drive picture that is referenced where it stands and never travels.
    private var pendingUploadBytes: Int? {
        guard upload != nil, case .upload(let prepared, _) = pending?.outcome else { return nil }
        return prepared.data.count
    }

    private func sentDescription(of total: Int) -> String {
        let sent = Int64(Double(total) * (progress ?? 0))
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: sent)) of \(formatter.string(fromByteCount: Int64(total)))"
    }

    // MARK: - Preview

    /// What was chosen, at a size worth looking at, with the way back to choosing something else.
    @ViewBuilder
    private func previewSection(_ pending: Pending) -> some View {
        Section {
            HStack {
                Spacer(minLength: 0)
                if let preview = pending.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Every source is fetched and decoded before it gets here, so this is the
                    // narrow case of bytes that arrived but are not a picture.
                    Label("That file isn't an image this app can show",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)

            Button("Choose Something Else") {
                self.pending = nil
                photoSelection = nil
            }
        } header: {
            Text(pending.caption)
        }
    }

    // MARK: - Photos and files

    @ViewBuilder
    private var photosSection: some View {
        Section {
            PhotosPicker(selection: $photoSelection, matching: .images, photoLibrary: .shared()) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Choose a File", systemImage: "folder")
            }
        } footer: {
            Text("The picture is saved to your Drive at its original size, and the document "
                 + "refers to it rather than carrying a copy.")
        }
        .onChange(of: photoSelection) { item in
            guard let item else { return }
            Task { await insertPickedPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await insertFile(at: url) }
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }

    // MARK: - Link

    @ViewBuilder
    private var linkSection: some View {
        Section {
            TextField("https://example.com/picture.png", text: $linkURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Button("Preview") {
                Task { await insertLink(linkURL) }
            }
            .disabled(linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text("The picture is copied into your Drive, so the document keeps showing it even if "
                 + "the original address stops working.")
        }
    }

    // MARK: - Drive

    @ViewBuilder
    private var driveSection: some View {
        DriveImagePicker { item in
            Task { await insertDriveImage(item) }
        }
    }

    // MARK: - Insertion

    /// The name is the library's own — "IMG_0042" — carried through so a Drive full of inserted
    /// pictures is a list of distinguishable files rather than an `Image.jpg` twenty times over.
    /// Only the stem survives: a HEIC stored as JPEG has to be named for what it now is.
    private func insertPickedPhoto(_ item: PhotosPickerItem) async {
        await stage {
            guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else {
                throw EditorImage.Failure.unreadable
            }
            let prepared = try EditorImage.prepared(photo.data)
            let name = EditorImage.fileName(from: photo.name, extension: prepared.fileExtension)
            return (.upload(prepared, name: name), name)
        }
    }

    private func insertFile(at url: URL) async {
        if altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            altText = url.deletingPathExtension().lastPathComponent
        }
        await stage(caption: url.lastPathComponent) {
            // A file from the Files app arrives outside the sandbox, so it has to be opened for
            // access explicitly and closed again whatever happens.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let prepared = try EditorImage.prepared(try Data(contentsOf: url))
            return .upload(prepared, name: EditorImage.fileName(from: url.lastPathComponent,
                                                                extension: prepared.fileExtension))
        }
    }

    /// Copies a linked picture into Drive rather than pointing the document at somebody else's
    /// server.
    ///
    /// The web app does the same, for the same reason: a document that references a Drive file
    /// still shows its pictures after the original link rots. It also leaves one rule — every
    /// picture in a document is a Drive file — instead of a second kind of source to resolve.
    private func insertLink(_ address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            failure = "That doesn't look like a web address."
            return
        }

        let name = url.lastPathComponent
        await stage(caption: name.isEmpty ? trimmed : name) {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InsertImageFailure.download(statusCode: http.statusCode)
            }
            let prepared = try EditorImage.prepared(data)
            return .upload(prepared, name: EditorImage.fileName(from: name,
                                                                extension: prepared.fileExtension))
        }
    }

    private func insertDriveImage(_ item: DocItem) async {
        if altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            altText = item.displayName
        }
        await stage(caption: item.name) { .driveFile(id: item.id) }
    }

    /// Works out what Insert would do and shows the result, rather than doing it.
    ///
    /// Nothing is uploaded here. A picture staged and then abandoned would otherwise leave a file
    /// in Attachments that no document mentions, and a sheet is a place people back out of.
    ///
    /// The preview is decoded from the very bytes that will be uploaded, so what is on screen is
    /// what gets stored. One already in Drive is previewed by fetching it, for the same reason.
    private func stage(caption: String,
                       _ build: @escaping () async throws -> Pending.Outcome) async {
        await stage { (try await build(), caption) }
    }

    /// The same, for a source whose caption is only known once it has been fetched — a photo, whose
    /// name comes back with the bytes.
    private func stage(_ build: @escaping () async throws -> (Pending.Outcome, String)) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }

        do {
            let (outcome, caption) = try await build()
            pending = Pending(outcome: outcome,
                              preview: try await preview(of: outcome),
                              caption: caption)
        } catch {
            failure = error.localizedDescription
            photoSelection = nil
        }
    }

    private func preview(of outcome: Pending.Outcome) async throws -> UIImage? {
        switch outcome {
        case .upload(let prepared, _):
            return EditorImageStore.image(from: prepared.data)
        case .driveFile(let id):
            return EditorImageStore.image(
                from: try await contentService.attachmentData(forFileID: id))
        }
    }

    /// Turns what was staged into the reference the document stores, uploading the bytes first
    /// unless the picture is already a Drive file.
    ///
    /// The staged picture is kept whatever happens short of success, so a failed or cancelled
    /// upload can be retried from where it was rather than from the photo library.
    private func insert() {
        guard let pending else { return }

        let task = Task {
            isWorking = true
            failure = nil
            progress = nil
            defer {
                isWorking = false
                progress = nil
                upload = nil
            }

            do {
                let fileID: String
                switch pending.outcome {
                case .driveFile(let id):
                    fileID = id
                case .upload(let prepared, let name):
                    fileID = try await contentService.uploadAttachment(
                        prepared.data, name: name, mimeType: prepared.mimeType,
                        onProgress: { progress = $0 })
                }
                onInsert(altText, DriveImageReference.source(fileID: fileID))
                dismiss()
            } catch is CancellationError {
                // The user stopped it. Nothing reached the document and nothing is on the server,
                // so there is nothing to report — the staged picture is simply still staged.
            } catch {
                failure = error.localizedDescription
            }
        }
        upload = task
    }
}

// MARK: - PickedPhoto

/// A picture chosen from the photo library, with the name the library knows it by.
///
/// `PhotosPickerItem` will hand over `Data` and nothing else, which is why every photo inserted
/// before this became `Image.jpg` in Drive — the name was not lost, it was never asked for. The
/// picker does write the item to a temporary file named as it is in the library ("IMG_0042.HEIC"),
/// and a file-backed `Transferable` is the way to see that name: the alternative is looking the
/// asset up through `PHAsset`, which needs the library authorisation the picker exists to avoid.
struct PickedPhoto: Transferable {

    let data: Data
    /// The library's file name, or nil for an item that had no file to take one from.
    let name: String?

    static var transferRepresentation: some TransferRepresentation {
        // Preferred, for the name. The file is deleted as soon as this returns, so the bytes are
        // read here rather than the URL being carried out of the closure.
        FileRepresentation(importedContentType: .image) { received in
            PickedPhoto(data: try Data(contentsOf: received.file),
                        name: received.file.lastPathComponent)
        }
        // Not every item has a file behind it — one still being fetched from iCloud, one the picker
        // materialises in memory. Those are still pictures worth inserting, just nameless.
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(data: data, name: nil)
        }
    }
}

// MARK: - InsertImageFailure

/// What can go wrong fetching a picture from somewhere other than this device.
enum InsertImageFailure: LocalizedError {
    case download(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .download(let statusCode):
            return "The image could not be downloaded (HTTP \(statusCode))."
        }
    }
}

// MARK: - DriveImagePicker

/// Browses the images in Neutrino Drive — the listings this app has never shown, because every
/// other call it makes filters to `type=doc`.
private struct DriveImagePicker: View {

    let onSelect: (DocItem) -> Void

    @EnvironmentObject private var driveService: DocsDriveService

    @State private var folders: [DocItem] = []
    @State private var images: [DocItem] = []
    @State private var trail: [DocItem] = []
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        Section {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else if folders.isEmpty, images.isEmpty {
                Text(trail.isEmpty ? "No images in your Drive yet."
                                   : "No images in this folder.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(folders) { folder in
                    Button {
                        trail.append(folder)
                        Task { await load() }
                    } label: {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                }

                ForEach(images) { image in
                    Button {
                        onSelect(image)
                    } label: {
                        Label(image.name, systemImage: "photo")
                    }
                }
            }
        } header: {
            HStack {
                Text(trail.last?.name ?? "Recent")
                Spacer()
                if !trail.isEmpty {
                    Button("Back") {
                        trail.removeLast()
                        Task { await load() }
                    }
                    .textCase(nil)
                }
            }
        }
        .task { await load() }
    }

    /// The root of the picker is Recent rather than the drive's root folder: the picture somebody
    /// wants is usually one they have just added.
    private func load() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }

        do {
            if trail.isEmpty {
                folders = []
                images = try await driveService.fetchRecentImages()
                if images.isEmpty {
                    // Nothing recent is not the same as nothing at all.
                    let contents = try await driveService.fetchImages(inFolder: nil)
                    folders = contents.folders
                    images = contents.images
                }
            } else {
                let contents = try await driveService.fetchImages(inFolder: trail.last?.id)
                folders = contents.folders
                images = contents.images
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}
