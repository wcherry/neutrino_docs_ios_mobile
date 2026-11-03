import Foundation
import UIKit

// MARK: - Attribute keys

/// The three attributes that carry the ProseMirror document through the text view.
///
/// Everything else on a run — font, colour, paragraph style — is presentation derived from these,
/// and is never read back. These three are the document; the rest is how it looks.
extension NSAttributedString.Key {

    /// The block the character belongs to, with its whole ancestry. See ``DocumentBlock``.
    static let documentBlock = NSAttributedString.Key("neutrinoDocumentBlock")

    /// The inline marks the character carries, as ``DocumentMarks``. Absent means unmarked text.
    static let documentMarks = NSAttributedString.Key("neutrinoDocumentMarks")

    /// The node an attachment character stands in for — a picture, a rule, an embed the app does
    /// not model. Held whole so it is written back exactly as it arrived.
    static let documentNode = NSAttributedString.Key("neutrinoDocumentNode")
}

// MARK: - DocumentBlock

/// Where one line of text sits in the document tree.
///
/// `levels` runs outermost to innermost and always ends with the node that holds the line's inline
/// content — so a bullet inside a quote is `[blockquote, bulletList, listItem, paragraph]`. The
/// builder regroups lines by their common prefix, which is what rebuilds the nesting.
///
/// An `NSObject` rather than a struct because `NSAttributedString` decides whether two adjacent
/// runs can be merged by sending `isEqual:` to their attribute values. A Swift struct bridged into
/// an attribute dictionary compares by identity, which would leave every character in its own run.
final class DocumentBlock: NSObject {

    // MARK: - Level

    struct Level: Hashable {

        /// The ProseMirror node type, spelled as the document spells it.
        var type: String

        /// The node's attributes, held verbatim so web-only settings survive a save.
        var attrs: [String: JSONValue]?

        /// Distinguishes two adjacent instances of the same container.
        ///
        /// Without it, two consecutive bulleted lists would share a prefix and be rebuilt as one.
        /// A line inheriting an id — which is what typing at the end of a list item does, since the
        /// new characters take the previous character's attributes — is a line joining that same
        /// list, which is exactly the wanted behaviour.
        var id: Int

        /// The item's position in its parent ordered list, counting from the list's `start`.
        /// Derived at projection time for rendering the number; never written back.
        var ordinal: Int?

        init(type: String, attrs: [String: JSONValue]? = nil, id: Int, ordinal: Int? = nil) {
            self.type = type
            self.attrs = attrs
            self.id = id
            self.ordinal = ordinal
        }

        /// Two levels are the same *instance* of a container, which is what grouping turns on.
        /// Attributes are deliberately not compared: a level's attrs can be edited (a heading's
        /// level, a cell's colspan) without the line leaving the container it is in.
        func isSameInstance(as other: Level) -> Bool {
            type == other.type && id == other.id
        }
    }

    // MARK: - Properties

    let levels: [Level]

    init(_ levels: [Level]) {
        self.levels = levels
    }

    // MARK: - Accessors

    /// The node holding the inline content — the line's own block.
    var leaf: Level { levels.last ?? Level(type: "paragraph", id: 0) }

    var leafType: String { leaf.type }

    var attrs: [String: JSONValue]? { leaf.attrs }

    /// How deeply the line is nested in containers, for the indent its paragraph style gets.
    var containerDepth: Int { max(0, levels.count - 1) }

    /// The innermost list this line is an item of, if it is one.
    var enclosingList: Level? {
        guard levels.count >= 2 else { return nil }
        // The item is the level above the leaf; the list is the one above that.
        let listIndex = levels.count - 3
        guard listIndex >= 0 else { return nil }
        let list = levels[listIndex]
        return DocumentNodeType.isList(list.type) ? list : nil
    }

    /// The list item this line opens, if the line is the first block of one.
    var listItem: Level? {
        guard levels.count >= 2 else { return nil }
        let item = levels[levels.count - 2]
        return DocumentNodeType.isListItem(item.type) ? item : nil
    }

    /// Replaces the leaf, keeping the line where it is in the tree — how a paragraph becomes a
    /// heading without leaving its list item or quote.
    func replacingLeaf(type: String, attrs: [String: JSONValue]?) -> DocumentBlock {
        var updated = levels
        guard !updated.isEmpty else {
            return DocumentBlock([Level(type: type, attrs: attrs, id: 0)])
        }
        updated[updated.count - 1] = Level(type: type, attrs: attrs, id: updated[updated.count - 1].id)
        return DocumentBlock(updated)
    }

    /// Replaces the leaf's attributes, leaving its type alone — alignment, a heading's level.
    func settingLeafAttribute(_ name: String, to value: JSONValue?) -> DocumentBlock {
        var attributes = attrs ?? [:]
        if let value {
            attributes[name] = value
        } else {
            attributes.removeValue(forKey: name)
        }
        return replacingLeaf(type: leafType, attrs: attributes.isEmpty ? nil : attributes)
    }

    // MARK: - NSObject

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DocumentBlock else { return false }
        return levels == other.levels
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(levels)
        return hasher.finalize()
    }

    override var description: String {
        "DocumentBlock(" + levels.map { "\($0.type)#\($0.id)" }.joined(separator: " > ") + ")"
    }
}

// MARK: - DocumentMarks

/// The inline marks on a run of text, held whole so a mark this app does not model — a tracked
/// insertion, a comment anchor — survives being typed around.
final class DocumentMarks: NSObject {

    let marks: [ProseMirrorMark]

    init(_ marks: [ProseMirrorMark]) {
        self.marks = marks
    }

    var isEmpty: Bool { marks.isEmpty }

    func has(_ type: String) -> Bool { marks.contains { $0.type == type } }

    func mark(_ type: String) -> ProseMirrorMark? { marks.first { $0.type == type } }

    /// Adds a mark, replacing any existing one of the same type — a second link on the same words
    /// is a changed link, not two.
    func adding(_ mark: ProseMirrorMark) -> DocumentMarks {
        DocumentMarks(marks.filter { $0.type != mark.type } + [mark])
    }

    func removing(_ type: String) -> DocumentMarks {
        DocumentMarks(marks.filter { $0.type != type })
    }

    // MARK: - NSObject

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DocumentMarks else { return false }
        return marks == other.marks
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(marks)
        return hasher.finalize()
    }
}

// MARK: - DocumentAtom

/// An atomic node standing in the text as a single character — a picture, a rule, an embed.
///
/// The whole node is held rather than the parts this app understands, so an embed belonging to a
/// newer web release is written back exactly as it arrived rather than reduced to what a phone can
/// draw.
final class DocumentAtom: NSObject {

    let node: ProseMirrorNode

    init(_ node: ProseMirrorNode) {
        self.node = node
    }

    /// A copy of the atom with one attribute changed — how the image panel resizes a picture.
    func setting(_ name: String, to value: JSONValue?) -> DocumentAtom {
        var attrs = node.attrs ?? [:]
        if let value {
            attrs[name] = value
        } else {
            attrs.removeValue(forKey: name)
        }
        var updated = node
        updated.attrs = attrs.isEmpty ? nil : attrs
        return DocumentAtom(updated)
    }

    // MARK: - NSObject

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DocumentAtom else { return false }
        return node == other.node
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(node)
        return hasher.finalize()
    }
}

// MARK: - DocumentNodeType

/// The document's vocabulary, as the web app's TipTap extension list spells it.
///
/// Both spellings of every name are accepted on the way in — ProseMirror's own schema uses
/// `bullet_list` while TipTap writes `bulletList`, and documents in Drive carry both. The camelCase
/// spelling is the one written back, matching what the web app produces today.
enum DocumentNodeType {

    // MARK: - Classification

    /// Nodes that hold other blocks. Each becomes a level of ancestry rather than a line.
    static let containers: Set<String> = [
        "blockquote",
        "bulletList", "bullet_list",
        "orderedList", "ordered_list",
        "listItem", "list_item",
        "taskList", "task_list",
        "taskItem", "task_item",
        "table",
        "tableRow", "table_row",
        "tableCell", "table_cell",
        "tableHeader", "table_header",
        "columnLayout", "column",
    ]

    /// Nodes that hold inline content. Each becomes one line of text.
    static let textBlocks: Set<String> = [
        "paragraph", "heading", "codeBlock", "code_block",
    ]

    /// Nodes with no content of their own, standing in the text as a single character.
    static let atomics: Set<String> = [
        "horizontalRule", "horizontal_rule",
        "sectionBreak", "pageBreak", "page_break",
        "tableOfContents",
        "sheetEmbed", "diagramEmbed", "drawingEmbed",
    ]

    /// Inline nodes that are not text.
    static let inlineAtomics: Set<String> = [
        "image", "footnote", "crossRef", "hardBreak", "hard_break",
    ]

    static func isList(_ type: String) -> Bool {
        ["bulletList", "bullet_list", "orderedList", "ordered_list",
         "taskList", "task_list"].contains(type)
    }

    static func isOrderedList(_ type: String) -> Bool {
        ["orderedList", "ordered_list"].contains(type)
    }

    static func isListItem(_ type: String) -> Bool {
        ["listItem", "list_item", "taskItem", "task_item"].contains(type)
    }

    static func isHeading(_ type: String) -> Bool { type == "heading" }

    static func isCodeBlock(_ type: String) -> Bool {
        ["codeBlock", "code_block"].contains(type)
    }

    static func isHardBreak(_ type: String) -> Bool {
        ["hardBreak", "hard_break"].contains(type)
    }

    // MARK: - Canonical spellings

    static let paragraph = "paragraph"
    static let heading = "heading"
    static let codeBlock = "codeBlock"
    static let bulletList = "bulletList"
    static let orderedList = "orderedList"
    static let listItem = "listItem"
    static let blockquote = "blockquote"
    static let horizontalRule = "horizontalRule"
    static let hardBreak = "hardBreak"
    static let image = "image"
    static let text = "text"
    static let doc = "doc"
}

// MARK: - DocumentMarkType

/// The mark vocabulary, likewise the web app's.
enum DocumentMarkType {
    static let bold = "bold"
    static let italic = "italic"
    static let strike = "strike"
    static let code = "code"
    static let underline = "underline"
    static let link = "link"
    static let highlight = "highlight"
    static let superscript = "superscript"
    static let `subscript` = "subscript"
    /// Colour, font family, and font size all ride on this one mark's attributes.
    static let textStyle = "textStyle"
}
