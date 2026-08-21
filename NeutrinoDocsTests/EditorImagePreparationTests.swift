import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import NeutrinoDocs

/// What gets uploaded when a picture is inserted.
///
/// The rule is the web app's: the original goes to Drive as it arrived, at its own resolution and
/// in its own format. Drive holds the picture somebody actually has rather than this app's idea of
/// a reasonable one, so a document opened on a desktop shows the full-quality image.
///
/// HEIC is the single exception, and the reason is interoperability rather than size: it is what an
/// iPhone camera writes and what most browsers cannot display, so a photo stored as it came would
/// render here and nowhere else — including in the web editor reading the same file.
final class EditorImagePreparationTests: XCTestCase {

    // MARK: - Fixtures

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
    }

    /// Encodes to a specific container, so the passthrough can be asserted per format.
    private func encoded(_ image: UIImage, as type: UTType) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: - The original is what gets stored

    func testAJPEGIsUploadedByteForByte() throws {
        let original = try encoded(image(width: 300, height: 200), as: .jpeg)

        let prepared = try EditorImage.prepared(original)

        XCTAssertEqual(prepared.data, original, "the bytes the user chose are the bytes stored")
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpeg")
    }

    /// The old path re-encoded everything to JPEG, which threw away a screenshot's transparency
    /// and its sharp edges.
    func testAPNGStaysAPNG() throws {
        let original = try encoded(image(width: 300, height: 200), as: .png)

        let prepared = try EditorImage.prepared(original)

        XCTAssertEqual(prepared.data, original)
        XCTAssertEqual(prepared.mimeType, "image/png")
        XCTAssertEqual(prepared.fileExtension, "png")
    }

    func testAGIFStaysAGIF() throws {
        let original = try encoded(image(width: 40, height: 40), as: .gif)

        let prepared = try EditorImage.prepared(original)

        XCTAssertEqual(prepared.data, original)
        XCTAssertEqual(prepared.mimeType, "image/gif")
    }

    /// The whole point of the change: a photograph is not reduced to 1280px on its long edge.
    func testAFullResolutionPhotoKeepsEveryPixel() throws {
        let original = try encoded(image(width: 4032, height: 3024), as: .jpeg)

        let prepared = try EditorImage.prepared(original)

        XCTAssertEqual(prepared.data, original)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 4032)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 3024)
    }

    /// There is no ceiling on the upload path. The old one existed because the bytes rode inside
    /// the document body; a Drive file is written once and is not part of the document.
    func testALargePictureIsNotRefused() throws {
        // Noise, so the encoder cannot compress it back under the old limit — a flat colour at any
        // resolution is a few hundred kilobytes of PNG and would not test the thing.
        let original = try encoded(noise(width: 1200, height: 1200), as: .png)
        XCTAssertGreaterThan(original.count, EditorImage.maximumEncodedBytes)

        let prepared = try EditorImage.prepared(original)
        XCTAssertEqual(prepared.data, original)
    }

    /// A picture of incompressible pixels, built directly rather than drawn: filling a million
    /// rectangles through a renderer takes long enough to notice.
    private func noise(width: Int, height: Int) throws -> UIImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for index in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8((seed >> 33) & 0xFF)
        }

        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return UIImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    // MARK: - HEIC

    func testHEICIsConvertedToJPEGAtFullResolution() throws {
        // Not every simulator can *encode* HEIC; skip rather than fail on a machine that cannot.
        guard let heic = try? encoded(image(width: 1600, height: 1200), as: .heic),
              !heic.isEmpty else {
            throw XCTSkip("This runtime cannot encode HEIC")
        }

        let prepared = try EditorImage.prepared(heic)

        XCTAssertEqual(prepared.mimeType, "image/jpeg", "browsers cannot show HEIC")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertNotEqual(prepared.data, heic)

        // Converted, not shrunk.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1200)
    }

    // MARK: - Rejections

    func testSomethingThatIsNotAnImageIsRejected() {
        XCTAssertThrowsError(try EditorImage.prepared(Data("not a picture".utf8)))
        XCTAssertThrowsError(try EditorImage.prepared(Data()))
    }

    // MARK: - Naming

    func testTheFileNameCarriesTheStoredFormatsExtension() {
        XCTAssertEqual(EditorImage.fileName(from: "holiday.heic", extension: "jpg"), "holiday.jpg")
        XCTAssertEqual(EditorImage.fileName(from: "diagram.png", extension: "png"), "diagram.png")
    }

    func testASourceWithNoNameStillGetsOne() {
        XCTAssertEqual(EditorImage.fileName(from: nil, extension: "png"), "Image.png")
        XCTAssertEqual(EditorImage.fileName(from: "   ", extension: "jpeg"), "Image.jpeg")
    }
}
