import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - EditorImage

/// Prepares a picture for upload into Drive.
///
/// A document stores a reference to a Drive file rather than the picture itself — see
/// ``DriveImageReference`` — so what this produces is the bytes that get uploaded, not something
/// that goes in the document.
///
/// ## The original is what gets stored
///
/// The bytes go up as they arrived, at the resolution and in the format the user chose, which is
/// what the web app does. Drive holds the picture somebody actually has rather than this app's idea
/// of a reasonable one, so a document opened on a desktop shows the full-quality image and an
/// export is not working from a phone-sized copy.
///
/// Nothing is resized here, so the memory that used to be saved by resizing is saved at the other
/// end instead: `EditorImageStore` decodes to a bounded size rather than to the file's own, which
/// is the technique that makes storing originals safe on a phone. Downscaling before upload would
/// have thrown the pixels away for good; downsampling at decode only declines to hold them.
///
/// ## The one exception
///
/// HEIC is converted to JPEG. It is what an iPhone camera writes and what most browsers cannot
/// display, so storing it as it came would mean a picture inserted here rendering nowhere else —
/// including in the web editor that reads the same file. The conversion keeps full resolution.
enum EditorImage {

    // MARK: - Errors

    enum Failure: LocalizedError {
        case unreadable
        case tooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't an image this app can read."
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "That image is \(size), which is too large to add to a document."
            }
        }
    }

    // MARK: - Preparing for upload

    /// A picture as it will be stored in Drive.
    struct Prepared: Equatable {
        let data: Data
        /// What the bytes actually are, for the Drive file's metadata.
        let mimeType: String
        /// The matching extension, so the stored file is named for what it holds.
        let fileExtension: String
    }

    /// Quality for the HEIC conversion. High enough that the result is visually the original;
    /// this is a format change, not a size reduction.
    static let transcodeQuality: CGFloat = 0.9

    /// Reads what `data` is and returns the bytes to upload, converting only when the format is one
    /// the other clients could not display.
    static func prepared(_ data: Data) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image) else {
            throw Failure.unreadable
        }

        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: transcodeQuality) else {
                throw Failure.unreadable
            }
            return Prepared(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg")
        }

        return Prepared(data: data,
                        mimeType: type.preferredMIMEType ?? "image/*",
                        fileExtension: type.preferredFilenameExtension ?? "img")
    }

    // MARK: - The preview Drive shows

    /// Longest edge of the preview stored alongside an uploaded picture, in pixels. The web app's
    /// `generateThumbnail` uses the same 512, so a picture inserted here and one inserted there are
    /// the same size in the grid.
    static let thumbnailMaximumPixels: CGFloat = 512

    /// JPEG quality for that preview, again the web app's.
    static let thumbnailQuality: CGFloat = 0.8

    /// A small JPEG of `data`, base64-encoded without a `data:` prefix — what Drive's upload
    /// endpoint takes as `thumbnail_b64`.
    ///
    /// The server cannot make this itself: what it receives is ciphertext, and the key never leaves
    /// the device. So a picture uploaded without one has no preview anywhere a preview is shown —
    /// the Drive grid, the web app's image picker — and appears as a generic file icon while every
    /// picture inserted from the web app shows its contents.
    ///
    /// JPEG because `set_cover_thumbnail` records the type as `image/jpeg` regardless of what is
    /// sent, so anything else would be stored under a lie. Transparency is lost, which is the right
    /// trade for a thumbnail; the stored picture itself keeps its own format.
    ///
    /// Decoded through ImageIO at a bounded size rather than through `UIImage`, for the reason given
    /// in ``EditorImageStore/image(from:)``: a 12-megapixel photograph is about 48 MB of bitmap, and
    /// none of it is needed to draw 512 pixels. Answers nil rather than throwing — a picture whose
    /// preview could not be made is still a picture worth uploading.
    nonisolated static func thumbnailBase64(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Without this a photograph taken in portrait is previewed sideways: the rotation is in
            // the file's EXIF orientation, and a re-encoded thumbnail does not carry that tag on.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: thumbnailQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (jpeg as Data).base64EncodedString()
    }

    /// A file name for an uploaded picture, carrying the extension its bytes actually have.
    ///
    /// `suggestion` is whatever the source knew — a filename, the last path component of a URL —
    /// and is used for its stem only, since the extension has to describe what was stored.
    static func fileName(from suggestion: String?, extension fileExtension: String) -> String {
        let stem = (suggestion.map { ($0 as NSString).deletingPathExtension } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "Image" : stem) + "." + fileExtension
    }

    // MARK: - The format documents used to be written in

    /// Longest edge a picture was reduced to before being inlined.
    static let maximumDimension: CGFloat = 1280

    /// JPEG quality used by the inline encoder.
    static let compressionQuality: CGFloat = 0.7

    /// The ceiling an inlined picture had to stay under, since it rode inside the document body and
    /// was re-uploaded on every autosave. Nothing enforces it on the upload path: a Drive file is
    /// written once and is not part of the document.
    static let maximumEncodedBytes = 2 * 1024 * 1024

    /// Downscales and re-encodes `image` the way the inline format did.
    static func encoded(_ image: UIImage) throws -> Data {
        guard let jpeg = downscaled(image).jpegData(compressionQuality: compressionQuality) else {
            throw Failure.unreadable
        }
        guard jpeg.count <= maximumEncodedBytes else { throw Failure.tooLarge(bytes: jpeg.count) }
        return jpeg
    }

    /// The same, from bytes that arrived already encoded.
    static func encoded(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else { throw Failure.unreadable }
        return try encoded(image)
    }

    /// A `data:` URI holding the picture.
    ///
    /// Nothing on the insertion path writes one any more: a document references a Drive file. This
    /// remains because documents written before that format still hold inline pictures and are
    /// still read, and it is how those documents are built in tests.
    static func dataURI(from image: UIImage) throws -> String {
        "data:image/jpeg;base64," + (try encoded(image)).base64EncodedString()
    }

    /// The same, from bytes that arrived already encoded.
    static func dataURI(from data: Data) throws -> String {
        "data:image/jpeg;base64," + (try encoded(from: data)).base64EncodedString()
    }

    // MARK: - Scaling

    /// `image` with its longest edge no greater than ``maximumDimension``, preserving the aspect
    /// ratio. Returned unchanged when it is already small enough — re-encoding a thumbnail only
    /// costs it quality.
    static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maximumDimension, longest > 0 else { return image }

        let scale = maximumDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        let renderer = UIGraphicsImageRenderer(size: target, format: {
            let format = UIGraphicsImageRendererFormat.default()
            // The source is already in pixels; rendering at the screen's scale would multiply the
            // result back up to where it started.
            format.scale = 1
            return format
        }())
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The size a scaled image would come out at, without doing the scaling. Split out so the rule
    /// can be asserted directly.
    static func scaledSize(for size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maximumDimension, longest > 0 else { return size }
        let scale = maximumDimension / longest
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }
}
