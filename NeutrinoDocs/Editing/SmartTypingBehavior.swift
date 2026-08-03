import Foundation

// MARK: - SmartTypingBehavior

/// The as-you-type editor behaviours — Phase 2 — Editor Improvements: "Smart indentation",
/// "Auto bullets", "Auto numbering", "Auto closing brackets".
///
/// Modelled as pure functions from an `EditorTextState` plus the text about to be inserted, to an
/// optional replacement state. `nil` means "no special handling, let the text view do its normal
/// thing", which keeps the `UITextViewDelegate` hook trivial and every rule under test.
enum SmartTypingBehavior {

    // MARK: - Configuration

    struct Options: Equatable {
        var continueLists = true
        var closeBrackets = true
        /// Spaces per indent level, used when Tab indents a list item.
        var indentWidth = 2

        static let `default` = Options()
    }

    // MARK: - Newline

    /// Handles Return.
    ///
    /// Continues a list (`- `, `1. `, `- [ ] `) or a block quote onto the next line, carrying the
    /// indentation with it. Pressing Return on an *empty* item ends the list instead — which is how
    /// every editor lets you stop — by clearing the marker rather than adding another.
    static func newline(in state: EditorTextState,
                        options: Options = .default) -> EditorTextState? {
        guard options.continueLists else { return nil }

        let text = state.nsText
        let lineRange = text.lineRange(for: NSRange(location: state.selection.location, length: 0))
        let line = text.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")

        // Only continue when the caret is at the end of the line's content — pressing Return in
        // the middle of an item is a split, not a new item.
        let lineContentEnd = lineRange.location + (line as NSString).length
        guard state.selection.location >= lineContentEnd else { return nil }

        guard let marker = ListMarker(line: line) else { return nil }

        // An empty item: Return clears it and ends the list.
        if marker.contentIsEmpty {
            let cleared = text.replacingCharacters(
                in: NSRange(location: lineRange.location, length: (line as NSString).length),
                with: ""
            )
            return EditorTextState(text: cleared,
                                   selection: NSRange(location: lineRange.location, length: 0))
        }

        let continuation = "\n" + marker.nextMarker
        let result = text.replacingCharacters(in: state.selection, with: continuation)
        return EditorTextState(
            text: result,
            selection: NSRange(location: state.selection.location + (continuation as NSString).length,
                               length: 0)
        )
    }

    // MARK: - Bracket closing

    /// Pairs that auto-close. Backticks are included because a code span is far more often wanted
    /// closed than not; quotes are not, because apostrophes in prose would be mangled.
    static let bracketPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "`": "`",
    ]

    /// Handles a single inserted character.
    ///
    /// Opening a bracket inserts its partner and leaves the caret between them. With a selection,
    /// the selection is *wrapped* rather than replaced, which is the behaviour that makes
    /// "select a word, press `(`" useful. Typing a closing bracket that is already there just steps
    /// over it instead of doubling it.
    static func insert(_ character: Character,
                       in state: EditorTextState,
                       options: Options = .default) -> EditorTextState? {
        guard options.closeBrackets else { return nil }
        let text = state.nsText

        // Step over an auto-inserted closer.
        if bracketPairs.values.contains(character), state.isCaret,
           state.selection.location < text.length,
           text.substring(with: NSRange(location: state.selection.location, length: 1))
            == String(character) {
            return EditorTextState(
                text: state.text,
                selection: NSRange(location: state.selection.location + 1, length: 0)
            )
        }

        guard let closer = bracketPairs[character] else { return nil }

        // Wrap a selection.
        if !state.isCaret {
            let wrapped = String(character) + state.selectedText + String(closer)
            let result = text.replacingCharacters(in: state.selection, with: wrapped)
            return EditorTextState(
                text: result,
                selection: NSRange(location: state.selection.location + 1,
                                   length: state.selection.length)
            )
        }

        // A backtick immediately after another backtick is a fence being typed, not a code span —
        // closing it would fight the author writing ```.
        if character == "`", state.selection.location > 0,
           text.substring(with: NSRange(location: state.selection.location - 1, length: 1)) == "`" {
            return nil
        }

        // Don't auto-close directly before a word: `(` typed before "foo" should not make "()foo".
        if state.selection.location < text.length {
            let next = text.substring(with: NSRange(location: state.selection.location, length: 1))
            if let scalar = next.unicodeScalars.first,
               CharacterSet.alphanumerics.contains(scalar) {
                return nil
            }
        }

        let pair = String(character) + String(closer)
        let result = text.replacingCharacters(in: state.selection, with: pair)
        return EditorTextState(
            text: result,
            selection: NSRange(location: state.selection.location + 1, length: 0)
        )
    }

    // MARK: - Backspace

    /// Deleting between an auto-inserted pair removes both, so `()` with the caret inside clears in
    /// one press rather than leaving a stray `)`.
    static func deleteBackward(in state: EditorTextState,
                               options: Options = .default) -> EditorTextState? {
        guard options.closeBrackets, state.isCaret, state.selection.location > 0 else { return nil }

        let text = state.nsText
        guard state.selection.location < text.length else { return nil }

        let before = text.substring(with: NSRange(location: state.selection.location - 1, length: 1))
        let after = text.substring(with: NSRange(location: state.selection.location, length: 1))

        guard let opener = before.first, let closer = bracketPairs[opener],
              String(closer) == after else { return nil }

        let result = text.replacingCharacters(
            in: NSRange(location: state.selection.location - 1, length: 2), with: ""
        )
        return EditorTextState(text: result,
                               selection: NSRange(location: state.selection.location - 1, length: 0))
    }

    // MARK: - Indentation

    /// Tab / Shift-Tab — Phase 2 — Editor Improvements, "Smart indentation".
    ///
    /// Indents every line the selection touches. On a bare caret mid-line, Tab inserts spaces to
    /// the next tab stop instead, so it still works as a plain tab key in prose.
    static func indent(_ state: EditorTextState,
                       outdent: Bool = false,
                       options: Options = .default) -> EditorTextState {
        let text = state.nsText
        let unit = String(repeating: " ", count: options.indentWidth)

        // A caret in the middle of a line with nothing selected: plain tab insertion.
        if state.isCaret, !outdent {
            let lineRange = text.lineRange(for: state.selection)
            let prefix = text.substring(
                with: NSRange(location: lineRange.location,
                              length: state.selection.location - lineRange.location)
            )
            if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                let result = text.replacingCharacters(in: state.selection, with: unit)
                return EditorTextState(
                    text: result,
                    selection: NSRange(location: state.selection.location + unit.count, length: 0)
                )
            }
        }

        let range = MarkdownEditing.lineRange(for: state)
        let block = text.substring(with: range)
        let lines = block.components(separatedBy: "\n")

        let rewritten: [String] = lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if outdent {
                // Remove up to `indentWidth` spaces, or a single tab.
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                var removed = 0
                var result = Substring(line)
                while removed < options.indentWidth, result.first == " " {
                    result = result.dropFirst()
                    removed += 1
                }
                return String(result)
            }
            return unit + line
        }

        let replacement = rewritten.joined(separator: "\n")
        let result = text.replacingCharacters(in: range, with: replacement)
        return EditorTextState(
            text: result,
            selection: NSRange(location: range.location,
                               length: (replacement as NSString).length)
        )
    }
}

// MARK: - ListMarker

/// The marker at the start of a list item, and what the *next* item's marker should be.
///
/// Split out from `SmartTypingBehavior` so the "what continues what" rules — a bullet repeats, a
/// number increments, a checked box comes back unchecked — are one small thing to test.
struct ListMarker: Equatable {

    enum Kind: Equatable {
        case bullet(Character)
        case numbered(Int, delimiter: Character)
        case task(Character)
        case quote
    }

    let indent: String
    let kind: Kind
    /// True when the item has a marker but no text after it.
    let contentIsEmpty: Bool

    // MARK: - Parsing

    init?(line: String) {
        let indent = MarkdownEditing.leadingWhitespace(line)
        self.indent = indent
        let body = String(line.dropFirst(indent.count))

        if let length = MarkdownEditing.taskMarkerLength(line) {
            guard let bullet = body.first else { return nil }
            self.kind = .task(bullet)
            self.contentIsEmpty = String(line.dropFirst(length)).trimmingCharacters(
                in: .whitespaces
            ).isEmpty
            return
        }

        if let length = MarkdownEditing.numberedMarkerLength(line) {
            let digits = body.prefix { $0.isNumber }
            let delimiter = body.dropFirst(digits.count).first ?? "."
            self.kind = .numbered(Int(digits) ?? 1, delimiter: delimiter)
            self.contentIsEmpty = String(line.dropFirst(length)).trimmingCharacters(
                in: .whitespaces
            ).isEmpty
            return
        }

        if let length = MarkdownEditing.bulletMarkerLength(line) {
            guard let bullet = body.first else { return nil }
            self.kind = .bullet(bullet)
            self.contentIsEmpty = String(line.dropFirst(length)).trimmingCharacters(
                in: .whitespaces
            ).isEmpty
            return
        }

        if let length = MarkdownEditing.quoteMarkerLength(line) {
            self.kind = .quote
            self.contentIsEmpty = String(line.dropFirst(length)).trimmingCharacters(
                in: .whitespaces
            ).isEmpty
            return
        }

        return nil
    }

    // MARK: - Continuation

    /// The marker to open the next line with.
    var nextMarker: String {
        switch kind {
        case .bullet(let character):
            return "\(indent)\(character) "
        case .numbered(let value, let delimiter):
            // Auto numbering: the next item counts on from this one.
            return "\(indent)\(value + 1)\(delimiter) "
        case .task(let bullet):
            // A new task starts unchecked whatever the one above it was.
            return "\(indent)\(bullet) [ ] "
        case .quote:
            return "\(indent)> "
        }
    }
}
