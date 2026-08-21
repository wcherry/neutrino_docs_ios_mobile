import SwiftUI

// MARK: - ImagePropertiesSheet

/// Everything about a picture except the picture: how wide it is, where it sits, what is drawn
/// around it, and what it says.
///
/// The vocabulary is the web editor's, deliberately — same attributes, same names, same four
/// groupings as its properties panel, so that a document styled on one does not look edited by the
/// other. What differs is the shape: four tabs floating beside the document work on a desktop, and
/// on a phone the same thing is a form you scroll.
///
/// Nothing is applied until Done. An image is a thing people fiddle with, and a panel that wrote
/// every slider movement into the document would fill the undo stack with a hundred steps and send
/// a hundred autosaves.
struct ImagePropertiesSheet: View {

    let image: EditorImageSelection
    /// Called with the edited image. The caller is what knows where in the document it goes.
    let onApply: (EditorImageDescriptor) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var width: String
    @State private var alignment: ImageAlignment
    @State private var border: String
    @State private var shadow: ImageShadow
    @State private var brightness: Double
    @State private var contrast: Double
    @State private var saturation: Double
    @State private var alt: String
    @State private var title: String
    @State private var caption: String
    @State private var isConfirmingRemoval = false

    // MARK: - Init

    init(image: EditorImageSelection,
         onApply: @escaping (EditorImageDescriptor) -> Void,
         onRemove: @escaping () -> Void) {
        self.image = image
        self.onApply = onApply
        self.onRemove = onRemove

        let attributes = image.attributes
        _width = State(initialValue: attributes.width ?? "")
        _alignment = State(initialValue: attributes.alignment)
        _border = State(initialValue: attributes.border ?? "")
        _shadow = State(initialValue: attributes.shadow)
        _alt = State(initialValue: image.descriptor.alt)
        _title = State(initialValue: image.descriptor.title ?? "")
        _caption = State(initialValue: attributes.caption)

        let tint = attributes.appliedFilter ?? ImageAttributes.Filter()
        _brightness = State(initialValue: tint.brightness * 100)
        _contrast = State(initialValue: tint.contrast * 100)
        _saturation = State(initialValue: tint.saturation * 100)
    }

    // MARK: - Body

    var body: some View {
        Form {
            previewSection
            layoutSection
            appearanceSection
            tintSection
            metadataSection

            Section {
                Button("Remove Image", role: .destructive) { isConfirmingRemoval = true }
            }
        }
        .navigationTitle("Image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onApply(edited)
                    dismiss()
                }
            }
        }
        .confirmationDialog("Remove this image?",
                            isPresented: $isConfirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove Image", role: .destructive) {
                onRemove()
                dismiss()
            }
        } message: {
            Text("The picture is stored inside the document, so removing it here removes it for "
                 + "good.")
        }
    }

    // MARK: - The edited image

    /// What the panel would write, which is also what the preview shows.
    private var edited: EditorImageDescriptor {
        var attributes = image.attributes
        attributes.width = width.trimmingCharacters(in: .whitespaces).nilIfEmpty
        attributes.alignment = alignment
        attributes.border = border.trimmingCharacters(in: .whitespaces).nilIfEmpty
        attributes.shadow = shadow
        attributes.caption = caption.trimmingCharacters(in: .whitespaces)
        attributes.filter = ImageAttributes.Filter.css(brightness: brightness / 100,
                                                       contrast: contrast / 100,
                                                       saturation: saturation / 100)

        var edited = image.descriptor
        edited.alt = alt
        edited.title = title.trimmingCharacters(in: .whitespaces).nilIfEmpty
        edited.attributes = attributes
        return edited
    }

    // MARK: - Preview

    /// The picture as the settings would leave it, which is the only way to tell what a border of
    /// `2px dashed #888` is going to look like without applying it and undoing.
    @ViewBuilder
    private var previewSection: some View {
        Section {
            ImagePropertiesPreview(source: image.source, attributes: edited.attributes)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var layoutSection: some View {
        Section {
            HStack {
                Text("Width")
                Spacer()
                TextField("Auto", text: $width)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 140)
            }

            HStack {
                ForEach([ImageAttributes.WidthPreset.quarter, .half, .threeQuarters, .full],
                        id: \.rawValue) { preset in
                    Button(preset.label) { width = preset.rawValue }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.footnote)

            Picker("Position", selection: $alignment) {
                ForEach(ImageAlignment.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } header: {
            Text("Layout")
        } footer: {
            if alignment.isFloat {
                Text("Text flows around a floated image on the web. Here it sits on its own line, "
                     + "on the \(alignment == .floatLeft ? "left" : "right") — the setting is kept "
                     + "either way.")
            } else {
                Text("A width in per cent is of the column, so 50% is half the width of the text.")
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            HStack {
                Text("Border")
                Spacer()
                TextField("None", text: $border)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 180)
            }

            HStack {
                ForEach(ImageAttributes.borderPresets, id: \.label) { preset in
                    Button(preset.label) { border = preset.css }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.footnote)

            Picker("Shadow", selection: $shadow) {
                ForEach(ImageShadow.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("A border is CSS: a width, a style, and a colour — \"2px solid #333\".")
        }
    }

    // MARK: - Tint

    @ViewBuilder
    private var tintSection: some View {
        Section {
            slider("Brightness", value: $brightness, range: 50...150)
            slider("Contrast", value: $contrast, range: 50...150)
            slider("Saturation", value: $saturation, range: 0...200)

            if brightness != 100 || contrast != 100 || saturation != 100 {
                Button("Reset Tint") {
                    brightness = 100
                    contrast = 100
                    saturation = 100
                }
            }
        } header: {
            Text("Tint")
        }
    }

    @ViewBuilder
    private func slider(_ label: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            LabeledContent("Alt Text") {
                TextField("Describe the image", text: $alt)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Title") {
                TextField("Shown on hover", text: $title)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Caption") {
                TextField("Shown below", text: $caption)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Metadata")
        } footer: {
            Text("Alt text is read aloud by VoiceOver and shown if the picture can't be loaded.")
        }
    }
}

// MARK: - ImagePropertiesPreview

/// Draws the picture the way the editor will, so the panel is showing the thing it is describing.
private struct ImagePropertiesPreview: View {

    let source: String
    let attributes: ImageAttributes

    @EnvironmentObject private var contentService: DocContentService

    /// The picture behind a `neutrino-drive:` reference, once it has been fetched and decrypted.
    ///
    /// A reference names an end-to-end encrypted Drive file, so unlike the other two kinds of
    /// source there is no URL that resolves to a picture and nothing SwiftUI can load on its own.
    @State private var resolved: UIImage?

    private static let height: CGFloat = 160

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            HStack(spacing: 0) {
                if alignmentSpacerLeading { Spacer(minLength: 0) }
                picture(width: attributes.drawnWidth(naturalWidth: available,
                                                     availableWidth: available))
                if alignmentSpacerTrailing { Spacer(minLength: 0) }
            }
            .frame(width: available, height: Self.height)
        }
        .frame(height: Self.height)
    }

    private var alignmentSpacerLeading: Bool {
        attributes.alignment.placement == .center || attributes.alignment.placement == .right
    }

    private var alignmentSpacerTrailing: Bool {
        attributes.alignment.placement == .center || attributes.alignment.placement == .left
            || attributes.alignment.placement == .none
    }

    @ViewBuilder
    private func picture(width: CGFloat) -> some View {
        let shadow = attributes.shadow
        let border = attributes.strokedBorder

        loaded
            .frame(width: max(width, 1), height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(uiColor: border.color), lineWidth: border.width)
                }
            }
            .shadow(color: .black.opacity(shadow.opacity),
                    radius: shadow.blur / 2,
                    x: shadow.offset.width,
                    y: shadow.offset.height)
            .brightness(attributes.appliedFilter.map { $0.brightness - 1 } ?? 0)
            .contrast(attributes.appliedFilter?.contrast ?? 1)
            .saturation(attributes.appliedFilter?.saturation ?? 1)
    }

    @ViewBuilder
    private var loaded: some View {
        if let fileID = DriveImageReference.fileID(from: source) {
            Group {
                if let resolved {
                    Image(uiImage: resolved).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .task(id: fileID) {
                guard let data = try? await contentService.attachmentData(forFileID: fileID) else {
                    return
                }
                resolved = UIImage(data: data)
            }
        } else if source.hasPrefix("data:"), let decoded = EditorImageStore.decodeDataURI(source) {
            Image(uiImage: decoded).resizable().scaledToFill()
        } else if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Presets

extension ImageAttributes {

    /// The widths worth one tap, since typing `50%` into a text field on a phone is a chore.
    enum WidthPreset: String {
        case quarter = "25%"
        case half = "50%"
        case threeQuarters = "75%"
        case full = "100%"

        var label: String { rawValue }
    }

    static let borderPresets: [(label: String, css: String)] = [
        ("None", ""),
        ("Thin", "1px solid #999999"),
        ("Thick", "3px solid #333333"),
        ("Dashed", "2px dashed #999999"),
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
