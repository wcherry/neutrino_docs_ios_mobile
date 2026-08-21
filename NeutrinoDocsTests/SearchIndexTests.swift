import XCTest
@testable import NeutrinoDocs

/// Phase 5 — Search. Covers the tokenizer, the inverted index, the field extraction, and the
/// filters. Everything here is pure: no store, no service, no network.
final class SearchIndexTests: XCTestCase {

    // MARK: - Tokenizer

    func testTokenizerLowercasesAndDropsPunctuation() {
        XCTAssertEqual(SearchTokenizer.words(in: "Hello, World! It's 2026."),
                       ["hello", "world", "it", "s", "2026"])
    }

    /// The rules have to agree with the web app's tokenizer, or the same query would mean
    /// different things on the two clients.
    func testTokenizerKeepsLettersAndNumbersOfAnyScript() {
        XCTAssertEqual(SearchTokenizer.words(in: "café — naïve — 42 — Ünicode"),
                       ["café", "naïve", "42", "ünicode"])
    }

    func testTokenizerRecordsEveryPositionOfATerm() {
        let terms = SearchTokenizer.tokenize("the cat and the hat")
        XCTAssertEqual(terms["the"], [0, 3])
        XCTAssertEqual(terms["cat"], [1])
    }

    func testShortQueryTermsAreDropped() {
        XCTAssertEqual(SearchTokenizer.queryPrefixes("a an the budget"), ["the", "budget"])
        XCTAssertTrue(SearchTokenizer.queryPrefixes("a an").isEmpty)
    }

    // MARK: - Indexing and matching

    func testAQueryMatchesAPrefixOfAnIndexedWord() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1"), fields: [.content: "the quarterly budget review"])
        index.prepareForQuerying()

        XCTAssertEqual(index.search("budg").map(\.documentID), ["d1"])
        XCTAssertEqual(index.search("budget").map(\.documentID), ["d1"])
        XCTAssertTrue(index.search("udget").isEmpty, "A prefix search must not match mid-word")
    }

    /// Multi-term queries are AND, matching the web engine: every term has to find something.
    func testEveryQueryTermMustMatch() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1"), fields: [.content: "quarterly budget review"])
        index.index(IndexFixture.document(id: "d2"), fields: [.content: "quarterly hiring plan"])
        index.prepareForQuerying()

        XCTAssertEqual(index.search("quarterly budget").map(\.documentID), ["d1"])
        XCTAssertEqual(Set(index.search("quarterly").map(\.documentID)), ["d1", "d2"])
        XCTAssertTrue(index.search("quarterly nonsense").isEmpty)
    }

    func testATitleMatchOutranksABodyMatch() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "body"), fields: [.content: "a passing mention of budget"])
        index.index(IndexFixture.document(id: "titled", title: "Budget"), fields: [.title: "Budget"])
        index.prepareForQuerying()

        XCTAssertEqual(index.search("budget").map(\.documentID), ["titled", "body"])
    }

    func testAHeadingMatchOutranksABodyMatch() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "body"), fields: [.content: "mentions onboarding once"])
        index.index(IndexFixture.document(id: "heading"), fields: [.heading: "Onboarding"])
        index.prepareForQuerying()

        XCTAssertEqual(index.search("onboarding").map(\.documentID), ["heading", "body"])
    }

    func testTheMatchedFieldsAreReported() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1", title: "Budget"),
                    fields: [.title: "Budget", .content: "the budget again", .tag: "finance"])
        index.prepareForQuerying()

        let result = try? XCTUnwrap(index.search("budget").first)
        XCTAssertEqual(result?.matchedFields, [.title, .content])
    }

    /// Re-indexing has to retract the old terms, or a word the user deleted keeps finding the
    /// document forever.
    func testReindexingDropsTermsTheDocumentNoLongerHas() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1"), fields: [.content: "confidential merger talks"])
        index.index(IndexFixture.document(id: "d1"), fields: [.content: "office snack rota"])
        index.prepareForQuerying()

        XCTAssertTrue(index.search("merger").isEmpty)
        XCTAssertEqual(index.search("snack").map(\.documentID), ["d1"])
        XCTAssertEqual(index.documentCount, 1, "Re-indexing must not duplicate the document")
    }

    func testRemovingADocumentRemovesItsTerms() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1"), fields: [.content: "unique keyword"])
        index.remove(documentID: "d1")
        index.prepareForQuerying()

        XCTAssertTrue(index.search("keyword").isEmpty)
        XCTAssertTrue(index.isEmpty)
    }

    func testTiesBreakOnRecency() {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "old", modifiedAt: older), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "new", modifiedAt: newer), fields: [.content: "report"])
        index.prepareForQuerying()

        XCTAssertEqual(index.search("report").map(\.documentID), ["new", "old"])
    }

    func testTheIndexSurvivesEncodingAndDecoding() throws {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1", title: "Notes"), fields: [.content: "persisted text"])

        let data = try JSONEncoder().encode(index)
        var restored = try JSONDecoder().decode(SearchIndex.self, from: data)
        restored.prepareForQuerying()

        XCTAssertEqual(restored.search("persisted").map(\.documentID), ["d1"])
        XCTAssertEqual(restored.document(id: "d1")?.title, "Notes")
    }

    // MARK: - Filters

    func testTheOwnerFilterSeparatesMineFromShared() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "mine", isShared: false), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "theirs", isShared: true), fields: [.content: "report"])
        index.prepareForQuerying()

        var filters = SearchFilters()
        filters.ownership = .mine
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["mine"])

        filters.ownership = .shared
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["theirs"])
    }

    func testTheFolderFilterRestrictsToTheGivenFolders() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "inside", folderID: "f1"), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "outside", folderID: "f2"), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "root", folderID: nil), fields: [.content: "report"])
        index.prepareForQuerying()

        var filters = SearchFilters()
        filters.folderIDs = ["f1"]
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["inside"])
    }

    func testTheModifiedFilterBoundsBothEnds() {
        let january = Date(timeIntervalSince1970: 1_700_000_000)
        let june = Date(timeIntervalSince1970: 1_750_000_000)
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "jan", modifiedAt: january), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "jun", modifiedAt: june), fields: [.content: "report"])
        index.prepareForQuerying()

        var filters = SearchFilters()
        filters.modifiedAfter = january.addingTimeInterval(1)
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["jun"])

        filters = SearchFilters()
        filters.modifiedBefore = june.addingTimeInterval(-1)
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["jan"])
    }

    /// Selecting two tags means both, not either — the narrowing a filter is for.
    func testTheTagFilterRequiresEverySelectedTag() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "both", tags: ["swift", "ios"]), fields: [.content: "report"])
        index.index(IndexFixture.document(id: "one", tags: ["swift"]), fields: [.content: "report"])
        index.prepareForQuerying()

        var filters = SearchFilters()
        filters.tags = ["swift", "ios"]
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["both"])

        filters.tags = ["swift"]
        XCTAssertEqual(Set(index.search("report", filters: filters).map(\.documentID)), ["both", "one"])
    }

    func testTagsAreMatchedWithoutRegardToCase() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1", tags: ["Swift"]), fields: [.content: "report"])
        index.prepareForQuerying()

        var filters = SearchFilters()
        filters.tags = ["swift"]
        XCTAssertEqual(index.search("report", filters: filters).map(\.documentID), ["d1"])
    }

    /// Filters alone, with no query, list what matches — how the tag and folder pickers browse.
    func testBrowsingByFilterAloneReturnsMatchesNewestFirst() {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "old", tags: ["x"], modifiedAt: older), fields: [:])
        index.index(IndexFixture.document(id: "new", tags: ["x"], modifiedAt: newer), fields: [:])
        index.index(IndexFixture.document(id: "other", tags: ["y"], modifiedAt: newer), fields: [:])

        var filters = SearchFilters()
        filters.tags = ["x"]
        XCTAssertEqual(index.browse(filters: filters).map(\.documentID), ["new", "old"])
    }

    func testAllTagsIsDeduplicatedAndSorted() {
        var index = SearchIndex()
        index.index(IndexFixture.document(id: "d1", tags: ["swift", "ios"]), fields: [:])
        index.index(IndexFixture.document(id: "d2", tags: ["Swift", "api"]), fields: [:])

        XCTAssertEqual(index.allTags, ["api", "ios", "swift"])
    }

    // MARK: - Field extraction

    func testTheTitleComesFromFrontMatterWhenThereIsOne() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.frontMatter("title: Quarterly Review"),
                                   Doc.heading(1, "Something else")),
            fileName: "untitled.md"
        )
        XCTAssertEqual(content.title, "Quarterly Review")
    }

    /// A document's name is its title, so it is used as it is.
    func testTheTitleFallsBackToTheDocumentsName() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.heading(1, "Heading")),
            fileName: "Report"
        )
        XCTAssertEqual(content.title, "Report")
    }

    func testHeadingsAndTagsAreExtracted() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.frontMatter("title: Notes\ntags: [swift, ios]"),
                                   Doc.heading(1, "First"),
                                   Doc.paragraph("Body text."),
                                   Doc.heading(2, "Second")),
            fileName: "n.md"
        )

        XCTAssertEqual(content.headings, ["First", "Second"])
        XCTAssertEqual(content.tags, ["swift", "ios"])
    }

    /// A search for "class" should find the document about classes, not every document with a code
    /// sample in it.
    func testCodeBlocksAreNotIndexed() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.paragraph("Prose about deployment."),
                                   Doc.codeBlock("final class Reticulator {}", language: "swift")),
            fileName: "n.md"
        )

        XCTAssertTrue(content.content.contains("deployment"))
        XCTAssertFalse(content.content.contains("Reticulator"))
    }

    /// There is no syntax to strip: what a paragraph says is its text, whatever marks are on it.
    func testEmphasisedTextIsIndexedAsTheWordsItIs() {
        let bold = ProseMirrorNode.text("bold", marks: [ProseMirrorMark(type: DocumentMarkType.bold)])
        let paragraph = ProseMirrorNode.paragraph([.text("Some "), bold, .text(" text.")])
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.heading(1, "Title"), paragraph),
            fileName: "n.md"
        )

        XCTAssertFalse(content.content.contains("*"))
        XCTAssertFalse(content.content.contains("#"))
        XCTAssertTrue(content.content.contains("bold"))
    }

    /// Someone searching for a word means the word in the sentence, not a URL that happens to
    /// contain it.
    func testALinksTextIsIndexedAndItsDestinationIsNot() {
        let link = ProseMirrorNode.text(
            "the pricing page",
            marks: [ProseMirrorMark(type: DocumentMarkType.link,
                                    attrs: ["href": .string("https://example.com/secretpath")])]
        )
        let content = DocumentSearchContent.extract(
            document: Doc.document(.paragraph([.text("See "), link, .text(".")])),
            fileName: "n.md"
        )

        XCTAssertTrue(content.content.contains("pricing"))
        XCTAssertFalse(content.content.contains("secretpath"))
    }

    func testFrontMatterIsNotIndexedAsBodyText() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.frontMatter("title: Notes\nauthor: Ana"),
                                   Doc.paragraph("Body.")),
            fileName: "n.md"
        )
        XCTAssertFalse(content.content.contains("author"))
        XCTAssertEqual(content.content, "Body.")
    }

    func testThePreviewIsBoundedAndCutAtAWord() {
        let long = String(repeating: "word ", count: 200)
        let content = DocumentSearchContent.extract(document: Doc.document(Doc.paragraph(long)),
                                                    fileName: "n.md")

        XCTAssertLessThanOrEqual(content.preview.count, IndexedDocument.previewLimit + 1)
        XCTAssertTrue(content.preview.hasSuffix("…"))
    }

    /// Headings are deliberately counted in both fields, which is what makes a document whose
    /// heading is about the query outrank one that merely mentions it.
    func testHeadingsAreCountedInBothTheHeadingAndContentFields() {
        let content = DocumentSearchContent.extract(
            document: Doc.document(Doc.heading(1, "Onboarding"), Doc.paragraph("Text.")),
            fileName: "n.md"
        )
        XCTAssertEqual(content.headings, ["Onboarding"])
        XCTAssertTrue(content.content.contains("Onboarding"))
    }

    // MARK: - Fixture

    private enum IndexFixture {
        static func document(id: String,
                             title: String = "Untitled",
                             tags: [String] = [],
                             folderID: String? = nil,
                             isShared: Bool = false,
                             modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> IndexedDocument {
            IndexedDocument(id: id, title: title, preview: "", tags: tags, folderID: folderID,
                            isShared: isShared, modifiedAt: modifiedAt, indexedAt: modifiedAt)
        }
    }
}
