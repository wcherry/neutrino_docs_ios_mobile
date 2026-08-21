import Foundation

// MARK: - JSONValue

/// A JSON value held exactly as it was written.
///
/// A Neutrino Doc's stored body is a ProseMirror document produced by the web app's TipTap editor,
/// and it carries far more than this app models — a table cell's `colspan`, a tracked change's
/// author, a paragraph's line height. Decoding those attributes into `JSONValue` instead of dropping
/// them is what lets a document edited on an iPhone go back to the web with its web-only settings
/// intact.
enum JSONValue: Equatable, Hashable {
    case null
    case bool(Bool)
    /// Kept apart from `double` so `{"level": 1}` re-encodes as `1` rather than `1.0`.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - JSONValue + accessors

extension JSONValue {

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):    return value
        case .double(let value): return Int(value)
        default:                 return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - JSONValue + Codable

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unrepresentable JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .int(let v):      try container.encode(v)
        case .double(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }
}

// MARK: - ProseMirrorMark

/// An inline mark — `bold`, `italic`, `link`, and the web app's own `trackedInsertion` and friends.
///
/// `Hashable` so it can ride in an `NSAttributedString` attribute: the text system merges adjacent
/// runs by comparing their attribute values, and a value that cannot be hashed or compared leaves
/// every character in a run of its own.
struct ProseMirrorMark: Equatable, Hashable, Codable {
    var type: String
    var attrs: [String: JSONValue]?

    init(type: String, attrs: [String: JSONValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }
}

// MARK: - ProseMirrorNode

/// One node of a ProseMirror document tree.
///
/// Deliberately schema-less: any `type` decodes, and unknown attributes survive re-encoding. The
/// schema lives in the web app's TipTap extension list, and duplicating it here would mean this app
/// silently discarding every node a newer web release adds.
struct ProseMirrorNode: Equatable, Hashable, Codable {
    var type: String
    var attrs: [String: JSONValue]?
    var content: [ProseMirrorNode]?
    var marks: [ProseMirrorMark]?
    var text: String?

    init(type: String,
         attrs: [String: JSONValue]? = nil,
         content: [ProseMirrorNode]? = nil,
         marks: [ProseMirrorMark]? = nil,
         text: String? = nil) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.text = text
    }

    /// The children, or an empty array — the common case at every call site is "walk the children".
    var children: [ProseMirrorNode] { content ?? [] }

    func attribute(_ name: String) -> JSONValue? { attrs?[name] }

    func mark(_ name: String) -> ProseMirrorMark? { marks?.first { $0.type == name } }

    /// What the document says, with nothing around it: every text run, one line per block.
    ///
    /// The counterpart to ``DocumentProjection``, minus the styling — for the places that want the
    /// words and not the appearance, like the word count.
    var plainText: String {
        if let text { return text }
        // A text block's children are the runs of one line and run together; everything else holds
        // blocks, and each of those is a line of its own.
        let separator = DocumentNodeType.textBlocks.contains(type)
            ? ""
            : DocumentProjection.blockSeparator
        return children.map(\.plainText).joined(separator: separator)
    }

    func hasMark(_ names: String...) -> Bool {
        guard let marks else { return false }
        return marks.contains { names.contains($0.type) }
    }

    // MARK: - Convenience constructors

    static func text(_ string: String, marks: [ProseMirrorMark]? = nil) -> ProseMirrorNode {
        ProseMirrorNode(type: "text", marks: marks, text: string)
    }

    static func paragraph(_ content: [ProseMirrorNode]) -> ProseMirrorNode {
        // An empty paragraph must have no `content` key at all: ProseMirror rejects `content: []`
        // for a node whose schema requires inline content.
        ProseMirrorNode(type: "paragraph", content: content.isEmpty ? nil : content)
    }
}

// MARK: - ProseMirrorDocument

/// A stored Neutrino Doc body: the ProseMirror document, plus the web app's layout `_meta` block
/// when the document was written with one.
///
/// The web editor writes one of two shapes depending on its `docsLayoutStructure` feature flag —
/// a bare document, or `{ "doc": …, "_meta": … }`. Both are read here, and whichever shape a
/// document arrived in is the shape it is written back in, so opening a document on iPhone never
/// changes its envelope out from under the web app.
struct ProseMirrorDocument: Equatable {

    /// The root node, always of type `doc`.
    var doc: ProseMirrorNode

    /// The web app's `_meta`: header and footer text, page numbers, watermark, background, theme.
    /// Held verbatim because this app has no editor for any of it, and dropping it would silently
    /// reset a document's page setup the first time it was opened on a phone.
    var layout: JSONValue?

    init(doc: ProseMirrorNode, layout: JSONValue? = nil) {
        self.doc = doc
        self.layout = layout
    }

    /// An empty document — what the backend seeds a new file with (`{"type":"doc","content":[]}`).
    static let empty = ProseMirrorDocument(doc: ProseMirrorNode(type: "doc", content: []))

    // MARK: - Coding

    /// Decodes either envelope shape. Returns nil when `json` is not a ProseMirror document at all,
    /// which is how `NeutrinoDocumentCodec` recognizes a body it has to read as plain text.
    static func decode(from json: String) -> ProseMirrorDocument? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        // The wrapper form is checked first: `{ doc, _meta }` would otherwise decode as a node whose
        // `type` is missing, which the node decoder rejects — but only by accident of key names.
        if let wrapper = try? decoder.decode(Wrapper.self, from: data), wrapper.doc.type == "doc" {
            return ProseMirrorDocument(doc: wrapper.doc, layout: wrapper.meta)
        }
        if let node = try? decoder.decode(ProseMirrorNode.self, from: data), node.type == "doc" {
            return ProseMirrorDocument(doc: node)
        }
        return nil
    }

    /// Re-encodes in the envelope shape this document arrived in.
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        // Stable key order keeps a no-op save from producing different bytes each time, which
        // matters because the offline cache compares ciphertext blobs.
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        if let layout {
            data = try encoder.encode(Wrapper(doc: doc, meta: layout))
        } else {
            data = try encoder.encode(doc)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Wrapper: Codable {
        var doc: ProseMirrorNode
        var meta: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case doc
            case meta = "_meta"
        }
    }
}
