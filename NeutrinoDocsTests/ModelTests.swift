import XCTest
import NeutrinoCore
@testable import NeutrinoDocs

// MARK: - DocItemTests

/// Supports **Browse Drive**: the rules that decide what appears in a listing and how it reads.
final class DocItemTests: XCTestCase {

    /// A document's title is its file name with the `.docx` taken off — and a name that never had
    /// one is a title already.
    func testDisplayNameShowsTheTitleRatherThanTheFileName() {
        XCTAssertEqual(Fixture.doc(name: "Untitled document.docx").displayName, "Untitled document")
        XCTAssertEqual(Fixture.doc(name: "Roadmap v1.2.docx").displayName, "Roadmap v1.2")
        XCTAssertEqual(Fixture.doc(name: "Untitled document").displayName, "Untitled document")
    }

    /// Only the extension a Neutrino document actually has is hidden. Every other dot in a name is
    /// part of the title.
    func testDisplayNameHidesOnlyTheDocxExtension() {
        XCTAssertEqual(Fixture.doc(name: "Report.md").displayName, "Report.md")
        XCTAssertEqual(Fixture.doc(name: "archive.tar.gz").displayName, "archive.tar.gz")
        XCTAssertEqual(Fixture.doc(name: "README").displayName, "README")
        // A dotfile's leading dot is not an extension marker.
        XCTAssertEqual(Fixture.doc(name: ".hidden").displayName, ".hidden")
    }

    // MARK: - The stored format

    private static let docx =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private func word(name: String, id: String = "w1") -> DocItem {
        DocItem(id: id, name: name, type: .file, parentID: nil, size: 128,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isTrashed: false,
                mimeType: Self.docx)
    }

    /// A Neutrino document is a Word document, and nothing else is one.
    func testOnlyAWordDocumentCountsAsADocument() {
        XCTAssertTrue(DocItem.isDocument(Self.docx))
        XCTAssertFalse(DocItem.isDocument("application/x-neutrino-doc"))
        XCTAssertFalse(DocItem.isDocument("application/x-neutrino-sheet"))
        XCTAssertFalse(DocItem.isDocument("text/csv"))
        XCTAssertFalse(DocItem.isDocument(nil))
    }

    /// Every document this app lists is one it can open; a folder is not.
    func testADocumentIsEditableAndAFolderIsNot() {
        XCTAssertTrue(word(name: "Spec.docx").isEditable)
        XCTAssertTrue(Fixture.doc(name: "Spec.docx").isEditable)
        XCTAssertFalse(Fixture.folder(name: "Projects").isEditable)
    }

    /// The extension is part of the *file* name — a `.docx` has to land on disk as one to open on
    /// a double-click — but the document is called "Report", as the web library also shows it.
    func testTheDocxExtensionIsHiddenFromTheTitle() {
        XCTAssertEqual(word(name: "Report.docx").displayName, "Report")
        XCTAssertEqual(word(name: "Report").displayName, "Report")
        // Only the real extension goes: a title that merely mentions it keeps every character.
        XCTAssertEqual(word(name: "About .docx files.docx").displayName, "About .docx files")
    }

    func testFolderNamesAreNeverTruncated() {
        XCTAssertEqual(Fixture.folder(name: "v1.2").displayName, "v1.2")
        XCTAssertEqual(Fixture.folder(name: "notes").displayName, "notes")
    }

    /// The copy suffix goes on the *title*, and the extension goes back on the end — `Report.docx
    /// copy` is a file the operating system no longer recognises.
    func testDuplicateNameAppendsCopyToTheTitle() {
        XCTAssertEqual(Fixture.doc(name: "Report.docx").duplicateName, "Report copy.docx")
        // The dot belongs to the title, so the copy suffix goes after it.
        XCTAssertEqual(Fixture.doc(name: "Roadmap v1.2.docx").duplicateName, "Roadmap v1.2 copy.docx")
    }

    func testDuplicateNameGivesANameWithNoExtensionOne() {
        XCTAssertEqual(Fixture.doc(name: "Report").duplicateName, "Report copy.docx")
        XCTAssertEqual(Fixture.doc(name: "a.b").duplicateName, "a.b copy.docx")
    }

    func testIconsDistinguishFoldersFromDocuments() {
        XCTAssertEqual(Fixture.folder().iconName, "folder.fill")
        XCTAssertEqual(Fixture.doc().iconName, "doc.text.fill")
    }
}

// MARK: - DocsSectionTests

final class DocsSectionTests: XCTestCase {

    /// Only Home navigates into folders. Recent and Favorites deliberately cut across the tree, and
    /// Shared is flat by necessity — Drive's folder listings are owner-scoped, so somebody else's
    /// folder cannot be enumerated at all.
    func testOnlyHomeSupportsFolderNavigation() {
        XCTAssertTrue(DocsSection.home.supportsFolderNavigation)
        for section in [DocsSection.recent, .favorites, .shared, .trash] {
            XCTAssertFalse(section.supportsFolderNavigation, section.rawValue)
        }
    }

    func testEverySectionHasAnIconAndEmptyMessage() {
        for section in DocsSection.allCases {
            XCTAssertFalse(section.iconName.isEmpty, section.rawValue)
            XCTAssertFalse(section.emptyMessage.isEmpty, section.rawValue)
        }
    }

    func testSectionsCoverThePhaseOneBrowseList() {
        // Phase 1 — Drive Integration, "Browse Drive": Home, Recent, Favorites, Shared.
        let names = Set(DocsSection.allCases.map(\.rawValue))
        XCTAssertTrue(names.isSuperset(of: ["Home", "Recent", "Favorites", "Shared"]))
    }

    /// Recent is a newest-first listing by definition — sorting it A–Z until asked would throw away
    /// the point of the section. Every other section reads as a file browser does.
    func testRecentDefaultsToNewestAndEveryOtherSectionToAToZ() {
        XCTAssertEqual(DocsSection.recent.defaultSortOrder, .newest)
        for section in [DocsSection.home, .favorites, .shared, .trash] {
            XCTAssertEqual(section.defaultSortOrder, .nameAscending, section.rawValue)
        }
    }
}

// MARK: - DocSortOrderTests

/// Supports **Browse Drive**: the four orders the browser's sort menu offers.
final class DocSortOrderTests: XCTestCase {

    private static let jan1 = Date(timeIntervalSince1970: 1_700_000_000)

    private func doc(_ name: String, _ daysLater: TimeInterval, id: String? = nil) -> DocItem {
        Fixture.doc(id: id ?? name,
                    name: name + ".docx",
                    modifiedAt: Self.jan1.addingTimeInterval(daysLater * 86_400))
    }

    private func names(_ items: [DocItem]) -> [String] { items.map(\.displayName) }

    func testNewestPutsTheMostRecentlyModifiedFirst() {
        let items = [doc("Middle", 1), doc("Oldest", 0), doc("Newest", 2)]

        XCTAssertEqual(names(DocSortOrder.newest.sorted(items)), ["Newest", "Middle", "Oldest"])
    }

    func testOldestPutsTheLeastRecentlyModifiedFirst() {
        let items = [doc("Middle", 1), doc("Oldest", 0), doc("Newest", 2)]

        XCTAssertEqual(names(DocSortOrder.oldest.sorted(items)), ["Oldest", "Middle", "Newest"])
    }

    /// A–Z and Z–A are exact opposites, and neither is decided by letter case.
    func testNameOrdersRunInBothDirectionsAndIgnoreCase() {
        let items = [doc("banana", 0), doc("Apple", 0), doc("cherry", 0)]

        XCTAssertEqual(names(DocSortOrder.nameAscending.sorted(items)), ["Apple", "banana", "cherry"])
        XCTAssertEqual(names(DocSortOrder.nameDescending.sorted(items)), ["cherry", "banana", "Apple"])
    }

    /// Sorting reads the title the row shows, so the hidden `.docx` cannot decide where a document
    /// lands — otherwise "Report" and "Report.docx" would sort as if spelled differently.
    func testNameOrderUsesTheTitleRatherThanTheFileName() {
        let items = [Fixture.doc(id: "1", name: "Zebra"), Fixture.doc(id: "2", name: "Apple.docx")]

        XCTAssertEqual(names(DocSortOrder.nameAscending.sorted(items)), ["Apple", "Zebra"])
    }

    /// A file browser groups folders ahead of documents whatever the order, and a folder's
    /// modification date is not something to rank a document against.
    func testFoldersStayAheadOfDocumentsInEveryOrder() {
        let items = [doc("Document", 5),
                     Fixture.folder(id: "f1", name: "Projects"),
                     Fixture.folder(id: "f2", name: "Archive")]

        for order in DocSortOrder.allCases {
            let sorted = order.sorted(items)
            XCTAssertEqual(sorted.prefix(2).map(\.type), [.folder, .folder], order.rawValue)
            XCTAssertEqual(sorted.last?.displayName, "Document", order.rawValue)
        }
    }

    /// Documents saved in the same second read as a list rather than as an arbitrary order.
    func testItemsModifiedAtTheSameTimeFallBackToTheName() {
        let items = [doc("Charlie", 0), doc("Alpha", 0), doc("Bravo", 0)]

        XCTAssertEqual(names(DocSortOrder.newest.sorted(items)), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(names(DocSortOrder.oldest.sorted(items)), ["Alpha", "Bravo", "Charlie"])
    }

    /// Two documents can share a name, and `sorted(by:)` is not stable — without the id tiebreak a
    /// reload could shuffle them under the reader.
    func testItemsSharingANameKeepAFixedOrder() {
        let duplicates = [doc("Report", 0, id: "c"), doc("Report", 0, id: "a"), doc("Report", 0, id: "b")]

        for order in DocSortOrder.allCases {
            XCTAssertEqual(order.sorted(duplicates).map(\.id), ["a", "b", "c"], order.rawValue)
            XCTAssertEqual(order.sorted(duplicates.reversed()).map(\.id), ["a", "b", "c"], order.rawValue)
        }
    }

    func testEveryOrderIsLabelledForTheMenu() {
        for order in DocSortOrder.allCases {
            XCTAssertFalse(order.displayName.isEmpty, order.rawValue)
        }
        XCTAssertEqual(Set(DocSortOrder.allCases.map(\.displayName)).count, DocSortOrder.allCases.count)
    }

    /// The chosen order is persisted by `rawValue`, so the spellings are a stored format.
    func testRawValuesAreTheStoredFormat() {
        XCTAssertEqual(Set(DocSortOrder.allCases.map(\.rawValue)),
                       ["newest", "oldest", "nameAscending", "nameDescending"])
    }

    func testAnEmptyListingSortsToNothing() {
        XCTAssertTrue(DocSortOrder.newest.sorted([]).isEmpty)
    }
}

// MARK: - ShareRoleTests

final class ShareRoleTests: XCTestCase {

    func testOnlyOwnersAndEditorsMayEdit() {
        XCTAssertTrue(ShareRole.owner.canEdit)
        XCTAssertTrue(ShareRole.editor.canEdit)
        XCTAssertFalse(ShareRole.commenter.canEdit)
        XCTAssertFalse(ShareRole.viewer.canEdit)
    }

    func testOnlyOwnersMayManage() {
        XCTAssertTrue(ShareRole.owner.canManage)
        for role in [ShareRole.editor, .commenter, .viewer] {
            XCTAssertFalse(role.canManage, role.rawValue)
        }
    }

    /// An unrecognised role is safer treated as read-only than as write access.
    func testUnknownRolesDefaultToTheLeastPrivilege() {
        XCTAssertEqual(ShareRole(serverValue: "administrator-of-everything"), .viewer)
        XCTAssertFalse(ShareRole(serverValue: "brand-new-role").canEdit)
    }

    func testServerValuesAreCaseInsensitive() {
        XCTAssertEqual(ShareRole(serverValue: "OWNER"), .owner)
        XCTAssertEqual(ShareRole(serverValue: "Editor"), .editor)
    }
}

// MARK: - DriveDateTests

/// Drive is not consistent about timestamps: file payloads carry zone-less `NaiveDateTime`, version
/// payloads carry zoned RFC 3339 with a variable number of fractional digits. Both have to parse,
/// because conflict detection compares them.
final class DriveDateTests: XCTestCase {

    func testZoneLessTimestampsAreReadAsUTC() {
        let date = DriveDate.date(from: "2026-07-30T14:25:36.123456")
        XCTAssertNotNil(date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 30)
        XCTAssertEqual(components.hour, 14)
    }

    func testEveryFractionalPrecisionParses() {
        let inputs = [
            "2026-07-30T14:25:36Z",
            "2026-07-30T14:25:36.1Z",
            "2026-07-30T14:25:36.123Z",
            "2026-07-30T14:25:36.123456Z",
            "2026-07-30T14:25:36.123456789Z",
        ]
        for input in inputs {
            XCTAssertNotNil(DriveDate.date(from: input), input)
        }
    }

    func testNumericZoneOffsetsParse() {
        let utc = DriveDate.date(from: "2026-07-30T14:25:36Z")
        let plusTwo = DriveDate.date(from: "2026-07-30T16:25:36+02:00")
        XCTAssertEqual(utc, plusTwo, "The same instant expressed two ways")
    }

    func testNegativeOffsetsAreNotConfusedWithTheDatesHyphens() {
        let utc = DriveDate.date(from: "2026-07-30T14:25:36Z")
        let minusFive = DriveDate.date(from: "2026-07-30T09:25:36-05:00")
        XCTAssertEqual(utc, minusFive)
    }

    func testMalformedInputReturnsNil() {
        for input in ["", "not a date", "2026-07-30", "2026-07-30T14:25:36.abcZ"] {
            XCTAssertNil(DriveDate.date(from: input), input)
        }
    }

    func testDecoderReadsBothShapesInOneResponse() throws {
        struct Payload: Decodable {
            let fileTime: Date
            let versionTime: Date
        }
        let json = Data("""
        {"fileTime":"2026-07-30T14:25:36.123456",
         "versionTime":"2026-07-30T14:25:36.123456789Z"}
        """.utf8)

        let payload = try DriveDate.makeDecoder().decode(Payload.self, from: json)

        XCTAssertEqual(payload.fileTime.timeIntervalSince1970,
                       payload.versionTime.timeIntervalSince1970, accuracy: 0.01)
    }

    func testDecoderReportsUnparseableDates() {
        struct Payload: Decodable { let when: Date }
        var reported: String?
        let decoder = DriveDate.makeDecoder(onFailure: { reported = $0 })

        XCTAssertThrowsError(try decoder.decode(Payload.self, from: Data(#"{"when":"nope"}"#.utf8)))
        XCTAssertEqual(reported, "nope")
    }
}

// MARK: - DocTextStatsTests

/// Supports **Edit**: the counts shown under the editor.
final class DocTextStatsTests: XCTestCase {

    func testEmptyTextHasNoWordsAndNoReadingTime() {
        let stats = DocTextStats.compute(from: "")
        XCTAssertEqual(stats.wordCount, 0)
        XCTAssertEqual(stats.characterCount, 0)
        XCTAssertEqual(stats.readingTimeMinutes, 0)
    }

    func testWordsAreSplitOnWhitespaceAndNewlines() {
        let stats = DocTextStats.compute(from: "one two\tthree\nfour")
        XCTAssertEqual(stats.wordCount, 4)
    }

    func testRepeatedWhitespaceDoesNotInflateTheCount() {
        XCTAssertEqual(DocTextStats.compute(from: "  one   two  ").wordCount, 2)
    }

    func testCharacterCountCountsCharactersNotBytes() {
        // Four visible characters, more than four UTF-8 bytes.
        XCTAssertEqual(DocTextStats.compute(from: "héllo").characterCount, 5)
    }

    func testShortTextStillReadsAsOneMinute() {
        XCTAssertEqual(DocTextStats.compute(from: "one two three").readingTimeMinutes, 1)
    }

    func testReadingTimeRoundsUp() {
        let text = Array(repeating: "word", count: 201).joined(separator: " ")
        XCTAssertEqual(DocTextStats.compute(from: text).readingTimeMinutes, 2)
    }

    func testReadingTimeScalesWithLength() {
        let text = Array(repeating: "word", count: 1000).joined(separator: " ")
        XCTAssertEqual(DocTextStats.compute(from: text).readingTimeMinutes, 5)
    }

    func testSummaryTextIsSingularWhereItShouldBe() {
        let stats = DocTextStats.compute(from: "a")
        XCTAssertTrue(stats.summaryText.contains("1 word"))
        XCTAssertTrue(stats.summaryText.contains("1 character"))
    }
}

// MARK: - SyncBackoffTests

/// Supports **Sync**: the retry curve.
final class SyncBackoffTests: XCTestCase {

    func testFirstAttemptIsImmediate() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 0), 0)
    }

    func testDelayGrowsGeometrically() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 1), 5)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 2), 15)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 3), 45)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 4), 135)
    }

    func testDelayIsCapped() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 5), SyncBackoff.maximumDelay)
        XCTAssertEqual(SyncBackoff.delay(forAttempt: 50), SyncBackoff.maximumDelay)
    }

    /// A large attempt count must not overflow before the cap is applied.
    func testAVeryLargeAttemptCountStillReturnsTheCap() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: Int.max), SyncBackoff.maximumDelay)
    }

    func testNegativeAttemptsAreTreatedAsImmediate() {
        XCTAssertEqual(SyncBackoff.delay(forAttempt: -1), 0)
    }
}

// MARK: - PendingMutationTests

/// Supports **Work offline**: the queue's collapsing rules.
final class PendingMutationTests: XCTestCase {

    func testDeleteSupersedesEverythingForTheSameItem() {
        let delete = PendingMutation(itemID: "a", kind: .delete(isFolder: false))

        XCTAssertTrue(delete.supersedes(PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "x"))))
        XCTAssertTrue(delete.supersedes(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: nil))))
        XCTAssertTrue(delete.supersedes(PendingMutation(itemID: "a", kind: .delete(isFolder: false))))
    }

    func testLikeReplacesLike() {
        let move = PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f2"))
        XCTAssertTrue(move.supersedes(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f1"))))

        let rename = PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "b"))
        XCTAssertTrue(rename.supersedes(PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "a"))))
    }

    /// A move and a rename are independent facts; neither may swallow the other.
    func testAMoveDoesNotSupersedeARename() {
        let move = PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: "f1"))
        XCTAssertFalse(move.supersedes(PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "b"))))
    }

    func testNothingSupersedesAMutationForADifferentItem() {
        let delete = PendingMutation(itemID: "a", kind: .delete(isFolder: false))
        XCTAssertFalse(delete.supersedes(PendingMutation(itemID: "b", kind: .delete(isFolder: false))))
    }

    func testIsFolderIsReadableFromEveryKind() {
        XCTAssertTrue(PendingMutation.Kind.delete(isFolder: true).isFolder)
        XCTAssertTrue(PendingMutation.Kind.move(isFolder: true, targetFolderID: nil).isFolder)
        XCTAssertTrue(PendingMutation.Kind.rename(isFolder: true, newName: "x").isFolder)
        XCTAssertFalse(PendingMutation.Kind.delete(isFolder: false).isFolder)
    }

    func testSummariesAreHumanReadable() {
        XCTAssertEqual(PendingMutation(itemID: "a", kind: .delete(isFolder: false)).summary, "Delete")
        XCTAssertEqual(PendingMutation(itemID: "a", kind: .move(isFolder: false, targetFolderID: nil)).summary,
                       "Move to Drive root")
        XCTAssertEqual(PendingMutation(itemID: "a", kind: .rename(isFolder: false, newName: "New.md")).summary,
                       "Rename to New.md")
    }

    func testMutationsRoundTripThroughCoding() throws {
        let original = PendingMutation(itemID: "a", kind: .move(isFolder: true, targetFolderID: "f1"))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingMutation.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

// MARK: - CacheReasonTests

final class CacheReasonTests: XCTestCase {

    /// A document the user deliberately kept must survive automatic cache maintenance.
    func testOnlyAutomaticReasonsAreEvictable() {
        XCTAssertFalse(CacheReason.pinned.isEvictable)
        for reason in [CacheReason.opened, .recent, .favorite] {
            XCTAssertTrue(reason.isEvictable, reason.rawValue)
        }
    }

    func testEveryReasonHasADisplayName() {
        for reason in CacheReason.allCases {
            XCTAssertFalse(reason.displayName.isEmpty, reason.rawValue)
        }
    }
}

// MARK: - DocVersionTests

/// Supports Phase 1's Version History, including "View timestamps".
final class DocVersionTests: XCTestCase {

    func testVersionsDecodeFromTheServerShape() throws {
        let json = Data("""
        {"versions":[{"id":"v1","fileId":"d1","versionNumber":2,"sizeBytes":128,
                      "label":"Draft","createdAt":"2026-07-30T14:25:36.123456789Z","isNamed":true}],
         "total":1}
        """.utf8)
        struct Response: Decodable { let versions: [DocVersion] }

        let versions = try DocVersion.decoder.decode(Response.self, from: json).versions

        XCTAssertEqual(versions.first?.id, "v1")
        XCTAssertEqual(versions.first?.fileID, "d1")
        XCTAssertEqual(versions.first?.versionNumber, 2)
        XCTAssertTrue(versions.first?.isNamed ?? false)
    }

    func testUnnamedVersionsTitleByNumber() {
        let version = DocVersion(id: "v1", fileID: "d1", versionNumber: 3, sizeBytes: 10,
                                 createdAt: Date())
        XCTAssertEqual(version.displayTitle, "Version 3")
        XCTAssertEqual(version.shortTitle, "v3")
    }

    func testNamedVersionsShowTheirLabelAndNumber() {
        let version = DocVersion(id: "v1", fileID: "d1", versionNumber: 3, sizeBytes: 10,
                                 label: "Sent to Ana", createdAt: Date(), isNamed: true)
        XCTAssertEqual(version.displayTitle, "Sent to Ana (v3)")
    }

    func testABlankLabelFallsBackToTheNumber() {
        let version = DocVersion(id: "v1", fileID: "d1", versionNumber: 3, sizeBytes: 10,
                                 label: "   ", createdAt: Date())
        XCTAssertEqual(version.displayTitle, "Version 3")
    }

    func testTimestampTextIsPopulated() {
        let version = DocVersion(id: "v1", fileID: "d1", versionNumber: 1, sizeBytes: 10,
                                 createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertFalse(version.timestampText.isEmpty)
    }
}

// MARK: - DocFileInfoTests

final class DocFileInfoTests: XCTestCase {

    func testInfoDecodesWithARole() throws {
        let json = Data("""
        {"id":"d1","name":"Notes.md","sizeBytes":42,"folderId":"f1",
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"2026-07-30T14:25:36.123456",
         "yourRole":"viewer"}
        """.utf8)

        let info = try DocFileInfo.decoder.decode(DocFileInfo.self, from: json)

        XCTAssertEqual(info.yourRole, .viewer)
        XCTAssertEqual(info.folderID, "f1")
        XCTAssertTrue(info.isLive)
    }

    /// `/info` omits the field for a file in the caller's own drive.
    func testAMissingRoleMeansTheCallerOwnsIt() throws {
        let json = Data("""
        {"id":"d1","name":"Notes.md","sizeBytes":42,"folderId":null,
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"2026-07-30T14:25:36.123456"}
        """.utf8)

        let info = try DocFileInfo.decoder.decode(DocFileInfo.self, from: json)

        XCTAssertEqual(info.yourRole, .owner)
    }

    func testATrashedFileIsNotLive() throws {
        let json = Data("""
        {"id":"d1","name":"Notes.md","sizeBytes":42,"folderId":null,
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"2026-07-30T14:25:36.123456",
         "deletedAt":"2026-07-30T15:00:00.000000","yourRole":"owner"}
        """.utf8)

        let info = try DocFileInfo.decoder.decode(DocFileInfo.self, from: json)

        XCTAssertFalse(info.isLive, "A trashed file is not somewhere an edit can land")
    }

    func testAMissingSizeDefaultsToZeroRatherThanFailing() throws {
        let json = Data("""
        {"id":"d1","name":"Notes.md","folderId":null,
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"2026-07-30T14:25:36.123456",
         "yourRole":"owner"}
        """.utf8)

        let info = try DocFileInfo.decoder.decode(DocFileInfo.self, from: json)

        XCTAssertEqual(info.sizeBytes, 0)
    }
}

// MARK: - MultipartFormBodyTests

/// Drive's actix-multipart handlers reject a raw octet-stream body, so this framing is what every
/// write path depends on.
final class MultipartFormBodyTests: XCTestCase {

    func testContentTypeCarriesTheBoundary() {
        let form = MultipartFormBody(boundary: "ABC123")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=ABC123")
    }

    func testFieldsAreFramedWithTheirName() {
        var form = MultipartFormBody(boundary: "B")
        form.appendField(name: "folder_id", value: "f1")

        let body = String(decoding: form.finalized(), as: UTF8.self)

        XCTAssertTrue(body.contains("--B\r\n"))
        XCTAssertTrue(body.contains(#"Content-Disposition: form-data; name="folder_id""#))
        XCTAssertTrue(body.contains("f1"))
    }

    /// Optional fields can be passed straight through without the caller branching.
    func testNilFieldsAreOmittedEntirely() {
        var form = MultipartFormBody(boundary: "B")
        form.appendField(name: "label", value: nil)

        XCTAssertEqual(String(decoding: form.finalized(), as: UTF8.self), "--B--\r\n")
    }

    func testFilePartsCarryFilenameAndContentType() {
        var form = MultipartFormBody(boundary: "B")
        form.appendFile(name: "file", fileName: "Notes.md",
                        mimeType: DocItem.documentMIME, data: Data([1, 2, 3]))

        let body = String(decoding: form.finalized(), as: UTF8.self)

        XCTAssertTrue(body.contains(#"name="file"; filename="Notes.md""#))
        XCTAssertTrue(body.contains("Content-Type: \(DocItem.documentMIME)"))
    }

    /// The payload is ciphertext: it must survive byte for byte, not be re-encoded as text.
    func testBinaryPayloadsAreWrittenVerbatim() {
        var form = MultipartFormBody(boundary: "B")
        let payload = Data([0x00, 0xFF, 0xFE, 0x80, 0x0A, 0x0D])
        form.appendFile(name: "file", fileName: "x", mimeType: "application/octet-stream", data: payload)

        let body = form.finalized()

        XCTAssertNotNil(body.range(of: payload))
    }

    func testBodyIsTerminatedByTheClosingBoundary() {
        var form = MultipartFormBody(boundary: "B")
        form.appendField(name: "a", value: "1")

        XCTAssertTrue(String(decoding: form.finalized(), as: UTF8.self).hasSuffix("--B--\r\n"))
    }

    func testBoundariesAreUniquePerBody() {
        XCTAssertNotEqual(MultipartFormBody().boundary, MultipartFormBody().boundary)
    }
}
