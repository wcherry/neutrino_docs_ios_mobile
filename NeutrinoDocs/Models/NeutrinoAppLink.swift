import Foundation

// MARK: - NeutrinoAppLink

/// The Universal Link vocabulary shared by every Neutrino iOS app.
///
/// A single link opens one Drive file in whichever app owns its format:
///
/// ```
/// https://www.getneutrino.app/open/note/0d0f7c…      -> Neutrino Notes
/// https://www.getneutrino.app/open/doc/0d0f7c…       -> Neutrino Docs
/// https://www.getneutrino.app/open/file/0d0f7c…      -> Neutrino Drive
/// ```
///
/// Only the *file id* travels in the link — never file contents and never a key. The receiving app
/// fetches the current version from the server itself, which is what keeps permissions centralised
/// and guarantees the user sees the latest revision rather than whatever Drive happened to have
/// cached. `v` (the server's `contentVersion`) may be attached as a hint; it is advisory only.
///
/// One path segment per app is what lets all three apps share a domain: the
/// `apple-app-site-association` document at `www.getneutrino.app` lists each app id against its own
/// `/open/<kind>/*` pattern, so iOS routes the link without the apps having to negotiate.
///
/// > Important: this file is duplicated verbatim in `neutrino_drive_ios_mobile`,
/// > `neutrino_notes_ios_mobile` and `neutrino_sheets_ios_mobile`. The four copies define one wire
/// > format between separately shipped binaries, so a change here that is not mirrored there
/// > breaks links across app versions. See `agent_docs/plans/feature-universal-links.md`.
enum NeutrinoAppLink {

    // MARK: - Domain

    /// The host the links are minted with, and the one the `applinks:` entitlement claims.
    ///
    /// Deliberately *not* derived from the configured server host: a development build pointed at
    /// `localhost:8080` must still produce links that iOS will hand to the sibling app, and the
    /// receiving app resolves the id against its own host anyway.
    static let host = "www.getneutrino.app"

    /// Accepted on the way in, so a link typed or pasted without the `www.` still resolves.
    static let alternateHosts = ["getneutrino.app"]

    /// First path component of every app link.
    static let pathPrefix = "open"

    /// Query item carrying the server's `contentVersion` at the time the link was made.
    static let versionQueryItem = "v"

    // MARK: - OOXML

    /// The Office Open XML types Docs, Sheets, and Slides store their files in.
    ///
    /// A Neutrino document *is* a real `.docx`, a spreadsheet a real `.xlsx`, a deck a real
    /// `.pptx` — the backend registers them in `src/drive/storage/native_types.rs` and the web app
    /// in `api-core/src/ooxml.ts` (issue #127). So an Office file sitting in Drive is not a foreign
    /// attachment to be downloaded and handed to Quick Look: it is the *native* format of the app
    /// that owns it, and it belongs on the same route as everything else that app edits.
    ///
    /// The bespoke `x-neutrino-*` JSON above them predates that change and is still read and
    /// written unchanged — nothing is migrated — so both generations stay in the routing table.
    ///
    /// Only the three modern types appear here. A legacy `.doc`/`.xls`/`.ppt` is a foreign file
    /// Neutrino cannot open, and routing one to an editor that would fail to parse it is worse for
    /// the user than the download it gets today.
    enum OOXML {
        static let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        static let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        static let pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    }

    // MARK: - Kind

    /// The Neutrino app that owns a file format. One case per `/open/<kind>/…` path.
    enum Kind: String, CaseIterable {
        case file
        case note
        case doc
        case sheet
        case slide
        case diagram
        case drawing

        /// The MIME types the server stores for this kind.
        ///
        /// Three vintages are matched, because a Drive listing routinely holds all three at once
        /// and routing must not depend on which one wrote the row:
        ///
        /// - `OOXML.*` — what Docs, Sheets, and Slides write today. A document is a `.docx`.
        /// - `application/x-neutrino-*` — the bespoke JSON that predates OOXML, still read and
        ///   written for files created in it (`src/drive/storage/native_types.rs`).
        /// - `application/vnd.neutrino.*` — the oldest spelling, still present in some records
        ///   and in Drive's `DriveItem.NeutrinoMIME`.
        ///
        /// Diagrams and Drawings have no OOXML counterpart and keep their own JSON.
        var mimeTypes: [String] {
            switch self {
            case .file:    return []
            case .note:    return ["application/x-neutrino-note", "application/vnd.neutrino.note"]
            case .doc:     return [OOXML.docx, "application/x-neutrino-doc", "application/vnd.neutrino.doc"]
            case .sheet:   return [OOXML.xlsx, "application/x-neutrino-sheet", "application/vnd.neutrino.sheet"]
            case .slide:   return [OOXML.pptx, "application/x-neutrino-slide", "application/vnd.neutrino.slide"]
            case .diagram: return ["application/x-neutrino-diagram", "application/vnd.neutrino.diagram"]
            case .drawing: return ["application/x-neutrino-drawing", "application/vnd.neutrino.drawing"]
            }
        }

        /// The app that handles this kind, as the user knows it. Used in the "…isn't installed"
        /// prompt, so it has to match the App Store name.
        var appName: String {
            switch self {
            case .file:    return "Neutrino Drive"
            case .note:    return "Neutrino Notes"
            case .doc:     return "Neutrino Docs"
            case .sheet:   return "Neutrino Sheets"
            case .slide:   return "Neutrino Slides"
            case .diagram: return "Neutrino Diagrams"
            case .drawing: return "Neutrino Drawings"
            }
        }

        /// True for the kinds Drive offers to hand off to a sibling app.
        ///
        /// Diagrams and Drawings are excluded because they exist only on the web: there is no iOS
        /// target for either, so an offer could never resolve into anything but the Drive viewer
        /// the user already had.
        ///
        /// Sheets and Slides *are* offered even though neither is on the App Store yet, because a
        /// miss is not a dead end — the prompt still opens the file in Drive, which is exactly the
        /// behaviour tapping it had before. That keeps one route for every Office file instead of
        /// two that diverge on release dates, and the day those apps ship nothing here changes.
        /// Whether an *install* button can be shown is a separate question, answered by
        /// `CompanionAppStore`: a kind with no store listing simply does not get one.
        var hasCompanionApp: Bool {
            switch self {
            case .note, .doc, .sheet, .slide: return true
            case .file, .diagram, .drawing:   return false
            }
        }
    }

    // MARK: - Destination

    /// A parsed app link.
    struct Destination: Equatable, Hashable, Identifiable {
        let kind: Kind
        let fileID: String
        /// The server's `contentVersion` when the link was minted, when the sender supplied it.
        /// Advisory: the receiver always loads the current version.
        let contentVersion: Int?

        var id: String { "\(kind.rawValue)/\(fileID)" }

        init(kind: Kind, fileID: String, contentVersion: Int? = nil) {
            self.kind = kind
            self.fileID = fileID
            self.contentVersion = contentVersion
        }
    }

    // MARK: - Building

    /// Builds the link that opens `fileID` in the app owning `kind`.
    ///
    /// Returns nil for an empty or whitespace-only id rather than minting
    /// `https://www.getneutrino.app/open/note/`, which would land the recipient on a 404 in Safari.
    static func url(kind: Kind, fileID: String, contentVersion: Int? = nil) -> URL? {
        let id = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(pathPrefix)/\(kind.rawValue)/\(id)"
        if let contentVersion {
            components.queryItems = [URLQueryItem(name: versionQueryItem, value: String(contentVersion))]
        }
        return components.url
    }

    /// Convenience for the common case: "open this Drive file wherever it belongs".
    /// Returns nil when no Neutrino app claims the MIME type.
    static func url(forFileID fileID: String, mimeType: String?) -> URL? {
        guard let kind = kind(forMIME: mimeType) else { return nil }
        return url(kind: kind, fileID: fileID)
    }

    // MARK: - Parsing

    /// Parses an inbound Universal Link, or returns nil if it is not one of ours.
    ///
    /// Rejects anything that is not `https` on a Neutrino host under `/open/<kind>/<id>`; a
    /// malformed link is dropped rather than guessed at, because the only thing a guess could do is
    /// open the wrong file.
    static func destination(from url: URL) -> Destination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }

        let host = components.host?.lowercased() ?? ""
        guard host == Self.host || alternateHosts.contains(host) else { return nil }

        // `pathComponents` starts with "/" for an absolute path.
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 3, segments[0] == pathPrefix else { return nil }
        guard let kind = Kind(rawValue: segments[1]) else { return nil }

        let fileID = segments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return nil }

        let version = components.queryItems?
            .first { $0.name == versionQueryItem }
            .flatMap { $0.value }
            .flatMap { Int($0) }

        return Destination(kind: kind, fileID: fileID, contentVersion: version)
    }

    // MARK: - Routing

    /// The app that owns `mimeType`, or nil if no Neutrino editor claims it.
    ///
    /// `.file` is never returned: it means "Drive itself", which is a property of the link, not of
    /// the file's format.
    static func kind(forMIME mimeType: String?) -> Kind? {
        guard let mimeType else { return nil }
        // Servers append parameters (`; charset=utf-8`) and casing is not significant.
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !normalized.isEmpty else { return nil }

        return Kind.allCases.first { $0 != .file && $0.mimeTypes.contains(normalized) }
    }
}
