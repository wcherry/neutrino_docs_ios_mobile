import PDFKit
import UIKit
import XCTest
import NeutrinoPrint
@testable import NeutrinoDocs

/// Printing a document: what lands on paper, and that its pictures are in hand before the pages are
/// drawn. The pagination, header and page numbers themselves are NeutrinoPrint's and tested there.
@MainActor
final class DocumentPrintTests: XCTestCase {

    // MARK: - Helpers

    private let font = UIFont.systemFont(ofSize: 17)

    private func picture() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }.pngData()!
    }

    private func image(_ source: String) -> ProseMirrorNode {
        ProseMirrorNode(type: "image", attrs: ["src": .string(source)])
    }

    private func list(_ type: String, _ items: [String]) -> ProseMirrorNode {
        ProseMirrorNode(type: type, content: items.map {
            ProseMirrorNode(type: "listItem", content: [.paragraph([.text($0)])])
        })
    }

    private func pdfText(_ job: PrintJob) -> String {
        let pdf = NeutrinoPrintPageRenderer(job: job).pdfData()
        guard let document = PDFDocument(data: pdf) else { return "" }
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    private func pageCount(_ job: PrintJob) -> Int {
        PDFDocument(data: NeutrinoPrintPageRenderer(job: job).pdfData())?.pageCount ?? -1
    }

    // MARK: - The job

    func testTheJobIsNamedAndHeadedAfterTheDocument() async {
        let doc = ProseMirrorNode(type: "doc", content: [.paragraph([.text("Hello")])])
        let job = await DocumentPrint.job(for: doc, title: "Board minutes", bodyFont: font,
                                          resolveAttachment: nil)

        XCTAssertEqual(job.name, "Board minutes")
        XCTAssertEqual(job.header, "Board minutes")
        XCTAssertTrue(pdfText(job).contains("Hello"))
    }

    func testALongDocumentRunsOntoSeveralPages() async {
        let paragraph = ProseMirrorNode.paragraph([.text(String(repeating: "Lorem ipsum dolor sit amet. ",
                                                                count: 12))])
        let doc = ProseMirrorNode(type: "doc", content: Array(repeating: paragraph, count: 80))
        let job = await DocumentPrint.job(for: doc, title: "Long", bodyFont: font,
                                          resolveAttachment: nil)

        XCTAssertGreaterThan(pageCount(job), 1)
    }

    /// List numbers are drawn from the document's structure, not stored in its text — so this is
    /// the decorations reaching the paper.
    func testListNumbersArePrinted() async {
        let doc = ProseMirrorNode(type: "doc", content: [
            list("orderedList", ["First", "Second", "Third"]),
        ])
        let job = await DocumentPrint.job(for: doc, title: "List", bodyFont: font,
                                          resolveAttachment: nil)
        let text = pdfText(job)

        for marker in ["1.", "2.", "3."] {
            XCTAssertTrue(text.contains(marker), "missing \(marker) in \(text)")
        }
    }

    func testTheEditorFontSizeDoesNotReachThePaper() async {
        let doc = ProseMirrorNode(type: "doc", content: [.paragraph([.text("Body")])])
        let job = await DocumentPrint.job(for: doc, title: "a",
                                          bodyFont: .systemFont(ofSize: 34),
                                          resolveAttachment: nil)

        guard case .pages(let source) = job.content else { return XCTFail("expected pages") }
        var size: CGFloat?
        (source as? AttributedTextPageSource)?.drawBehindText = { page in
            let storage = page.layoutManager.textStorage
            size = (storage?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
        }
        _ = NeutrinoPrintPageRenderer(job: job).pdfData()

        XCTAssertEqual(size, DocumentPrint.bodyPointSize)
    }

    // MARK: - Pictures

    func testPicturesAreFetchedBeforeThePagesAreDrawn() async {
        var asked: [String] = []
        let bytes = picture()
        let doc = ProseMirrorNode(type: "doc", content: [
            image(DriveImageReference.source(fileID: "img-1")),
            .paragraph([.text("Caption text")]),
        ])

        let job = await DocumentPrint.job(for: doc, title: "a", bodyFont: font) { fileID in
            asked.append(fileID)
            return bytes
        }

        XCTAssertEqual(asked, ["img-1"])
        guard case .pages(let source) = job.content else { return XCTFail("expected pages") }
        var attachment: DocumentImageAttachment?
        (source as? AttributedTextPageSource)?.drawBehindText = { page in
            attachment = page.layoutManager.textStorage?
                .attribute(.attachment, at: 0, effectiveRange: nil) as? DocumentImageAttachment
        }
        _ = NeutrinoPrintPageRenderer(job: job).pdfData()

        // Sized from the picture, not from the loading placeholder's column-wide box.
        let size = attachment?.renderedSize(availableWidth: 400)
        XCTAssertEqual(size?.width ?? 0, 20, accuracy: 0.5)
    }

    func testImageSourcesAreListedInDocumentOrder() {
        let doc = ProseMirrorNode(type: "doc", content: [
            image("https://example.com/a.png"),
            .paragraph([.text("between")]),
            image(DriveImageReference.source(fileID: "b")),
        ])
        let text = DocumentProjection.attributedString(from: doc,
                                                       style: DocumentStyle(bodyFont: font))

        XCTAssertEqual(DocumentImageAttachment.imageSources(in: text),
                       ["https://example.com/a.png", DriveImageReference.source(fileID: "b")])
    }

    func testPreloadReportsAFailedFetchAsFailed() async {
        let store = EditorImageStore()
        store.resolveAttachment = { _ in throw URLError(.notConnectedToInternet) }
        let source = DriveImageReference.source(fileID: "gone")

        await store.preload([source])

        XCTAssertTrue(store.hasFailed(source))
    }

    func testPreloadWithNoResolverFailsAReference() async {
        let store = EditorImageStore()
        let source = DriveImageReference.source(fileID: "x")

        await store.preload([source])

        XCTAssertTrue(store.hasFailed(source))
    }

    func testAResolvedAttachmentWithNoPictureDrawsAsFailed() {
        let attachment = DocumentImageAttachment(source: "x", attributes: ImageAttributes(proseMirror: nil),
                                                 resolvedImage: nil)
        // The placeholder is the column's width; the picture would have been its own.
        XCTAssertEqual(attachment.renderedSize(availableWidth: 300).width, 300)
    }

    // MARK: - Line ranges

    func testLineRangesIncludeTheirSeparator() {
        let text = NSAttributedString(string: "ab\n\ncd")
        XCTAssertEqual(DocumentPrint.lineRanges(in: text), [
            NSRange(location: 0, length: 3),
            NSRange(location: 3, length: 1),
            NSRange(location: 4, length: 2),
        ])
    }
}
