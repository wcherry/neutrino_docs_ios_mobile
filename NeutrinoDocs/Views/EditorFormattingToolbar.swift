import SwiftUI

// MARK: - EditorBarActions

/// The document-level actions the style bar offers — the ones that are about the document rather
/// than about the text in it.
///
/// They arrive as closures because they act on state `DocEditorView` owns: which sheet is up, and
/// whether the document is pinned for offline use. The bar decides where they appear; the editor
/// decides what they do.
struct EditorBarActions {
    /// Opens the insert-image sheet. The image button is not a formatting command: a picture has to
    /// be found before it can be written down, and typing `![](url)` for the user to fill in is not
    /// finding it.
    var insertImage: () -> Void = {}
    var showOutline: () -> Void = {}
    var saveVersion: () -> Void = {}
    var showVersionHistory: () -> Void = {}
    var toggleOffline: () -> Void = {}

    var isAvailableOffline = false
    /// Version history and named saves need both the server and the session key.
    var canUseServerFeatures = false

    var offersOutline = true
    var offersVersionHistory = true
    var offersOfflineToggle = true
}

// MARK: - EditorFormattingToolbar

/// The style bar: on a phone, every control the editor has.
///
/// ## Where it lives
///
/// While the document is being edited it is the text view's `inputAccessoryView`, so it rides with
/// the keyboard. With the keyboard down `DocEditorView` docks it at the bottom of the screen
/// instead. Both are needed because the bar is no longer only about formatting: Outline, Version
/// History and the offline toggle live here on a phone, and an action you can only reach by first
/// tapping into the text is not reachable.
///
/// ## How it copes with crowding
///
/// Everything scrolls. Nothing is pinned to either edge, so a new control costs one place in the
/// row and takes width from nothing that is already there — which matters because pinning the ends
/// is what makes a bar crowded: it leaves the additions fighting over a shrinking middle. The order
/// is the priority order, since what is on screen without scrolling is whatever comes first.
///
/// On a wider device the same row simply runs out of things to scroll past, which is the seam for
/// laying these out as always-visible controls on an iPad later.
struct EditorFormattingToolbar: View {

    /// Observed for `isEditing`: the dismiss-keyboard button has nothing to dismiss in the docked
    /// copy, and the formatting controls have nothing to act on.
    @ObservedObject var controller: DocumentEditorController
    /// A document this account may not edit still gets a bar — the document-level actions apply to
    /// it — but nothing that would change the text.
    var isEditable = true
    var actions = EditorBarActions()

    /// Height of the docked bar. The input accessory view is sized from this, so it is not free to
    /// disagree with the layout below.
    static let height: CGFloat = 44

    /// What the caret is sitting in — the paragraph style, the alignment, and which toggles are
    /// already on. Refreshed whenever the selection moves or an edit changes the formatting under
    /// it, and held here rather than read inline so the bar does not reach into the text view on
    /// every redraw.
    @State private var status = EditorSelectionStatus()

    /// Where a link's address is typed. A link is the one inline mark that needs something the
    /// document cannot supply, so it asks rather than toggling.
    @State private var isAskingForLink = false
    @State private var linkURL = ""

    /// The order commands appear in: the inline marks first, then links, then block structures,
    /// then the indent pair that used to be pinned to the trailing edge.
    private static let commands: [DocumentEditingCommand] = [
        .bold, .italic, .strikethrough, .code,
        .link, .image,
        .bulletList, .numberedList, .checkbox,
        .quote, .codeBlock, .table,
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if isEditable {
                    styleMenu
                    alignmentMenu
                    divider

                    ForEach(Self.commands) { command in
                        switch command {
                        case .image:
                            iconButton(command.systemImage, label: command.title) {
                                actions.insertImage()
                            }
                        case .link:
                            iconButton(command.systemImage,
                                       label: command.title,
                                       isActive: status.activeCommands.contains(command)) {
                                linkURL = ""
                                isAskingForLink = true
                            }
                            .disabled(!status.hasSelection)
                        default:
                            button(for: command)
                        }
                    }

                    iconButton("decrease.indent", label: "Outdent") {
                        controller.indent(outdent: true)
                    }
                    iconButton("increase.indent", label: "Indent") {
                        controller.indent()
                    }

                    divider
                }

                documentMenu

                if isEditable, controller.isEditing {
                    iconButton("keyboard.chevron.compact.down", label: "Hide Keyboard") {
                        controller.resignFirstResponder()
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .documentEditorSelectionChanged)) { _ in
            refreshStatus()
        }
        // The bar can come on screen with the caret already somewhere — a document opened on a
        // heading, or the docked copy appearing as the keyboard goes down — and no notification is
        // owed for a selection that never moved.
        .onAppear { refreshStatus() }
        // A link needs an address, and the selection is what it goes on — so the prompt is raised
        // from the bar rather than from a sheet the editor would have to give up focus for.
        .alert("Add Link", isPresented: $isAskingForLink) {
            TextField("https://example.com", text: $linkURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Add") { controller.setLink(href: linkURL) }
            Button("Remove Link", role: .destructive) { controller.setLink(href: "") }
        } message: {
            Text("The address the selected text should link to.")
        }
    }

    private var divider: some View {
        Divider().frame(height: 24).padding(.horizontal, 4)
    }

    // MARK: - Document actions

    /// Everything that is about the document rather than the text, in one pinned menu.
    ///
    /// A menu rather than buttons because these are the rare ones — you save a version now and
    /// then, and you undo constantly — and giving them each a slot would push the formatting they
    /// outrank off the screen.
    private var documentMenu: some View {
        Menu {
            if isEditable {
                Button {
                    controller.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!controller.canUndo)

                Button {
                    controller.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!controller.canRedo)

                Divider()
            }

            if actions.offersOutline {
                Button {
                    actions.showOutline()
                } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
            }

            Button {
                controller.presentFind()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }

            if isEditable {
                Button {
                    controller.presentFindAndReplace()
                } label: {
                    Label("Find and Replace", systemImage: "text.magnifyingglass")
                }
            }

            Divider()

            Button {
                controller.foldAll()
            } label: {
                Label("Fold All", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(controller.foldableRegions.isEmpty)

            Button {
                controller.unfoldAll()
            } label: {
                Label("Unfold All", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(controller.foldedStartLines.isEmpty)

            if actions.offersVersionHistory {
                Divider()

                Button {
                    actions.saveVersion()
                } label: {
                    Label("Save Version…", systemImage: "square.and.arrow.down")
                }
                .disabled(!actions.canUseServerFeatures)

                Button {
                    actions.showVersionHistory()
                } label: {
                    Label("Version History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!actions.canUseServerFeatures)
            }

            if actions.offersOfflineToggle {
                Divider()

                Button {
                    actions.toggleOffline()
                } label: {
                    Label(actions.isAvailableOffline ? "Remove Offline Copy"
                                                     : "Make Available Offline",
                          systemImage: actions.isAvailableOffline ? "arrow.down.circle.fill"
                                                                  : "arrow.down.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Document actions")
    }

    // MARK: - Paragraph style

    /// A menu rather than four buttons: the styles are mutually exclusive, and a menu can say which
    /// one is in force where a row of buttons could only offer them.
    private var styleMenu: some View {
        Menu {
            Picker("Paragraph Style", selection: styleSelection) {
                ForEach(DocumentEditingCommand.paragraphStyles) { style in
                    Label(style.title, systemImage: style.systemImage).tag(style)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(status.paragraphStyle.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Paragraph style")
    }

    // MARK: - Alignment

    /// One button with the four alignments behind it, showing the current one as its icon.
    ///
    /// A menu rather than four buttons in a row for the same reason the paragraph style is one: the
    /// options are mutually exclusive, so a single control that *reports* the answer is worth more
    /// than four that only offer it — and on an iPhone four more icons is most of the bar.
    private var alignmentMenu: some View {
        Menu {
            Picker("Alignment", selection: alignmentSelection) {
                ForEach(DocumentAlignment.allCases) { alignment in
                    Label(alignment.title, systemImage: alignment.systemImage).tag(alignment)
                }
            }
        } label: {
            Image(systemName: status.alignment.systemImage)
                .font(.system(size: 16))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Alignment")
    }

    private var alignmentSelection: Binding<DocumentAlignment> {
        Binding(
            get: { status.alignment },
            set: { newValue in
                controller.setAlignment(newValue)
                refreshStatus()
            }
        )
    }

    /// Reads as the caret's current style and writes as a command, so choosing an item applies it
    /// through the same path as every other button.
    private var styleSelection: Binding<DocumentEditingCommand> {
        Binding(
            get: { status.paragraphStyle },
            set: { style in
                controller.apply(style)
                refreshStatus()
            }
        )
    }

    // MARK: - State

    /// Re-reads what the caret is sitting in.
    ///
    /// Assigned only on a real change: this runs on every caret move and every edit, and SwiftUI
    /// would otherwise rebuild the bar for a keystroke that changed nothing about it.
    private func refreshStatus() {
        let latest = controller.selectionStatus()
        if latest != status { status = latest }
    }

    // MARK: - Buttons

    private func button(for command: DocumentEditingCommand) -> some View {
        iconButton(command.systemImage,
                   label: command.title,
                   isActive: status.activeCommands.contains(command)) {
            controller.apply(command)
        }
    }

    /// One control in the bar.
    ///
    /// An active toggle is drawn as a filled, tinted chip — the same way the system draws a selected
    /// control — rather than only recoloured: colour alone is not something every reader can see,
    /// and the filled shape is what reads as "on" at this size. The accessibility trait carries the
    /// same fact to VoiceOver, which cannot see either.
    private func iconButton(_ systemImage: String,
                            label: String,
                            isActive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 38, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.18 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - EditorKeyboardShortcuts

/// The hardware-keyboard shortcuts — Phase 2 — Editor Improvements, "Keyboard shortcuts".
///
/// Attached as hidden buttons rather than through `UIKeyCommand`: SwiftUI's `.keyboardShortcut`
/// already routes through the responder chain and shows up in the iPad shortcut overlay, and a
/// hidden button keeps each shortcut next to the action it performs.
struct EditorKeyboardShortcuts: ViewModifier {

    let controller: DocumentEditorController
    var isEnabled: Bool
    let onToggleOutline: () -> Void

    func body(content: Content) -> some View {
        content.background {
            if isEnabled {
                shortcutButtons
                    // Zero-opacity rather than `.hidden()`: a hidden view is removed from the
                    // responder chain, and its shortcut stops working.
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private var shortcutButtons: some View {
        VStack(spacing: 0) {
            ForEach(DocumentEditingCommand.allCases) { command in
                if let key = command.keyboardShortcut {
                    Button(command.title) { controller.apply(command) }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                }
            }

            Button("Find") { controller.presentFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find and Replace") { controller.presentFindAndReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Undo") { controller.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { controller.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Toggle Outline") { onToggleOutline() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Indent") { controller.indent() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { controller.indent(outdent: true) }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

extension View {
    /// Attaches Phase 2's editor keyboard shortcuts.
    func editorKeyboardShortcuts(controller: DocumentEditorController,
                                 isEnabled: Bool,
                                 onToggleOutline: @escaping () -> Void) -> some View {
        modifier(EditorKeyboardShortcuts(controller: controller,
                                         isEnabled: isEnabled,
                                         onToggleOutline: onToggleOutline))
    }
}
