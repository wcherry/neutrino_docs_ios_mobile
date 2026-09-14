import Foundation
import UIKit

// MARK: - EditorDocumentState

/// A snapshot of the editor: the styled text it holds, and the current selection.
///
/// This is the tree-native replacement for the old source-string state. The text is a
/// ``DocumentProjection`` — every character carries the block it belongs to and the marks it
/// wears — so a command is an *attribute* edit rather than string surgery on syntax. Offsets are
/// UTF-16, matching `NSRange` and `UITextView.selectedRange`.
///
/// Every command is a pure `EditorDocumentState -> EditorDocumentState` function, which is what
/// keeps the whole formatting toolbar testable without a `UITextView` in the loop.
struct EditorDocumentState {

    var text: NSAttributedString
    var selection: NSRange

    /// The marks the next characters typed will carry, when they are not simply the ones already
    /// under the caret — what "press bold, then type" leaves behind.
    ///
    /// It exists because a caret has no text to mark: the intent has to be held somewhere until
    /// there are characters to put it on. The editor keeps it in the text view's typing attributes,
    /// which is where UIKit reads from when it inserts; this carries it into the pure world so the
    /// toolbar's toggles answer from the same place.
    var pendingMarks: DocumentMarks?

    init(text: NSAttributedString, selection: NSRange, pendingMarks: DocumentMarks? = nil) {
        self.text = text
        self.pendingMarks = pendingMarks
        // A selection past the end would trap on the first substring operation. Clamping here means
        // every command downstream can assume the range is valid.
        let length = text.length
        let location = min(max(0, selection.location), length)
        self.selection = NSRange(location: location,
                                 length: min(max(0, selection.length), length - location))
    }

    /// Convenience for building a state from a document, which is what tests and the initial load do.
    init(doc: ProseMirrorNode, style: DocumentStyle, selection: NSRange = NSRange(location: 0, length: 0)) {
        self.init(text: DocumentProjection.attributedString(from: doc, style: style),
                  selection: selection)
    }

    var nsString: NSString { text.string as NSString }

    var length: Int { text.length }

    /// Collapsed selection — a caret rather than a range.
    var isCaret: Bool { selection.length == 0 }

    /// The document the editor currently holds.
    var document: ProseMirrorNode { DocumentBuilder.document(from: text) }

    // MARK: - Lines

    /// The block-separated lines the selection touches, as content ranges excluding the separator.
    ///
    /// A line is a block, so every structural command works over these rather than over characters.
    var selectedLines: [NSRange] {
        Self.lines(in: text, covering: selection)
    }

    /// The line the caret sits on.
    var caretLine: NSRange {
        Self.lines(in: text, covering: NSRange(location: selection.location, length: 0)).first
            ?? NSRange(location: 0, length: 0)
    }

    /// Every line of `text` that `range` touches, as content ranges without the trailing separator.
    static func lines(in text: NSAttributedString, covering range: NSRange) -> [NSRange] {
        let string = text.string as NSString
        var result: [NSRange] = []
        var start = 0

        while start <= string.length {
            let searchRange = NSRange(location: start, length: string.length - start)
            let separator = string.range(of: DocumentProjection.blockSeparator,
                                         options: [], range: searchRange)
            let end = separator.location == NSNotFound ? string.length : separator.location
            let content = NSRange(location: start, length: end - start)

            // A zero-length selection on a boundary belongs to the line it opens, and a selection
            // that merely ends where a line starts has not reached into it.
            let touches = range.length == 0
                ? (range.location >= content.location && range.location <= NSMaxRange(content))
                : (range.location < NSMaxRange(content) + 1 && NSMaxRange(range) > content.location)

            if touches { result.append(content) }

            if separator.location == NSNotFound { break }
            start = NSMaxRange(separator)
        }

        return result.isEmpty ? [NSRange(location: 0, length: 0)] : result
    }

    // MARK: - Reading the document at the selection

    /// The block of the line the caret is on.
    var caretBlock: DocumentBlock {
        Self.block(ofLine: caretLine, in: text)
    }

    /// The block a line belongs to, falling back to a bare paragraph for an empty document.
    static func block(ofLine line: NSRange, in text: NSAttributedString) -> DocumentBlock {
        guard text.length > 0 else {
            return DocumentBlock([DocumentBlock.Level(type: DocumentNodeType.paragraph, id: 0)])
        }
        let index = min(line.location, text.length - 1)
        let found = text.attribute(.documentBlock, at: index, effectiveRange: nil)
        return (found as? DocumentBlock)
            ?? DocumentBlock([DocumentBlock.Level(type: DocumentNodeType.paragraph, id: 0)])
    }

    /// The marks in force at the caret, which is what the toolbar's toggles show as active.
    ///
    /// Read from the character *before* the caret rather than after it: that is the run typing will
    /// join, and so the formatting the next keystroke will carry — unless the user has just said
    /// otherwise by pressing a toggle with nothing selected, which is what `pendingMarks` holds.
    var activeMarks: DocumentMarks {
        if isCaret, let pendingMarks { return pendingMarks }
        guard text.length > 0 else { return DocumentMarks([]) }
        if selection.length > 0 {
            // A selection is bold when every character in it is.
            var shared: DocumentMarks?
            var uniform = true
            text.enumerateAttribute(.documentMarks, in: selection, options: []) { value, _, stop in
                let marks = (value as? DocumentMarks) ?? DocumentMarks([])
                if let existing = shared {
                    if !existing.isEqual(marks) { uniform = false; stop.pointee = true }
                } else {
                    shared = marks
                }
            }
            return uniform ? (shared ?? DocumentMarks([])) : DocumentMarks([])
        }
        let index = max(0, min(selection.location - 1, text.length - 1))
        return (text.attribute(.documentMarks, at: index, effectiveRange: nil) as? DocumentMarks)
            ?? DocumentMarks([])
    }

    // MARK: - Identifiers

    /// One past the largest level id anywhere in the text.
    ///
    /// New containers are numbered from here so a list created now cannot collide with — and so be
    /// merged into — one that is already there.
    var nextLevelID: Int {
        var highest = 0
        text.enumerateAttribute(.documentBlock, in: NSRange(location: 0, length: text.length),
                                options: []) { value, _, _ in
            guard let block = value as? DocumentBlock else { return }
            for level in block.levels { highest = max(highest, level.id) }
        }
        return highest + 1
    }
}

// MARK: - DocumentBlock nesting

extension DocumentBlock {

    /// Inserts container levels directly above the leaf — how a paragraph becomes a list item or
    /// enters a quote without losing what it already sits inside.
    func wrapping(in containers: [Level]) -> DocumentBlock {
        guard !levels.isEmpty else { return DocumentBlock(containers) }
        var updated = levels
        let leaf = updated.removeLast()
        return DocumentBlock(updated + containers + [leaf])
    }

    /// Removes the innermost container satisfying `predicate`, keeping everything else.
    ///
    /// - Parameter depth: how many levels the container occupies. A quote is one; a list is two,
    ///   because its `listItem` goes with it — an item with no list around it is not a shape the
    ///   schema allows.
    func unwrapping(depth: Int = 1, where predicate: (Level) -> Bool) -> DocumentBlock {
        var containers = levels
        guard !containers.isEmpty else { return self }
        let leaf = containers.removeLast()

        guard let index = containers.lastIndex(where: predicate) else { return self }
        let end = min(index + depth, containers.count)
        let kept = Array(containers.prefix(index)) + Array(containers.suffix(from: end))
        return DocumentBlock(kept + [leaf])
    }

    /// The innermost list container, at any depth.
    var innermostList: Level? {
        levels.last { DocumentNodeType.isList($0.type) }
    }

    /// Whether the line sits inside a container of this type.
    func isInside(_ predicate: (Level) -> Bool) -> Bool {
        levels.dropLast().contains(where: predicate)
    }

    /// How many list containers enclose the line — its indent level in a list.
    var listDepth: Int {
        levels.dropLast().filter { DocumentNodeType.isList($0.type) }.count
    }
}
