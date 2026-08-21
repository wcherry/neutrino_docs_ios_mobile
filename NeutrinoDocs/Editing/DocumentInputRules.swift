import Foundation
import UIKit

// MARK: - DocumentInputRules

/// The as-you-type editor behaviours — Phase 2 — Editor Improvements: "Smart indentation",
/// "Auto bullets", "Auto numbering", "Auto closing brackets" — plus Phase 1's typing shortcuts.
///
/// ## The shortcuts are typing, not a format
///
/// Typing `# ` still makes a heading, and `- ` still starts a bullet. What has changed is what
/// happens next: the characters are *consumed* and the line's block becomes a heading or a list
/// item. There is no `#` left in the document to conceal, because there is no `#` — the document
/// is a tree, and the keystrokes were a way of reaching for a node.
///
/// Modelled as pure functions from an ``EditorDocumentState`` plus the text about to be inserted,
/// to an optional replacement state. `nil` means "no special handling, let the text view do its
/// normal thing", which keeps the `UITextViewDelegate` hook trivial and every rule under test.
enum DocumentInputRules {

    // MARK: - Configuration

    struct Options: Equatable {
        var continueLists = true
        var closeBrackets = true
        /// Whether `# `, `- `, `> ` and friends convert the line as they are typed.
        var typingShortcuts = true

        static let `default` = Options()
    }

    // MARK: - Newline

    /// Handles Return.
    ///
    /// A plain paragraph needs no help: the new line inherits the block attributes of the one it
    /// was split from, which is already the right answer. The cases that do need help are the ones
    /// where inheriting is *wrong* — a new list item has to be a new item rather than a second
    /// paragraph inside the old one, a heading should not beget another heading, and Return inside
    /// a code block is a break within the block rather than a new block.
    static func newline(in state: EditorDocumentState,
                        style: DocumentStyle,
                        options: Options = .default) -> EditorDocumentState? {
        let block = state.caretBlock
        let line = state.caretLine

        // Inside a code block, Return adds a line to the block rather than leaving it.
        if DocumentNodeType.isCodeBlock(block.leafType) {
            return insert(DocumentProjection.lineBreak, in: state, style: style)
        }

        guard options.continueLists else { return nil }

        // An empty list item: Return ends the list rather than adding another empty item, which is
        // how every editor lets you stop.
        if block.innermostList != nil, line.length == 0 {
            return DocumentEditing.indent(state, outdent: true, style: style)
        }

        // A new list item, with an id of its own so it is a sibling rather than a second paragraph
        // inside the item above it.
        if let list = block.innermostList {
            let itemType = block.listItem?.type ?? DocumentNodeType.listItem
            let fresh = block
                .unwrapping(depth: 2) { $0.isSameInstance(as: list) }
                .wrapping(in: [list,
                               DocumentBlock.Level(type: itemType, id: state.nextLevelID)])
            return insertLine(in: state, block: fresh, style: style)
        }

        // A heading is a title, and what follows a title is prose.
        if DocumentNodeType.isHeading(block.leafType) {
            let alignment = block.attrs?["textAlign"]
            let paragraph = block.replacingLeaf(
                type: DocumentNodeType.paragraph,
                attrs: alignment.map { ["textAlign": $0] }
            )
            return insertLine(in: state, block: paragraph, style: style)
        }

        return nil
    }

    // MARK: - Typing shortcuts

    /// The line-opening shortcuts, longest first so `## ` is not read as `# `.
    ///
    /// Each returns the block a plain paragraph becomes when the marker is typed at the start of
    /// it. The marker itself is removed — it was a gesture, not content.
    private static func shortcut(for marker: String,
                                 on block: DocumentBlock,
                                 nextID: Int) -> DocumentBlock? {
        // Only from a plain paragraph: `# ` typed at the start of an existing heading is somebody
        // writing a hash, and inside a code block it is code.
        guard block.leafType == DocumentNodeType.paragraph else { return nil }

        let alignment = block.attrs?["textAlign"]
        func heading(_ level: Int) -> DocumentBlock {
            var attrs: [String: JSONValue] = ["level": .int(level)]
            if let alignment { attrs["textAlign"] = alignment }
            return block.replacingLeaf(type: DocumentNodeType.heading, attrs: attrs)
        }
        func list(_ type: String, item: String) -> DocumentBlock {
            block.wrapping(in: [DocumentBlock.Level(type: type, id: nextID),
                                DocumentBlock.Level(type: item, id: nextID + 1)])
        }

        switch marker {
        case "#":      return heading(1)
        case "##":     return heading(2)
        case "###":    return heading(3)
        case "####":   return heading(4)
        case "#####":  return heading(5)
        case "######": return heading(6)
        case "-", "*", "+":
            return list(DocumentNodeType.bulletList, item: DocumentNodeType.listItem)
        case ">":
            return block.wrapping(in: [DocumentBlock.Level(type: DocumentNodeType.blockquote,
                                                           id: nextID)])
        case "[]", "[ ]", "[x]":
            return list("taskList", item: "taskItem")
        default:
            // `1. `, `2) ` — an ordered list starting at the number that was typed.
            guard let delimiter = marker.last, delimiter == "." || delimiter == ")" else {
                return nil
            }
            let digits = marker.dropLast()
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let start = Int(digits) else { return nil }
            var level = DocumentBlock.Level(type: DocumentNodeType.orderedList, id: nextID)
            if start != 1 { level.attrs = ["start": .int(start)] }
            return block.wrapping(in: [level,
                                       DocumentBlock.Level(type: DocumentNodeType.listItem,
                                                           id: nextID + 1)])
        }
    }

    /// Handles a single inserted character.
    ///
    /// Runs the typing shortcuts first — a space at the end of `## ` is the gesture completing —
    /// and falls back to bracket closing.
    static func insert(_ character: Character,
                       in state: EditorDocumentState,
                       style: DocumentStyle,
                       options: Options = .default) -> EditorDocumentState? {
        if options.typingShortcuts, character == " ", state.isCaret,
           let converted = applyShortcut(in: state, style: style) {
            return converted
        }

        // Three backticks open a code block, which has no trailing space to wait for.
        if options.typingShortcuts, character == "`", state.isCaret,
           let fence = applyCodeFence(in: state, style: style) {
            return fence
        }

        return closeBracket(character, in: state, style: style, options: options)
    }

    /// Converts the caret's line when the text before the caret is a line-opening marker.
    private static func applyShortcut(in state: EditorDocumentState,
                                      style: DocumentStyle) -> EditorDocumentState? {
        let line = state.caretLine
        let typed = NSRange(location: line.location, length: state.selection.location - line.location)
        guard typed.length > 0, typed.length <= 6 else { return nil }

        let marker = state.nsString.substring(with: typed)
        let block = state.caretBlock
        guard let converted = shortcut(for: marker, on: block, nextID: state.nextLevelID) else {
            return nil
        }

        // The marker goes; the line becomes what it was reaching for.
        let mutable = NSMutableAttributedString(attributedString: state.text)
        mutable.deleteCharacters(in: typed)

        var range = NSRange(location: line.location, length: max(0, line.length - typed.length))
        if NSMaxRange(range) < mutable.length,
           (mutable.string as NSString).substring(
               with: NSRange(location: NSMaxRange(range), length: 1)
           ) == DocumentProjection.blockSeparator {
            range.length += 1
        }
        if range.length > 0 {
            mutable.addAttribute(.documentBlock, value: converted, range: range)
        } else if mutable.length > 0 {
            // A marker on a line of its own at the very end of the document leaves nothing to carry
            // the block, so a placeholder separator is not the answer — re-tag what is there.
            let anchor = NSRange(location: max(0, range.location - 1), length: min(1, mutable.length))
            mutable.addAttribute(.documentBlock, value: converted, range: anchor)
        }

        return DocumentEditing.reproject(
            mutable,
            selection: NSRange(location: line.location, length: 0),
            style: style
        )
    }

    /// ``` at the start of a line opens a code block.
    private static func applyCodeFence(in state: EditorDocumentState,
                                       style: DocumentStyle) -> EditorDocumentState? {
        let line = state.caretLine
        let typed = NSRange(location: line.location, length: state.selection.location - line.location)
        guard typed.length == 2,
              state.nsString.substring(with: typed) == "``" else { return nil }

        let block = state.caretBlock
        guard block.leafType == DocumentNodeType.paragraph else { return nil }

        let mutable = NSMutableAttributedString(attributedString: state.text)
        mutable.deleteCharacters(in: typed)

        var range = NSRange(location: line.location, length: max(0, line.length - typed.length))
        if NSMaxRange(range) < mutable.length,
           (mutable.string as NSString).substring(
               with: NSRange(location: NSMaxRange(range), length: 1)
           ) == DocumentProjection.blockSeparator {
            range.length += 1
        }
        guard range.length > 0 else { return nil }

        mutable.addAttribute(.documentBlock,
                             value: block.replacingLeaf(type: DocumentNodeType.codeBlock, attrs: nil),
                             range: range)

        return DocumentEditing.reproject(
            mutable,
            selection: NSRange(location: line.location, length: 0),
            style: style
        )
    }

    // MARK: - Bracket closing

    /// Pairs that auto-close. Backticks are included because a code span is far more often wanted
    /// closed than not; quotes are not, because apostrophes in prose would be mangled.
    static let bracketPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "`": "`",
    ]

    /// Opening a bracket inserts its partner and leaves the caret between them. With a selection,
    /// the selection is *wrapped* rather than replaced, which is the behaviour that makes
    /// "select a word, press `(`" useful. Typing a closing bracket that is already there just steps
    /// over it instead of doubling it.
    private static func closeBracket(_ character: Character,
                                     in state: EditorDocumentState,
                                     style: DocumentStyle,
                                     options: Options) -> EditorDocumentState? {
        guard options.closeBrackets else { return nil }
        let text = state.nsString

        // Step over an auto-inserted closer.
        if bracketPairs.values.contains(character), state.isCaret,
           state.selection.location < text.length,
           text.substring(with: NSRange(location: state.selection.location, length: 1))
            == String(character) {
            return EditorDocumentState(
                text: state.text,
                selection: NSRange(location: state.selection.location + 1, length: 0)
            )
        }

        guard let closer = bracketPairs[character] else { return nil }

        // Wrap a selection.
        if !state.isCaret {
            let mutable = NSMutableAttributedString(attributedString: state.text)
            let attributes = mutable.attributes(at: state.selection.location, effectiveRange: nil)
            mutable.insert(NSAttributedString(string: String(closer), attributes: attributes),
                           at: NSMaxRange(state.selection))
            mutable.insert(NSAttributedString(string: String(character), attributes: attributes),
                           at: state.selection.location)
            return EditorDocumentState(
                text: mutable,
                selection: NSRange(location: state.selection.location + 1,
                                   length: state.selection.length)
            )
        }

        // A backtick immediately after another backtick is a fence being typed, not a code span —
        // closing it would fight the author reaching for a code block.
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

        guard let inserted = insert(String(character) + String(closer), in: state, style: style) else {
            return nil
        }
        return EditorDocumentState(
            text: inserted.text,
            selection: NSRange(location: state.selection.location + 1, length: 0)
        )
    }

    // MARK: - Backspace

    /// Backspace at the start of a line, where the character before the caret belongs to another
    /// block entirely.
    ///
    /// Pressing it in a list lifts the item out rather than joining it to the line above — the
    /// same gesture Shift-Tab makes, reached the way people reach for it. Everywhere else UIKit's
    /// own deletion is right.
    static func deleteBackward(in state: EditorDocumentState,
                               style: DocumentStyle,
                               options: Options = .default) -> EditorDocumentState? {
        guard state.isCaret else { return nil }

        let block = state.caretBlock
        let line = state.caretLine

        if state.selection.location == line.location {
            if block.innermostList != nil {
                return DocumentEditing.indent(state, outdent: true, style: style)
            }
            if block.isInside({ $0.type == DocumentNodeType.blockquote }) {
                return DocumentEditing.toggleQuote(state, style: style)
            }
            if DocumentNodeType.isHeading(block.leafType) {
                return DocumentEditing.setHeading(state, level: 0, style: style)
            }
        }

        // Deleting between an auto-inserted pair removes both, so `()` with the caret inside clears
        // in one press rather than leaving a stray `)`.
        guard options.closeBrackets, state.selection.location > 0,
              state.selection.location < state.length else { return nil }

        let text = state.nsString
        let before = text.substring(with: NSRange(location: state.selection.location - 1, length: 1))
        let after = text.substring(with: NSRange(location: state.selection.location, length: 1))

        guard let opener = before.first, let closer = bracketPairs[opener],
              String(closer) == after else { return nil }

        let mutable = NSMutableAttributedString(attributedString: state.text)
        mutable.deleteCharacters(in: NSRange(location: state.selection.location - 1, length: 2))
        return EditorDocumentState(
            text: mutable,
            selection: NSRange(location: state.selection.location - 1, length: 0)
        )
    }

    // MARK: - Insertion helpers

    /// Inserts plain text at the selection, inheriting the attributes already there.
    static func insert(_ string: String,
                       in state: EditorDocumentState,
                       style: DocumentStyle) -> EditorDocumentState? {
        guard !string.isEmpty else { return nil }
        let mutable = NSMutableAttributedString(attributedString: state.text)

        let anchor = max(0, min(state.selection.location, max(0, mutable.length - 1)))
        let attributes = mutable.length > 0
            ? mutable.attributes(at: anchor, effectiveRange: nil)
            : style.attributes(for: state.caretBlock)
                .merging([.documentBlock: state.caretBlock]) { _, new in new }

        mutable.replaceCharacters(in: state.selection,
                                  with: NSAttributedString(string: string, attributes: attributes))
        return EditorDocumentState(
            text: mutable,
            selection: NSRange(location: state.selection.location + (string as NSString).length,
                               length: 0)
        )
    }

    /// Starts a new line carrying `block`, which is what makes Return produce a *different* block
    /// from the one it was pressed in.
    private static func insertLine(in state: EditorDocumentState,
                                   block: DocumentBlock,
                                   style: DocumentStyle) -> EditorDocumentState {
        let mutable = NSMutableAttributedString(attributedString: state.text)
        let anchor = max(0, min(state.selection.location, max(0, mutable.length - 1)))
        var attributes = mutable.length > 0
            ? mutable.attributes(at: anchor, effectiveRange: nil)
            : style.attributes(for: block)
        attributes[.documentBlock] = block
        attributes.removeValue(forKey: .documentNode)

        // Everything from the caret to the end of the line moves onto the new block too — pressing
        // Return in the middle of an item splits it into two items, not one item and an orphan.
        let line = state.caretLine
        let tail = NSRange(location: state.selection.location,
                           length: max(0, NSMaxRange(line) - state.selection.location))

        mutable.replaceCharacters(
            in: state.selection,
            with: NSAttributedString(string: DocumentProjection.blockSeparator,
                                     attributes: attributes)
        )
        if tail.length > 0 {
            mutable.addAttribute(.documentBlock, value: block,
                                 range: NSRange(location: tail.location + 1, length: tail.length))
        }

        return DocumentEditing.reproject(
            mutable,
            selection: NSRange(location: state.selection.location + 1, length: 0),
            style: style
        )
    }
}
