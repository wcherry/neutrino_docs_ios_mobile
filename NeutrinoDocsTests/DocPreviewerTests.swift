import XCTest
@testable import NeutrinoDocs

/// Page one's signature: what decides whether an edit redraws the document's Drive preview.
@MainActor
final class DocPreviewerTests: XCTestCase {

    private func paragraph(_ text: String) -> ProseMirrorNode {
        ProseMirrorNode(type: "paragraph", content: [ProseMirrorNode(type: "text", text: text)])
    }

    private func document(_ blocks: [ProseMirrorNode]) -> ProseMirrorNode {
        ProseMirrorNode(type: "doc", content: blocks)
    }

    /// Enough text to fill page one several times over.
    private var longDocument: [ProseMirrorNode] {
        (0..<200).map { paragraph("Paragraph \($0): " + String(repeating: "lorem ipsum ", count: 10)) }
    }

    func testAnEditFarBelowPageOneKeepsTheSignature() {
        var edited = longDocument
        edited[190] = paragraph("Rewritten near the end")
        XCTAssertEqual(DocPreviewer.signature(of: document(edited)),
                       DocPreviewer.signature(of: document(longDocument)))
    }

    func testAnEditOnPageOneChangesTheSignature() {
        var edited = longDocument
        edited[0] = paragraph("A new opening line")
        XCTAssertNotEqual(DocPreviewer.signature(of: document(edited)),
                          DocPreviewer.signature(of: document(longDocument)))
    }

    func testAShortDocumentIsAllPageOne() {
        let short = [paragraph("one"), paragraph("two")]
        XCTAssertNotEqual(DocPreviewer.signature(of: document(short + [paragraph("three")])),
                          DocPreviewer.signature(of: document(short)))
    }
}
