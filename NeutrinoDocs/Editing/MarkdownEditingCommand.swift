import Foundation

// MARK: - EditorTextState

/// A snapshot of the editor: its text and the current selection.
///
/// Every formatting command is a pure `EditorTextState -> EditorTextState` function, which is what
/// makes the whole formatting toolbar testable without a `UITextView` in the loop. Offsets are
/// UTF-16, matching `NSRange` and `UITextView.selectedRange`.
struct EditorTextState: Equatable {
    var text: String
    var selection: NSRange

    init(text: String, selection: NSRange) {
        self.text = text
        // A selection past the end would trap on the first substring operation. Clamping here means
        // every command downstream can assume the range is valid.
        let length = (text as NSString).length
        let location = min(max(0, selection.location), length)
        self.selection = NSRange(location: location,
                                 length: min(max(0, selection.length), length - location))
    }

    var nsText: NSString { text as NSString }

    var selectedText: String { nsText.substring(with: selection) }

    /// Collapsed selection — a caret rather than a range.
    var isCaret: Bool { selection.length == 0 }
}

// MARK: - MarkdownEditingCommand

/// The formatting-toolbar actions — Phase 2 — Formatting Toolbar: "Bold", "Italic", "Link",
/// "Image", "Code", "Quote", "Table", "Checkbox".
///
/// Each command is a pure transform so its exact behaviour — what happens with no selection, what
/// happens when the markers are already there — is pinned down in tests rather than discovered by
/// tapping buttons.
enum MarkdownEditingCommand: String, CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case code
    case link
    case image
    case quote
    case codeBlock
    case table
    case checkbox
    case bulletList
    case numberedList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold:          return "Bold"
        case .italic:        return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code:          return "Code"
        case .link:          return "Link"
        case .image:         return "Image"
        case .quote:         return "Quote"
        case .codeBlock:     return "Code Block"
        case .table:         return "Table"
        case .checkbox:      return "Checkbox"
        case .bulletList:    return "Bulleted List"
        case .numberedList:  return "Numbered List"
        }
    }

    var systemImage: String {
        switch self {
        case .bold:          return "bold"
        case .italic:        return "italic"
        case .strikethrough: return "strikethrough"
        case .code:          return "chevron.left.forwardslash.chevron.right"
        case .link:          return "link"
        case .image:         return "photo"
        case .quote:         return "text.quote"
        case .codeBlock:     return "curlybraces"
        case .table:         return "tablecells"
        case .checkbox:      return "checklist"
        case .bulletList:    return "list.bullet"
        case .numberedList:  return "list.number"
        }
    }

    /// The ⌘-key for the commands that have one — Phase 2 — Editor Improvements, "Keyboard
    /// shortcuts". `nil` means toolbar-only.
    var keyboardShortcut: Character? {
        switch self {
        case .bold:   return "b"
        case .italic: return "i"
        case .code:   return "e"
        case .link:   return "k"
        default:      return nil
        }
    }

    // MARK: - Application

    func apply(to state: EditorTextState) -> EditorTextState {
        switch self {
        case .bold:          return MarkdownEditing.toggleWrap(state, marker: "**")
        case .italic:        return MarkdownEditing.toggleWrap(state, marker: "*")
        case .strikethrough: return MarkdownEditing.toggleWrap(state, marker: "~~")
        case .code:          return MarkdownEditing.toggleWrap(state, marker: "`")
        case .link:          return MarkdownEditing.insertLink(state)
        case .image:         return MarkdownEditing.insertImage(state)
        case .quote:         return MarkdownEditing.togglePrefix(state, prefix: "> ")
        case .codeBlock:     return MarkdownEditing.insertCodeBlock(state)
        case .table:         return MarkdownEditing.insertTable(state)
        case .checkbox:      return MarkdownEditing.toggleTaskList(state)
        case .bulletList:    return MarkdownEditing.togglePrefix(state, prefix: "- ")
        case .numberedList:  return MarkdownEditing.toggleNumberedList(state)
        }
    }
}

// MARK: - MarkdownEditing

/// The transforms behind `MarkdownEditingCommand`.
enum MarkdownEditing {

    // MARK: - Inline wrapping

    /// Wraps the selection in `marker`, or unwraps it when the markers are already there.
    ///
    /// With no selection the markers are inserted and the caret placed between them, so typing
    /// carries straight on inside the emphasis — the behaviour every other Markdown editor has.
    static func toggleWrap(_ state: EditorTextState, marker: String) -> EditorTextState {
        let text = state.nsText
        let markerLength = (marker as NSString).length

        // Already wrapped *inside* the selection: `**bold**` selected whole.
        let selected = state.selectedText
        if selected.hasPrefix(marker), selected.hasSuffix(marker),
           (selected as NSString).length >= markerLength * 2 {
            let inner = (selected as NSString).substring(
                with: NSRange(location: markerLength,
                              length: (selected as NSString).length - markerLength * 2)
            )
            let result = text.replacingCharacters(in: state.selection, with: inner)
            return EditorTextState(
                text: result,
                selection: NSRange(location: state.selection.location,
                                   length: (inner as NSString).length)
            )
        }

        // Already wrapped *outside* the selection: `**` before and after `bold`.
        let before = NSRange(location: state.selection.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(state.selection), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            let outer = NSRange(location: before.location,
                                length: markerLength * 2 + state.selection.length)
            let result = text.replacingCharacters(in: outer, with: selected)
            return EditorTextState(
                text: result,
                selection: NSRange(location: before.location, length: state.selection.length)
            )
        }

        let wrapped = marker + selected + marker
        let result = text.replacingCharacters(in: state.selection, with: wrapped)
        let caret = state.selection.location + markerLength
        return EditorTextState(
            text: result,
            // A caret lands between the markers; a selection stays on the text it wrapped.
            selection: NSRange(location: caret, length: state.selection.length)
        )
    }

    // MARK: - Links and images

    static func insertLink(_ state: EditorTextState) -> EditorTextState {
        insertReference(state, prefix: "[", placeholder: "title")
    }

    static func insertImage(_ state: EditorTextState) -> EditorTextState {
        insertReference(state, prefix: "![", placeholder: "alt text")
    }

    /// `[selected](url)`, with the caret left in the URL — the part that always has to be typed.
    private static func insertReference(_ state: EditorTextState,
                                        prefix: String,
                                        placeholder: String) -> EditorTextState {
        let label = state.isCaret ? placeholder : state.selectedText
        let inserted = "\(prefix)\(label)](url)"
        let result = state.nsText.replacingCharacters(in: state.selection, with: inserted)

        // Select "url" so typing replaces it.
        let urlOffset = state.selection.location + (prefix as NSString).length
            + (label as NSString).length + 2
        return EditorTextState(text: result,
                               selection: NSRange(location: urlOffset, length: 3))
    }

    // MARK: - Line prefixes

    /// Adds `prefix` to every line the selection touches, or removes it when every one of them
    /// already has it — the standard toggle for quotes and bullets.
    static func togglePrefix(_ state: EditorTextState, prefix: String) -> EditorTextState {
        let range = lineRange(for: state)
        let block = state.nsText.substring(with: range)
        let lines = block.components(separatedBy: "\n")

        let allPrefixed = lines.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.hasPrefix(prefix)
                || hasEquivalentMarker(line, prefix: prefix)
        }

        let rewritten: [String] = lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allPrefixed { return stripMarker(line, prefix: prefix) }
            // Replace a different list marker rather than stacking one on top of another.
            let bare = stripAnyListMarker(line)
            return prefix + bare
        }

        return replacing(range, in: state, with: rewritten.joined(separator: "\n"))
    }

    /// Numbers each selected line `1.`, `2.`, … or strips the numbering when it is already there.
    static func toggleNumberedList(_ state: EditorTextState) -> EditorTextState {
        let range = lineRange(for: state)
        let block = state.nsText.substring(with: range)
        let lines = block.components(separatedBy: "\n")

        let allNumbered = lines.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty || numberedMarkerLength(line) != nil
        }

        var counter = 0
        let rewritten: [String] = lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allNumbered { return stripAnyListMarker(line) }
            counter += 1
            return "\(counter). " + stripAnyListMarker(line)
        }

        return replacing(range, in: state, with: rewritten.joined(separator: "\n"))
    }

    /// Turns the selected lines into `- [ ]` task items, or clears the boxes when they all have
    /// one — Phase 2 — Formatting Toolbar, "Checkbox".
    static func toggleTaskList(_ state: EditorTextState) -> EditorTextState {
        let range = lineRange(for: state)
        let block = state.nsText.substring(with: range)
        let lines = block.components(separatedBy: "\n")

        let allTasks = lines.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty || taskMarkerLength(line) != nil
        }

        let rewritten: [String] = lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allTasks {
                // Drop the checkbox but keep the bullet, which is what the item was before.
                guard let length = taskMarkerLength(line) else { return line }
                let indent = leadingWhitespace(line)
                return indent + "- " + String(line.dropFirst(length))
            }
            return "- [ ] " + stripAnyListMarker(line)
        }

        return replacing(range, in: state, with: rewritten.joined(separator: "\n"))
    }

    // MARK: - Blocks

    static func insertCodeBlock(_ state: EditorTextState) -> EditorTextState {
        let body = state.isCaret ? "" : state.selectedText
        let block = "```\n\(body)\n```"
        let prepared = blockInsertion(block, in: state)
        let result = state.nsText.replacingCharacters(in: prepared.range, with: prepared.text)
        // Caret goes on the opening fence, ready for a language.
        let caret = prepared.range.location + (prepared.leadingNewlines as NSString).length + 3
        return EditorTextState(text: result, selection: NSRange(location: caret, length: 0))
    }

    /// A 2×3 starter table, the smallest one that shows the header/alignment rows.
    static func insertTable(_ state: EditorTextState) -> EditorTextState {
        let table = """
        | Column 1 | Column 2 |
        | --- | --- |
        |  |  |
        """
        let prepared = blockInsertion(table, in: state)
        let result = state.nsText.replacingCharacters(in: prepared.range, with: prepared.text)
        // Select the first header cell so it can be typed over immediately.
        let headerOffset = prepared.range.location
            + (prepared.leadingNewlines as NSString).length + 2
        return EditorTextState(text: result,
                               selection: NSRange(location: headerOffset, length: 8))
    }

    /// A block-level insertion needs to start on its own line and be followed by a blank one.
    /// Returns the range to replace and the text to put there, with the padding it added.
    private static func blockInsertion(
        _ block: String, in state: EditorTextState
    ) -> (range: NSRange, text: String, leadingNewlines: String) {
        let text = state.nsText
        let start = state.selection.location

        var leading = ""
        if start > 0 {
            let previous = text.substring(with: NSRange(location: start - 1, length: 1))
            if previous != "\n" {
                leading = "\n\n"
            } else if start > 1 {
                let beforeThat = text.substring(with: NSRange(location: start - 2, length: 1))
                if beforeThat != "\n" { leading = "\n" }
            }
        }

        var trailing = ""
        let end = NSMaxRange(state.selection)
        if end < text.length {
            let next = text.substring(with: NSRange(location: end, length: 1))
            trailing = next == "\n" ? "\n" : "\n\n"
        } else {
            trailing = "\n"
        }

        return (state.selection, leading + block + trailing, leading)
    }

    // MARK: - Line helpers

    /// Expands the selection to whole lines, which is what every prefix command operates on.
    static func lineRange(for state: EditorTextState) -> NSRange {
        state.nsText.lineRange(for: state.selection).trimmingTrailingNewline(in: state.nsText)
    }

    private static func replacing(_ range: NSRange,
                                  in state: EditorTextState,
                                  with replacement: String) -> EditorTextState {
        let result = state.nsText.replacingCharacters(in: range, with: replacement)
        return EditorTextState(
            text: result,
            selection: NSRange(location: range.location, length: (replacement as NSString).length)
        )
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Length of a `- [ ] ` / `* [x] ` task marker including its trailing space, or `nil`.
    static func taskMarkerLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indent = line.count - trimmed.count
        guard let first = trimmed.first, "-*+".contains(first) else { return nil }
        let rest = trimmed.dropFirst().drop { $0 == " " }
        guard rest.hasPrefix("[") else { return nil }
        let box = rest.prefix(3)
        guard box.count == 3, box.hasSuffix("]"),
              let state = box.dropFirst().first,
              state == " " || state == "x" || state == "X" else { return nil }
        let afterBox = rest.dropFirst(3)
        let spaces = afterBox.prefix { $0 == " " }.count
        return indent + (trimmed.count - rest.count) + 3 + spaces
    }

    /// Length of a `1. ` / `2) ` marker including its trailing space, or `nil`.
    static func numberedMarkerLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indent = line.count - trimmed.count
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let spaces = afterDigits.dropFirst().prefix { $0 == " " }.count
        guard spaces > 0 else { return nil }
        return indent + digits.count + 1 + spaces
    }

    /// Length of a `- ` / `* ` / `+ ` bullet marker including its trailing space, or `nil`.
    static func bulletMarkerLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indent = line.count - trimmed.count
        guard let first = trimmed.first, "-*+".contains(first) else { return nil }
        let spaces = trimmed.dropFirst().prefix { $0 == " " }.count
        guard spaces > 0 else { return nil }
        return indent + 1 + spaces
    }

    /// Length of a `> ` quote marker, or `nil`.
    static func quoteMarkerLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indent = line.count - trimmed.count
        guard trimmed.hasPrefix(">") else { return nil }
        let spaces = trimmed.dropFirst().prefix { $0 == " " }.count
        return indent + 1 + spaces
    }

    /// Whether `line` already carries a marker of the same family as `prefix` — `* item` counts as
    /// bulleted when the toolbar's bullet is `- `.
    private static func hasEquivalentMarker(_ line: String, prefix: String) -> Bool {
        switch prefix {
        case "- ", "* ", "+ ": return bulletMarkerLength(line) != nil && taskMarkerLength(line) == nil
        case "> ":             return quoteMarkerLength(line) != nil
        default:               return false
        }
    }

    /// Removes a marker of `prefix`'s family, preserving indentation.
    private static func stripMarker(_ line: String, prefix: String) -> String {
        let indent = leadingWhitespace(line)
        switch prefix {
        case "- ", "* ", "+ ":
            guard let length = bulletMarkerLength(line) else { return line }
            return indent + String(line.dropFirst(length))
        case "> ":
            guard let length = quoteMarkerLength(line) else { return line }
            return indent + String(line.dropFirst(length))
        default:
            guard line.hasPrefix(prefix) else { return line }
            return String(line.dropFirst(prefix.count))
        }
    }

    /// Strips whichever list or task marker a line starts with, so one list type can replace
    /// another without the markers accumulating.
    static func stripAnyListMarker(_ line: String) -> String {
        let indent = leadingWhitespace(line)
        if let length = taskMarkerLength(line) { return indent + String(line.dropFirst(length)) }
        if let length = numberedMarkerLength(line) { return indent + String(line.dropFirst(length)) }
        if let length = bulletMarkerLength(line) { return indent + String(line.dropFirst(length)) }
        return line
    }
}

// MARK: - NSRange helper

private extension NSRange {
    /// `lineRange(for:)` includes the terminating newline; prefix edits must not, or the command
    /// would swallow the following line's first character.
    func trimmingTrailingNewline(in text: NSString) -> NSRange {
        var result = self
        while result.length > 0,
              text.substring(with: NSRange(location: NSMaxRange(result) - 1, length: 1)) == "\n" {
            result.length -= 1
        }
        return result
    }
}
