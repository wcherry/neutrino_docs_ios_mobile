import Foundation
import os.log

// MARK: - DeepLinkRouter

/// Holds the document an inbound Universal Link asked for until the app is in a state to open it.
///
/// `https://www.getneutrino.app/open/doc/<file id>` is how Drive (or an email, or the web app)
/// hands a document to this app. Only the id travels; the document itself is fetched from the
/// server here, so the reader always gets the current version and permissions stay server-side.
///
/// A link can land at any moment — including a cold launch straight onto the login screen, or while
/// the biometric lock overlay is up. Rather than teach the open path about those states, the router
/// just remembers the destination and the view layer picks it up once the user is signed in. That
/// is also why nothing but `consume()` clears `pending`: a link that arrives before sign-in has to
/// survive the whole login round trip.
@MainActor
final class DeepLinkRouter: ObservableObject {

    // MARK: - State

    /// The document waiting to be opened, if any.
    @Published private(set) var pending: NeutrinoAppLink.Destination?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "DeepLinkRouter")

    // MARK: - Init

    init(pending: NeutrinoAppLink.Destination? = nil) {
        self.pending = pending
    }

    // MARK: - Inbound

    /// Records `url` if it is a Neutrino document link.
    ///
    /// Returns false for every other kind. A `/open/note/…` link belongs to Neutrino Notes — the
    /// two apps store different formats behind similar-looking Markdown, and opening one here would
    /// either fail to decode or, worse, silently show the wrong thing. In practice iOS never
    /// delivers one, because the `apple-app-site-association` document routes only `/open/doc/*` to
    /// this bundle id; the check exists because a URL can also arrive by paste or from another app.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let destination = NeutrinoAppLink.destination(from: url) else { return false }
        guard destination.kind == .doc else {
            logger.debug("ignoring app link for kind=\(destination.kind.rawValue, privacy: .public)")
            return false
        }
        logger.debug("accepted document link file=\(destination.fileID, privacy: .public)")
        pending = destination
        return true
    }

    /// Returns the pending destination and clears it, so a document that is already being opened is
    /// not opened a second time when the view tree re-evaluates.
    func consume() -> NeutrinoAppLink.Destination? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }
}
