import Foundation
import UIKit

// MARK: - DocumentEditingCommand

/// The formatting-toolbar actions — Phase 2 — Formatting Toolbar: "Bold", "Italic", "Link",
/// "Image", "Code", "Quote", "Table", "Checkbox".
///
/// Each command is a pure transform over an ``EditorDocumentState``, so its exact behaviour — what
/// happens with no selection, what happens when the formatting is already there — is pinned down in
/// tests rather than discovered by tapping buttons.
///
/// A command edits the *document* attributes a run carries and lets the projection decide how that
/// looks. Nothing here writes syntax, because there is no syntax: making a line a heading sets its
/// block's leaf type, and the type is what the size on screen is derived from.
enum DocumentEditingCommand: String, CaseIterable, Identifiable {
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
    // The paragraph styles, which the style bar offers as a choice rather than as toggles.
    case body
    case heading1
    case heading2
    case heading3

    var id: String { rawValue }

    /// The paragraph styles, in the order the style bar lists them.
    static let paragraphStyles: [DocumentEditingCommand] = [.body, .heading1, .heading2, .heading3]

    /// The style a line of this heading level is in — 0 being body text.
    static func paragraphStyle(forHeadingLevel level: Int) -> DocumentEditingCommand {
        switch level {
        case 1:  return .heading1
        case 2:  return .heading2
        // Deeper headings are rare enough that the bar does not offer them, and a line already at
        // H4 or below is closer to an H3 than to body text.
        case 3...: return .heading3
        default: return .body
        }
    }

    var title: String {
        switch self {
        case .body:          return "Body"
        case .heading1:      return "Heading 1"
        case .heading2:      return "Heading 2"
        case .heading3:      return "Heading 3"
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
        case .body:          return "text.alignleft"
        case .heading1:      return "1.square"
        case .heading2:      return "2.square"
        case .heading3:      return "3.square"
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
        case .bold:     return "b"
        case .italic:   return "i"
        case .code:     return "e"
        case .link:     return "k"
        // ⌘0 for body and ⌘1–⌘3 for the headings, the pairing every editor with paragraph styles
        // uses.
        case .body:     return "0"
        case .heading1: return "1"
        case .heading2: return "2"
        case .heading3: return "3"
        default:        return nil
        }
    }

    /// The mark a command toggles, for the ones that are inline formatting.
    var markType: String? {
        switch self {
        case .bold:          return DocumentMarkType.bold
        case .italic:        return DocumentMarkType.italic
        case .strikethrough: return DocumentMarkType.strike
        case .code:          return DocumentMarkType.code
        default:             return nil
        }
    }

    // MARK: - Active state

    /// Whether this command is already in force at the selection — what the style bar draws as a
    /// lit button, and what the paragraph-style menu puts its checkmark against.
    ///
    /// Every case asks the same question the command's own transform asks before deciding which way
    /// to go, through the shared predicates below. That is the point of routing it here: a lit
    /// button promises that tapping it takes the formatting *off*, and two separately written
    /// conditions would eventually disagree about when.
    ///
    /// The commands that insert rather than toggle — a picture, a table — are never active: there is
    /// no state for them to be in.
    func isActive(in state: EditorDocumentState) -> Bool {
        switch self {
        case .bold, .italic, .strikethrough, .code:
            guard let markType else { return false }
            return DocumentEditing.allCharacters(in: state, carry: markType)
        case .link:
            return DocumentEditing.allCharacters(in: state, carry: DocumentMarkType.link)
        case .quote:
            return DocumentEditing.allLinesQuoted(state)
        case .codeBlock:
            return DocumentEditing.allLinesAreCodeBlocks(state)
        case .bulletList:
            return DocumentEditing.allLines(state, inListOfType: DocumentNodeType.bulletList)
        case .numberedList:
            return DocumentEditing.allLines(state, inListOfType: DocumentNodeType.orderedList)
        case .checkbox:
            return DocumentEditing.allLines(state, inListOfType: "taskList")
        case .body, .heading1, .heading2, .heading3:
            return Self.paragraphStyle(
                forHeadingLevel: DocumentEditing.headingLevel(of: state.caretBlock)
            ) == self
        case .image, .table:
            return false
        }
    }

    // MARK: - Application

    /// Commands that need something the toolbar has to ask for — a URL, a picture — are no-ops
    /// here; the bar routes them to their sheet instead.
    func apply(to state: EditorDocumentState, style: DocumentStyle) -> EditorDocumentState {
        switch self {
        case .body:          return DocumentEditing.setHeading(state, level: 0, style: style)
        case .heading1:      return DocumentEditing.setHeading(state, level: 1, style: style)
        case .heading2:      return DocumentEditing.setHeading(state, level: 2, style: style)
        case .heading3:      return DocumentEditing.setHeading(state, level: 3, style: style)
        case .bold, .italic, .strikethrough, .code:
            guard let markType else { return state }
            return DocumentEditing.toggleMark(state, type: markType, style: style)
        case .quote:         return DocumentEditing.toggleQuote(state, style: style)
        case .codeBlock:     return DocumentEditing.toggleCodeBlock(state, style: style)
        case .table:         return DocumentEditing.insertTable(state, style: style)
        case .checkbox:      return DocumentEditing.toggleList(state, type: "taskList", style: style)
        case .bulletList:
            return DocumentEditing.toggleList(state, type: DocumentNodeType.bulletList, style: style)
        case .numberedList:
            return DocumentEditing.toggleList(state, type: DocumentNodeType.orderedList, style: style)
        case .link, .image:  return state
        }
    }
}

// MARK: - DocumentAlignment

/// The alignments the style bar offers, which are TipTap's `textAlign` values.
///
/// Left is the absence of the attribute rather than a value of its own: it is the default in both
/// apps, and a document that has never been aligned should not carry a setting saying so.
enum DocumentAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right
    case justify

    var id: String { rawValue }

    /// What the node's `textAlign` attribute holds. Nil for left.
    var attributeValue: JSONValue? {
        self == .left ? nil : .string(rawValue)
    }

    static func named(_ name: String?) -> DocumentAlignment {
        guard let name, let found = DocumentAlignment(rawValue: name) else { return .left }
        return found
    }

    var title: String {
        switch self {
        case .left:    return "Align Left"
        case .center:  return "Center"
        case .right:   return "Align Right"
        case .justify: return "Justify"
        }
    }

    var systemImage: String {
        switch self {
        case .left:    return "text.alignleft"
        case .center:  return "text.aligncenter"
        case .right:   return "text.alignright"
        case .justify: return "text.justify"
        }
    }
}

// MARK: - DocumentEditing

/// The transforms behind ``DocumentEditingCommand``.
///
/// Every one of them follows the same shape: rewrite the `.documentBlock` or `.documentMarks`
/// attributes the affected characters carry, then re-derive the text from the document those
/// attributes now describe. The re-derivation is what keeps presentation and document in step —
/// nothing here computes a font, and nothing here has to.
enum DocumentEditing {

    // MARK: - Re-deriving

    /// Rebuilds the document from the edited attributes and projects it again.
    ///
    /// This is deliberately a whole-document pass. A structural edit can change how *other* lines
    /// group — taking a line out of the middle of a list splits it in two — and only a rebuild
    /// gets that right. It costs one walk of the document per toolbar tap, which is not a keystroke.
    ///
    /// Character content is unchanged by an attribute edit, so the selection carries over as it is.
    static func reproject(_ text: NSAttributedString,
                          selection: NSRange,
                          style: DocumentStyle) -> EditorDocumentState {
        let document = DocumentBuilder.document(from: text)
        let projected = DocumentProjection.attributedString(from: document, style: style)
        return EditorDocumentState(text: projected, selection: selection)
    }

    /// Applies `transform` to the block of every line the selection touches.
    static func mapBlocks(_ state: EditorDocumentState,
                          style: DocumentStyle,
                          transform: (DocumentBlock, Int) -> DocumentBlock) -> EditorDocumentState {
        let mutable = NSMutableAttributedString(attributedString: state.text)
        let lines = state.selectedLines

        for (index, line) in lines.enumerated() {
            let block = EditorDocumentState.block(ofLine: line, in: state.text)
            let updated = transform(block, index)

            // The separator that ends the line carries the block too, and is what an empty line has
            // to hang its identity on — so it is rewritten with the content.
            var range = line
            if NSMaxRange(range) < mutable.length,
               (mutable.string as NSString).substring(
                   with: NSRange(location: NSMaxRange(range), length: 1)
               ) == DocumentProjection.blockSeparator {
                range.length += 1
            }
            guard range.length > 0 else { continue }
            mutable.addAttribute(.documentBlock, value: updated, range: range)
        }

        return reproject(mutable, selection: state.selection, style: style)
    }

    // MARK: - Paragraph styles

    /// Sets the heading level of every line the selection touches. Level 0 is body text.
    ///
    /// This is a *set*, not a toggle on top of whatever is there: going from H1 to H2 replaces the
    /// level rather than stacking, and choosing the level a line already has takes it back to body.
    /// That is what makes the style bar's list read as a choice you can undo rather than a one-way
    /// trip.
    ///
    /// A line keeps where it sits: a bullet that becomes a heading is still an item of its list.
    static func setHeading(_ state: EditorDocumentState,
                           level: Int,
                           style: DocumentStyle) -> EditorDocumentState {
        let blocks = selectedBlocks(state)
        let alreadyAtLevel = level > 0 && !blocks.isEmpty && blocks.allSatisfy {
            DocumentNodeType.isHeading($0.leafType) && ($0.attrs?["level"]?.intValue ?? 1) == level
        }
        let target = alreadyAtLevel ? 0 : level

        return mapBlocks(state, style: style) { block, _ in
            // Alignment is a property of the line, not of its type, so it survives the change.
            let alignment = block.attrs?["textAlign"]

            guard target > 0 else {
                var attrs: [String: JSONValue] = [:]
                if let alignment { attrs["textAlign"] = alignment }
                return block.replacingLeaf(type: DocumentNodeType.paragraph,
                                           attrs: attrs.isEmpty ? nil : attrs)
            }

            var attrs: [String: JSONValue] = ["level": .int(target)]
            if let alignment { attrs["textAlign"] = alignment }
            return block.replacingLeaf(type: DocumentNodeType.heading, attrs: attrs)
        }
    }

    /// The heading level of the line the caret is on, 0 for body text.
    static func headingLevel(of block: DocumentBlock) -> Int {
        guard DocumentNodeType.isHeading(block.leafType) else { return 0 }
        return block.attrs?["level"]?.intValue ?? 1
    }

    // MARK: - Alignment

    /// Sets the alignment of every line the selection touches.
    static func setAlignment(_ state: EditorDocumentState,
                             to alignment: DocumentAlignment,
                             style: DocumentStyle) -> EditorDocumentState {
        mapBlocks(state, style: style) { block, _ in
            block.settingLeafAttribute("textAlign", to: alignment.attributeValue)
        }
    }

    /// The alignment of the line the caret is on.
    static func alignment(of block: DocumentBlock) -> DocumentAlignment {
        DocumentAlignment.named(block.attrs?["textAlign"]?.stringValue)
    }

    // MARK: - Inline marks

    /// Adds a mark to the selection, or takes it off when every character already has it.
    ///
    /// With no selection there is nothing to mark, so the state is returned unchanged. That case
    /// never reaches here: ``DocumentEditorController/apply(_:)`` sends a caret to the text view's
    /// typing attributes instead, which is what makes "press bold, then type" work without
    /// inserting anything to hang the mark on.
    static func toggleMark(_ state: EditorDocumentState,
                           type: String,
                           attrs: [String: JSONValue]? = nil,
                           style: DocumentStyle) -> EditorDocumentState {
        guard state.selection.length > 0 else { return state }

        let hasEverywhere = allCharacters(in: state, carry: type)
        let mutable = NSMutableAttributedString(attributedString: state.text)

        mutable.enumerateAttribute(.documentMarks, in: state.selection, options: []) { value, range, _ in
            let current = (value as? DocumentMarks) ?? DocumentMarks([])
            let updated = hasEverywhere
                ? current.removing(type)
                : current.adding(ProseMirrorMark(type: type, attrs: attrs))

            if updated.isEmpty {
                mutable.removeAttribute(.documentMarks, range: range)
            } else {
                mutable.addAttribute(.documentMarks, value: updated, range: range)
            }
        }

        return reproject(mutable, selection: state.selection, style: style)
    }

    /// Whether every character of the selection carries `type`.
    static func allCharacters(in state: EditorDocumentState, carry type: String) -> Bool {
        guard state.selection.length > 0 else {
            return state.activeMarks.has(type)
        }
        var everywhere = true
        state.text.enumerateAttribute(.documentMarks, in: state.selection, options: []) { value, _, stop in
            let marks = (value as? DocumentMarks) ?? DocumentMarks([])
            if !marks.has(type) { everywhere = false; stop.pointee = true }
        }
        return everywhere
    }

    /// Puts a link on the selection, replacing any link already there.
    static func setLink(_ state: EditorDocumentState,
                        href: String,
                        style: DocumentStyle) -> EditorDocumentState {
        guard state.selection.length > 0, !href.isEmpty else { return state }
        let mutable = NSMutableAttributedString(attributedString: state.text)

        mutable.enumerateAttribute(.documentMarks, in: state.selection, options: []) { value, range, _ in
            let current = (value as? DocumentMarks) ?? DocumentMarks([])
            let updated = current.adding(
                ProseMirrorMark(type: DocumentMarkType.link, attrs: ["href": .string(href)])
            )
            mutable.addAttribute(.documentMarks, value: updated, range: range)
        }

        return reproject(mutable, selection: state.selection, style: style)
    }

    static func removeLink(_ state: EditorDocumentState,
                           style: DocumentStyle) -> EditorDocumentState {
        toggleMark(state, type: DocumentMarkType.link, style: style)
    }

    // MARK: - What the selection already is

    /// The block of every line the selection touches.
    static func selectedBlocks(_ state: EditorDocumentState) -> [DocumentBlock] {
        state.selectedLines.map { EditorDocumentState.block(ofLine: $0, in: state.text) }
    }

    /// Whether every line the selection touches already sits in a quote.
    ///
    /// One function rather than two because one answer decides two things: which way `toggleQuote`
    /// goes, and whether the toolbar lights its button. See ``DocumentEditingCommand/isActive(in:)``.
    static func allLinesQuoted(_ state: EditorDocumentState) -> Bool {
        let blocks = selectedBlocks(state)
        return !blocks.isEmpty && blocks.allSatisfy {
            $0.isInside { $0.type == DocumentNodeType.blockquote }
        }
    }

    /// Whether every line the selection touches is already a code block.
    static func allLinesAreCodeBlocks(_ state: EditorDocumentState) -> Bool {
        let blocks = selectedBlocks(state)
        return !blocks.isEmpty && blocks.allSatisfy { DocumentNodeType.isCodeBlock($0.leafType) }
    }

    /// Whether every line the selection touches is already an item of a list of `type`.
    ///
    /// The *innermost* list decides it: a bullet nested inside a numbered list is a bullet, which is
    /// also the one `toggleList` would replace.
    static func allLines(_ state: EditorDocumentState, inListOfType type: String) -> Bool {
        let blocks = selectedBlocks(state)
        return !blocks.isEmpty && blocks.allSatisfy {
            $0.innermostList.map { $0.type == type } ?? false
        }
    }

    // MARK: - Containers

    /// Puts the selected lines in a quote, or takes them out when they are all already in one.
    static func toggleQuote(_ state: EditorDocumentState,
                            style: DocumentStyle) -> EditorDocumentState {
        let allQuoted = allLinesQuoted(state)
        let id = state.nextLevelID

        return mapBlocks(state, style: style) { block, _ in
            guard !allQuoted else {
                return block.unwrapping { $0.type == DocumentNodeType.blockquote }
            }
            // One id for the whole selection, so the lines form a single quote rather than one
            // quote each.
            return block.wrapping(in: [DocumentBlock.Level(type: DocumentNodeType.blockquote, id: id)])
        }
    }

    /// Puts the selected lines in a list of `type`, or takes them out when they are already in one
    /// of that type. A list of a different type is replaced rather than nested.
    static func toggleList(_ state: EditorDocumentState,
                           type: String,
                           style: DocumentStyle) -> EditorDocumentState {
        let itemType = type == "taskList" ? "taskItem" : DocumentNodeType.listItem
        let allInThisList = allLines(state, inListOfType: type)

        let listID = state.nextLevelID
        var nextItemID = listID + 1

        return mapBlocks(state, style: style) { block, _ in
            // Already in a list of some kind: leave it, so switching type is a replacement rather
            // than a bullet inside a number.
            let stripped = block.innermostList != nil
                ? block.unwrapping(depth: 2) { DocumentNodeType.isList($0.type) }
                : block

            guard !allInThisList else { return stripped }

            let item = DocumentBlock.Level(type: itemType, id: nextItemID)
            nextItemID += 1
            return stripped.wrapping(in: [DocumentBlock.Level(type: type, id: listID), item])
        }
    }

    /// Makes the selected lines code blocks, or turns them back into paragraphs.
    static func toggleCodeBlock(_ state: EditorDocumentState,
                                style: DocumentStyle) -> EditorDocumentState {
        let allCode = allLinesAreCodeBlocks(state)

        return mapBlocks(state, style: style) { block, _ in
            allCode
                ? block.replacingLeaf(type: DocumentNodeType.paragraph, attrs: nil)
                : block.replacingLeaf(type: DocumentNodeType.codeBlock, attrs: nil)
        }
    }

    // MARK: - Indentation

    /// Tab / Shift-Tab — Phase 2 — Editor Improvements, "Smart indentation".
    ///
    /// In a list this nests an item under the one above it, or lifts it back out. Outside a list
    /// there is nothing to indent to: a document's shape is its tree, not its leading spaces, so
    /// this does nothing rather than inserting whitespace that would mean nothing.
    static func indent(_ state: EditorDocumentState,
                       outdent: Bool = false,
                       style: DocumentStyle) -> EditorDocumentState {
        let listID = state.nextLevelID
        var nextItemID = listID + 1

        return mapBlocks(state, style: style) { block, _ in
            guard let list = block.innermostList else { return block }

            guard !outdent else {
                return block.unwrapping(depth: 2) { DocumentNodeType.isList($0.type) }
            }

            // Nesting reuses the enclosing list's type, so an indented number stays a number.
            let item = DocumentBlock.Level(type: block.listItem?.type ?? DocumentNodeType.listItem,
                                           id: nextItemID)
            nextItemID += 1
            return block.wrapping(in: [DocumentBlock.Level(type: list.type, id: listID), item])
        }
    }

    // MARK: - Inserting content

    /// A 2×3 starter table, the smallest one that shows a header row.
    static func insertTable(_ state: EditorDocumentState,
                            style: DocumentStyle) -> EditorDocumentState {
        func cell(_ text: String, type: String) -> ProseMirrorNode {
            ProseMirrorNode(type: type,
                            content: [ProseMirrorNode(type: DocumentNodeType.paragraph,
                                                      content: text.isEmpty ? nil : [.text(text)])])
        }

        let table = ProseMirrorNode(type: "table", content: [
            ProseMirrorNode(type: "tableRow", content: [
                cell("Column 1", type: "tableHeader"),
                cell("Column 2", type: "tableHeader"),
            ]),
            ProseMirrorNode(type: "tableRow", content: [
                cell("", type: "tableCell"),
                cell("", type: "tableCell"),
            ]),
        ])

        return insertBlocks([table], in: state, style: style)
    }

    /// Splices whole blocks into the document at the caret's line boundary.
    ///
    /// The fragment is projected with the same style as the document and its level ids are lifted
    /// clear of the ones already in use, so a spliced list cannot be merged into a neighbouring one
    /// that happened to be numbered the same.
    static func insertBlocks(_ nodes: [ProseMirrorNode],
                             in state: EditorDocumentState,
                             style: DocumentStyle) -> EditorDocumentState {
        let container = ProseMirrorNode(type: DocumentNodeType.doc, content: nodes)
        let fragment = NSMutableAttributedString(
            attributedString: DocumentProjection.attributedString(from: container, style: style)
        )
        offsetLevelIDs(in: fragment, by: state.nextLevelID)

        let mutable = NSMutableAttributedString(attributedString: state.text)
        let line = state.caretLine

        // A block insertion starts on a line of its own. An empty line is replaced; anything else
        // is pushed down.
        var insertAt = NSMaxRange(line)
        if line.length == 0 {
            insertAt = line.location
        } else {
            fragment.insert(NSAttributedString(string: DocumentProjection.blockSeparator,
                                               attributes: mutable.attributes(at: max(0, min(line.location, mutable.length - 1)),
                                                                              effectiveRange: nil)),
                            at: 0)
        }

        mutable.insert(fragment, at: min(insertAt, mutable.length))

        // The caret lands in the first cell, ready to be typed over.
        let caret = min(insertAt + (line.length == 0 ? 0 : 1), mutable.length)
        return reproject(mutable,
                         selection: NSRange(location: caret, length: min(8, max(0, mutable.length - caret))),
                         style: style)
    }

    /// Inserts an atomic inline node — a picture — at the selection.
    static func insertAtom(_ node: ProseMirrorNode,
                           in state: EditorDocumentState,
                           style: DocumentStyle) -> EditorDocumentState {
        let mutable = NSMutableAttributedString(attributedString: state.text)
        let anchor = max(0, min(state.selection.location, max(0, mutable.length - 1)))

        var attributes = mutable.length > 0
            ? mutable.attributes(at: anchor, effectiveRange: nil)
            : style.attributes(for: DocumentBlock([DocumentBlock.Level(type: DocumentNodeType.paragraph, id: 1)]))
        attributes[.documentNode] = DocumentAtom(node)
        attributes.removeValue(forKey: .documentMarks)

        mutable.replaceCharacters(
            in: state.selection,
            with: NSAttributedString(string: DocumentProjection.atom, attributes: attributes)
        )

        let caret = state.selection.location + 1
        return reproject(mutable, selection: NSRange(location: caret, length: 0), style: style)
    }

    /// Replaces the atom at `range` with an edited copy of itself — how the image panel applies a
    /// change without touching anything else in the document.
    static func replaceAtom(_ state: EditorDocumentState,
                            at range: NSRange,
                            with node: ProseMirrorNode,
                            style: DocumentStyle) -> EditorDocumentState {
        guard range.location >= 0, NSMaxRange(range) <= state.length, range.length == 1 else {
            return state
        }
        let mutable = NSMutableAttributedString(attributedString: state.text)
        mutable.addAttribute(.documentNode, value: DocumentAtom(node), range: range)
        return reproject(mutable, selection: state.selection, style: style)
    }

    /// Takes an atom out of the document.
    static func removeAtom(_ state: EditorDocumentState,
                           at range: NSRange,
                           style: DocumentStyle) -> EditorDocumentState {
        guard range.location >= 0, NSMaxRange(range) <= state.length else { return state }
        let mutable = NSMutableAttributedString(attributedString: state.text)
        mutable.deleteCharacters(in: range)
        return reproject(mutable,
                         selection: NSRange(location: range.location, length: 0),
                         style: style)
    }

    // MARK: - Identifiers

    /// Lifts every level id in `text` clear of the ids already in the document it is spliced into.
    private static func offsetLevelIDs(in text: NSMutableAttributedString, by offset: Int) {
        text.enumerateAttribute(.documentBlock, in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let block = value as? DocumentBlock else { return }
            let lifted = DocumentBlock(block.levels.map { level in
                DocumentBlock.Level(type: level.type, attrs: level.attrs,
                                    id: level.id + offset, ordinal: level.ordinal)
            })
            text.addAttribute(.documentBlock, value: lifted, range: range)
        }
    }
}
