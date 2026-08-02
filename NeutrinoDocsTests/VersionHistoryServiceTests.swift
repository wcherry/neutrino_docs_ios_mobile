import XCTest
import Sodium
@testable import NeutrinoDocs

/// Phase 1 — Version History: "Previous versions", "Restore version", "View timestamps".
@MainActor
final class VersionHistoryServiceTests: XCTestCase {

    private var sut: VersionHistoryService!
    private var content: DocContentService!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        content = DocContentService(session: MockURLProtocol.makeSession())
        sut = VersionHistoryService(session: MockURLProtocol.makeSession())
        sut.contentService = content
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        content = nil
        super.tearDown()
    }

    // MARK: - List

    func testListVersionsDecodesTheHistory() async throws {
        MockURLProtocol.respond(json: """
        {"versions":[
          {"id":"v2","fileId":"d1","versionNumber":2,"sizeBytes":200,"label":"Draft",
           "createdAt":"2026-07-30T15:00:00Z","isNamed":true},
          {"id":"v1","fileId":"d1","versionNumber":1,"sizeBytes":100,"label":null,
           "createdAt":"2026-07-30T14:00:00Z","isNamed":false}
        ],"total":2}
        """)

        let versions = try await sut.listVersions(fileID: "d1")

        XCTAssertEqual(versions.map(\.versionNumber), [2, 1], "Newest first, as the server orders")
        XCTAssertEqual(versions.first?.displayTitle, "Draft (v2)")
        XCTAssertFalse(versions.last?.timestampText.isEmpty ?? true)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/drive/files/d1/versions")
    }

    func testAnEmptyHistoryIsNotAnError() async throws {
        MockURLProtocol.respond(json: #"{"versions":[],"total":0}"#)

        let versions = try await sut.listVersions(fileID: "d1")

        XCTAssertTrue(versions.isEmpty)
    }

    func testListVersionsSendsTheBearerToken() async throws {
        MockURLProtocol.respond(json: #"{"versions":[],"total":0}"#)

        _ = try await sut.listVersions(fileID: "d1")

        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-access-token")
    }

    func testServerErrorsSurface() async {
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        do {
            _ = try await sut.listVersions(fileID: "d1")
            XCTFail("Expected a server error")
        } catch VersionHistoryError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected serverError, got \(error)")
        }
    }

    // MARK: - Reading a snapshot

    /// A file's DEK never rotates, so the session key already in hand decrypts every version.
    func testVersionTextDecryptsWithTheSessionDEK() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(text: "# Old version",
                                             dek: dek,
                                             xcss: sodium.secretStream.xchacha20poly1305)
        MockURLProtocol.respond(data: ciphertext)

        let text = try await sut.versionText(fileID: "d1", versionID: "v1", dek: dek)

        XCTAssertEqual(text, "# Old version")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path,
                       "/api/v1/drive/files/d1/versions/v1/download")
    }

    func testVersionTextFailsWithTheWrongKey() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try content.encrypt(text: "secret", dek: dek,
                                             xcss: sodium.secretStream.xchacha20poly1305)
        MockURLProtocol.respond(data: ciphertext)

        let wrongDEK = sodium.secretStream.xchacha20poly1305.key()
        do {
            _ = try await sut.versionText(fileID: "d1", versionID: "v1", dek: wrongDEK)
            XCTFail("A snapshot must not decrypt under the wrong key")
        } catch {
            // Expected.
        }
    }

    // MARK: - Saving a named version

    func testSaveVersionUploadsCiphertextWithItsLabel() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"v3","fileId":"d1","versionNumber":3,"sizeBytes":50,"label":"Sent to Ana",
         "createdAt":"2026-07-30T16:00:00Z","isNamed":true}
        """)

        let version = try await sut.saveVersion("# Content", for: Fixture.doc(id: "d1"),
                                                dek: dek, label: "Sent to Ana")

        XCTAssertEqual(version.versionNumber, 3)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "POST")
        let body = String(decoding: MockURLProtocol.bodies.first ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="label""#))
        XCTAssertTrue(body.contains("Sent to Ana"))
    }

    func testSavedVersionBodyDoesNotContainThePlaintext() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"v3","fileId":"d1","versionNumber":3,"sizeBytes":50,"label":null,
         "createdAt":"2026-07-30T16:00:00Z","isNamed":true}
        """)

        _ = try await sut.saveVersion("the launch code is 12345", for: Fixture.doc(id: "d1"),
                                      dek: dek, label: nil)

        let body = String(decoding: MockURLProtocol.bodies.first ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("launch code"))
    }

    func testAnUnlabelledSaveOmitsTheLabelField() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"v3","fileId":"d1","versionNumber":3,"sizeBytes":50,"label":null,
         "createdAt":"2026-07-30T16:00:00Z","isNamed":false}
        """)

        _ = try await sut.saveVersion("text", for: Fixture.doc(id: "d1"), dek: dek, label: nil)

        let body = String(decoding: MockURLProtocol.bodies.first ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains(#"name="label""#))
    }

    // MARK: - Restore

    /// The server snapshots the pre-restore content first, so a restore is itself undoable.
    func testRestoreReturnsTheDocumentsNewSizeAndDate() async throws {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        MockURLProtocol.respond(json: """
        {"sizeBytes":321,"updatedAt":"\(Fixture.driveTimestamp(updated))"}
        """)

        let result = try await sut.restore(versionID: "v1", fileID: "d1")

        XCTAssertEqual(result.sizeBytes, 321)
        XCTAssertEqual(result.modifiedAt.timeIntervalSince1970, updated.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path,
                       "/api/v1/drive/files/d1/versions/v1/restore")
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "POST")
    }

    func testRestoringWithoutASessionFails() async {
        TestTokens.remove()

        do {
            _ = try await sut.restore(versionID: "v1", fileID: "d1")
            XCTFail("Expected notAuthenticated")
        } catch VersionHistoryError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("Expected notAuthenticated, got \(error)")
        }
    }
}

// MARK: - DeviceSessionServiceTests

/// Phase 1 — Authentication: "Device registration", the visible half.
@MainActor
final class DeviceSessionServiceTests: XCTestCase {

    private var sut: DeviceSessionService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        DeviceIdentity.setDeviceName("This Device")
        sut = DeviceSessionService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        DeviceIdentity.setDeviceName(nil)
        sut = nil
        super.tearDown()
    }

    func testLoadFetchesTheRegisteredDevices() async {
        MockURLProtocol.respond(json: """
        {"sessions":[{"id":"s1","deviceName":"Other iPad","userAgent":null,"ipAddress":null,
                      "createdAt":"2026-07-30T14:00:00.000000","lastUsedAt":null}]}
        """)

        await sut.load()

        XCTAssertNil(sut.error)
        XCTAssertEqual(sut.sessions.map(\.id), ["s1"])
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/v1/auth/sessions")
    }

    /// Somebody checking their devices is looking for the ones they do not recognise, so the one
    /// they are holding gets out of the way at the top.
    func testTheCurrentDeviceSortsFirstThenMostRecentlyUsed() async {
        MockURLProtocol.respond(json: """
        {"sessions":[
          {"id":"old","deviceName":"Old Laptop","userAgent":null,"ipAddress":null,
           "createdAt":"2026-07-01T10:00:00.000000","lastUsedAt":"2026-07-02T10:00:00.000000"},
          {"id":"mine","deviceName":"This Device","userAgent":null,"ipAddress":null,
           "createdAt":"2026-07-30T10:00:00.000000","lastUsedAt":null},
          {"id":"recent","deviceName":"Other Phone","userAgent":null,"ipAddress":null,
           "createdAt":"2026-07-20T10:00:00.000000","lastUsedAt":"2026-07-29T10:00:00.000000"}
        ]}
        """)

        await sut.load()

        XCTAssertEqual(sut.sessions.map(\.id), ["mine", "recent", "old"])
    }

    func testRevokeRemovesTheRowAndCallsDelete() async {
        MockURLProtocol.respond(json: """
        {"sessions":[{"id":"s1","deviceName":"Other iPad","userAgent":null,"ipAddress":null,
                      "createdAt":"2026-07-30T14:00:00.000000","lastUsedAt":null}]}
        """)
        await sut.load()
        MockURLProtocol.respond(json: "", statusCode: 204)

        await sut.revoke(sessionID: "s1")

        XCTAssertTrue(sut.sessions.isEmpty)
        let deleteRequest = MockURLProtocol.request { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deleteRequest?.url?.path, "/api/v1/auth/sessions/s1")
    }

    func testAFailedRevokePutsTheRowBack() async {
        MockURLProtocol.respond(json: """
        {"sessions":[{"id":"s1","deviceName":"Other iPad","userAgent":null,"ipAddress":null,
                      "createdAt":"2026-07-30T14:00:00.000000","lastUsedAt":null}]}
        """)
        await sut.load()
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        await sut.revoke(sessionID: "s1")

        XCTAssertEqual(sut.sessions.map(\.id), ["s1"], "An optimistic removal must be undone")
        XCTAssertNotNil(sut.error)
    }

    func testLoadWithoutASessionReportsAnError() async {
        TestTokens.remove()

        await sut.load()

        XCTAssertNotNil(sut.error)
        XCTAssertTrue(sut.sessions.isEmpty)
    }
}
