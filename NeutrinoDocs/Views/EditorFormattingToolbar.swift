import SwiftUI

// MARK: - EditorFormattingToolbar

/// The formatting bar above the keyboard — Phase 2 — Formatting Toolbar.
///
/// Sits in a `.keyboard` safe-area inset rather than in the navigation bar, so it is where a thumb
/// already is while typing. Scrolls horizontally because the full command set does not fit across
/// an iPhone in portrait, and dropping commands to make it fit would mean the toolbar's contents
/// changed with the device.
struct EditorFormattingToolbar: View {

    let controller: MarkdownTextEditorController
    /// Shown on the trailing edge so indentation is reachable without a hardware keyboard.
    var showsIndentControls = true

    /// The order commands appear in: the inline marks first, then links, then block structures.
    private static let commands: [MarkdownEditingCommand] = [
        .bold, .italic, .strikethrough, .code,
        .link, .image,
        .bulletList, .numberedList, .checkbox,
        .quote, .codeBlock, .table,
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Self.commands) { command in
                        button(for: command)
                    }
                }
                .padding(.horizontal, 8)
            }

            if showsIndentControls {
                Divider().frame(height: 24)
                HStack(spacing: 2) {
                    iconButton("decrease.indent", label: "Outdent") {
                        controller.indent(outdent: true)
                    }
                    iconButton("increase.indent", label: "Indent") {
                        controller.indent()
                    }
                    iconButton("keyboard.chevron.compact.down", label: "Hide Keyboard") {
                        controller.resignFirstResponder()
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 44)
        .background(.bar)
    }

    // MARK: - Buttons

    private func button(for command: MarkdownEditingCommand) -> some View {
        iconButton(command.systemImage, label: command.title) {
            controller.apply(command)
        }
    }

    private func iconButton(_ systemImage: String,
                            label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - EditorKeyboardShortcuts

/// The hardware-keyboard shortcuts — Phase 2 — Editor Improvements, "Keyboard shortcuts".
///
/// Attached as hidden buttons rather than through `UIKeyCommand`: SwiftUI's `.keyboardShortcut`
/// already routes through the responder chain and shows up in the iPad shortcut overlay, and a
/// hidden button keeps each shortcut next to the action it performs.
struct EditorKeyboardShortcuts: ViewModifier {

    let controller: MarkdownTextEditorController
    var isEnabled: Bool
    let onToggleOutline: () -> Void
    let onTogglePreview: () -> Void

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
            ForEach(MarkdownEditingCommand.allCases) { command in
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
            Button("Toggle Preview") { onTogglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Indent") { controller.indent() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { controller.indent(outdent: true) }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

extension View {
    /// Attaches Phase 2's editor keyboard shortcuts.
    func editorKeyboardShortcuts(controller: MarkdownTextEditorController,
                                 isEnabled: Bool,
                                 onToggleOutline: @escaping () -> Void,
                                 onTogglePreview: @escaping () -> Void) -> some View {
        modifier(EditorKeyboardShortcuts(controller: controller,
                                         isEnabled: isEnabled,
                                         onToggleOutline: onToggleOutline,
                                         onTogglePreview: onTogglePreview))
    }
}
