import Foundation

// MARK: - DocVersion

/// One snapshot in a document's version history, from `GET /api/v1/drive/files/{id}/versions`.
///
/// Decoded straight from the API shape rather than through a private DTO, because the history
/// sheet works in terms of this type and the decode is worth testing on its own.
struct DocVersion: Identifiable, Hashable, Decodable {

    // MARK: - Properties

    let id: String
    let fileID: String
    /// 1-based, monotonically increasing per file. v1 is the snapshot taken at upload.
    let versionNumber: Int
    let sizeBytes: Int64
    /// Set only for versions saved explicitly with a name; nil for automatic snapshots.
    let label: String?
    let createdAt: Date
    /// True for explicitly saved versions, which the server never prunes automatically.
    let isNamed: Bool

    // MARK: - Init

    init(id: String, fileID: String, versionNumber: Int, sizeBytes: Int64,
         label: String? = nil, createdAt: Date, isNamed: Bool = false) {
        self.id = id
        self.fileID = fileID
        self.versionNumber = versionNumber
        self.sizeBytes = sizeBytes
        self.label = label
        self.createdAt = createdAt
        self.isNamed = isNamed
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id
        case fileID = "fileId"
        case versionNumber
        case sizeBytes
        case label
        case createdAt
        case isNamed
    }

    // MARK: - Display

    /// "Version 3", or "Draft sent to Ana (v3)" when the version was saved with a name.
    var displayTitle: String {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Version \(versionNumber)"
        }
        return "\(label) (v\(versionNumber))"
    }

    /// "v3" regardless of label — for places where space is tight.
    var shortTitle: String { "v\(versionNumber)" }

    /// The Phase 1 deliverable "View timestamps": the snapshot's creation time, written out in the
    /// reader's locale and time zone.
    var timestampText: String {
        Self.timestampFormatter.string(from: createdAt)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Shared decoder

    /// The versions endpoint returns `createdAt` as a zoned RFC 3339 timestamp, while the restore
    /// endpoint returns file metadata in Drive's zone-less shape. `DriveDate` reads both, so one
    /// decoder covers every response this feature touches.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()
}
