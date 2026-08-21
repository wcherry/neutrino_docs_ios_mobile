import CoreImage
import ImageIO
import UIKit

// MARK: - EditorImageStore

/// The pictures the editor is currently showing, keyed by the source they came from.
///
/// Layout asks for an image's size on every pass and drawing asks for the image itself on every
/// frame, so neither can afford to do the work more than once: both go through the cache here, and a
/// source that is not in it yet is loaded once. A failed source is remembered as failed so a broken
/// link is not re-fetched for the rest of the session.
///
/// The kinds of source load differently, and the difference matters to the caller. A Drive
/// reference and a link are both fetched in the background and answer nil until they arrive, with
/// `onLoad` asking for another layout pass then — the first answer is a guess and is meant to be
/// corrected. A `data:` URI is decoded there and then and answers with the picture, because there is
/// nothing to wait for and so nothing to announce later: were it to answer nil once, the line it
/// sits on would keep the height of a placeholder until something else happened to invalidate the
/// layout.
///
/// ## The three kinds
///
/// `neutrino-drive:<fileId>` is what a document written now holds — see ``DriveImageReference``.
/// Resolving it means downloading and decrypting a Drive file, which only ``resolveAttachment`` can
/// do; a store without one shows the failed placeholder rather than pretending to load forever.
/// `http(s):` and `data:` are what documents written before the change hold, and both still work.
@MainActor
final class EditorImageStore {

    /// Called when a source finishes loading, so the editor can lay out and draw again now that it
    /// knows how big the picture is.
    var onLoad: (() -> Void)?

    /// Downloads and decrypts a Drive file, given its id.
    ///
    /// Injected rather than reached for: this store is owned by a `UITextView`, which has no access
    /// to the app's services, and the whole point of the reference format is that the bytes come
    /// from somewhere only the signed-in session can read. `DocumentTextEditor` supplies it.
    var resolveAttachment: ((String) async throws -> Data)?

    private var images: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []
    private var tinted: [TintKey: UIImage] = [:]

    private struct TintKey: Hashable {
        let source: String
        let brightness: Double
        let contrast: Double
        let saturation: Double
    }

    // MARK: - Access

    /// The image for `source`, or nil while it is still being fetched — or for good, if it cannot
    /// be. Starts the fetch on the first miss.
    ///
    /// A `data:` URI is answered on that first call, not the next one. It has to be: the caller is
    /// usually layout deciding how tall the picture's line should be, and a "not yet" it gets while
    /// the bytes are already in hand sizes the line for a placeholder that nothing will correct — a
    /// synchronous decode has no arrival to announce through `onLoad`.
    func image(for source: String) -> UIImage? {
        if let image = images[source] { return image }
        guard !failed.contains(source), !loading.contains(source) else { return nil }
        load(source)
        return images[source]
    }

    /// The same picture with a tint applied, for an image the document says to brighten or desaturate.
    ///
    /// Filtering a photograph is far too slow to do on every frame, so the result is kept under the
    /// tint it was made with: change the tint and the old one is still there for undo, keep it and
    /// nothing is recomputed while the user scrolls.
    func image(for source: String, filter: ImageAttributes.Filter?) -> UIImage? {
        guard let base = image(for: source) else { return nil }
        guard let filter, !filter.isIdentity else { return base }

        let key = TintKey(source: source,
                          brightness: filter.brightness,
                          contrast: filter.contrast,
                          saturation: filter.saturation)
        if let cached = tinted[key] { return cached }

        let result = Self.applying(filter, to: base) ?? base
        tinted[key] = result
        return result
    }

    /// Whether a source has been tried and cannot be shown — what the editor draws a placeholder
    /// for rather than leaving a silent gap.
    func hasFailed(_ source: String) -> Bool { failed.contains(source) }

    /// CSS's `brightness`/`contrast`/`saturate` through Core Image's colour controls.
    ///
    /// Contrast and saturation mean the same thing in both, and are passed straight through. CSS
    /// brightness is a multiplier where 1 leaves the picture alone; Core Image's is an offset added
    /// to every channel, where 0 does — so 80% brightness becomes an offset of -0.2. It is an
    /// approximation of the web's rendering rather than a reproduction of it.
    private nonisolated static func applying(_ filter: ImageAttributes.Filter,
                                             to image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image),
              let colourControls = CIFilter(name: "CIColorControls") else { return nil }

        colourControls.setValue(input, forKey: kCIInputImageKey)
        colourControls.setValue(filter.brightness - 1, forKey: kCIInputBrightnessKey)
        colourControls.setValue(filter.contrast, forKey: kCIInputContrastKey)
        colourControls.setValue(filter.saturation, forKey: kCIInputSaturationKey)

        guard let output = colourControls.outputImage,
              let rendered = CIContext().createCGImage(output, from: input.extent) else {
            return nil
        }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Loading

    private func load(_ source: String) {
        // A `data:` URI carries its own bytes, so there is nothing to wait for. Decoding is still
        // real work on a photograph, so it happens once and the result is kept.
        if source.hasPrefix("data:") {
            if let image = Self.decodeDataURI(source) {
                images[source] = image
            } else {
                failed.insert(source)
            }
            return
        }

        if let fileID = DriveImageReference.fileID(from: source) {
            loadAttachment(fileID: fileID, source: source)
            return
        }

        guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else {
            failed.insert(source)
            return
        }

        loading.insert(source)
        Task { [weak self] in
            let image: UIImage? = await Self.fetch(url)
            self?.finish(source, with: image)
        }
    }

    /// Downloads and decrypts the Drive file a reference names.
    ///
    /// A store with no ``resolveAttachment`` cannot ever answer, so the source is marked failed
    /// immediately rather than left loading — a picture that will never arrive should draw its
    /// placeholder now, not hold a gap open for the rest of the session.
    private func loadAttachment(fileID: String, source: String) {
        guard let resolveAttachment else {
            failed.insert(source)
            return
        }

        loading.insert(source)
        Task { [weak self] in
            let image = await Self.decode { try await resolveAttachment(fileID) }
            self?.finish(source, with: image)
        }
    }

    /// Records the outcome of a background load and asks for another layout pass.
    private func finish(_ source: String, with image: UIImage?) {
        loading.remove(source)
        if let image {
            images[source] = image
        } else {
            failed.insert(source)
        }
        onLoad?()
    }

    /// Runs a fetch and turns whatever it returns into a picture, or nil.
    ///
    /// Every failure — offline, revoked access, a locked key vault, bytes that are not an image —
    /// lands on the same placeholder, because there is nothing the drawing can do differently about
    /// any of them.
    private nonisolated static func decode(_ fetch: () async throws -> Data) async -> UIImage? {
        guard let data = try? await fetch() else { return nil }
        return image(from: data)
    }

    // MARK: - Decoding

    /// Longest edge a picture is decoded at, in pixels.
    ///
    /// Comfortably more than the editor can draw — the text container is at most about a thousand
    /// points wide and a picture is capped at ``EditorTextView/maximumImageHeight`` tall — with room
    /// left for the properties panel and for a screen scale of three.
    static let maximumDecodedPixels: CGFloat = 2048

    /// Decodes `data` at no more than ``maximumDecodedPixels`` on its long edge.
    ///
    /// This is what makes storing originals affordable. Drive holds the picture at full resolution,
    /// but `UIImage(data:)` would hold *all* of it in memory to draw a thumbnail of it — about
    /// 48 MB of bitmap for a 12-megapixel photograph, so a document showing five of them would be
    /// killed for the memory before it finished drawing. ImageIO decodes straight to a bounded size
    /// without ever materialising the full bitmap, so the cost is the size on screen rather than
    /// the size on disk.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` is not optional: without it a photograph taken
    /// in portrait decodes sideways, because the rotation lives in the file's EXIF orientation
    /// rather than in its pixels.
    nonisolated static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDecodedPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            // A format ImageIO can read but not thumbnail is rare; fall back rather than lose the
            // picture over it.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return image(from: data)
    }

    /// Decodes `data:[<mime>][;base64],<payload>`.
    ///
    /// Pure, and deliberately reachable off the main actor: the insert-image sheet previews exactly
    /// what it is about to store by decoding the URI it just built.
    nonisolated static func decodeDataURI(_ source: String) -> UIImage? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[source.startIndex..<comma]
        let payload = String(source[source.index(after: comma)...])

        guard header.contains(";base64") else {
            // Percent-encoded rather than base64 — rare, but it is still a picture.
            guard let decoded = payload.removingPercentEncoding else { return nil }
            return image(from: Data(decoded.utf8))
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return image(from: data)
    }
}
