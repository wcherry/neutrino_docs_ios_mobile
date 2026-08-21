import XCTest
import Sodium
@testable import NeutrinoDocs

/// Milestone 1 deliverables: **Open documents** and **Save**.
///
/// The crypto is real throughout — a real X25519 pair in the Keychain, real
/// XChaCha20-Poly1305 secretstream, real `crypto_box_seal`. Faking it would leave the most
/// expensive thing in the app to get wrong entirely unasserted.
@MainActor
final class DocContentServiceTests: XCTestCase {

    private var sut: DocContentService!
    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        sut = DocContentService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Encryption round trip

    func testEncryptThenDecryptReturnsTheOriginalText() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let original = "A title\n\nSome text with émoji 🎉 and a tab\t."

        let ciphertext = try sut.encrypt(text: original, dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)
        let roundTripped = try sut.decrypt(data: ciphertext, dek: dek)

        XCTAssertEqual(roundTripped, original)
    }

    func testCiphertextIsPrefixedByTheSecretStreamHeaderAndIsNotPlaintext() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let original = "secret content"

        let ciphertext = try sut.encrypt(text: original, dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)

        XCTAssertGreaterThan(ciphertext.count, 24, "24-byte header plus ciphertext")
        XCTAssertNil(String(data: ciphertext, encoding: .utf8).map { $0.contains(original) }
                        .flatMap { $0 ? true : nil },
                     "The plaintext must not be recoverable from the ciphertext bytes")
    }

    func testEncryptingTheSameTextTwiceProducesDifferentCiphertext() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let first = try sut.encrypt(text: "same", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)
        let second = try sut.encrypt(text: "same", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)

        // A fresh random header per stream — identical output would mean a reused nonce.
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try sut.decrypt(data: first, dek: dek),
                       try sut.decrypt(data: second, dek: dek))
    }

    func testDecryptingWithTheWrongKeyFails() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let wrongDEK = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try sut.encrypt(text: "secret", dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)

        XCTAssertThrowsError(try sut.decrypt(data: ciphertext, dek: wrongDEK))
    }

    /// Poly1305 authenticates the ciphertext; a flipped bit must fail rather than yield garbage.
    func testTamperedCiphertextIsRejected() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        var ciphertext = try sut.encrypt(text: "secret", dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)
        ciphertext[ciphertext.count - 1] ^= 0x01

        XCTAssertThrowsError(try sut.decrypt(data: ciphertext, dek: dek))
    }

    func testTruncatedCiphertextIsRejected() {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        XCTAssertThrowsError(try sut.decrypt(data: Data([1, 2, 3]), dek: dek))
    }

    func testEmptyDocumentRoundTrips() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try sut.encrypt(text: "", dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)
        XCTAssertEqual(try sut.decrypt(data: ciphertext, dek: dek), "")
    }

    // MARK: - DEK sealing

    func testSealedDEKUnsealsBackToTheSameKey() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let sealed = try sut.sealDEK(dek)
        let unsealed = try sut.unsealDEK(sealed)

        XCTAssertEqual(unsealed, dek)
    }

    func testSealedDEKIsBase64URLWithoutPadding() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealed = try sut.sealDEK(dek)
        XCTAssertNil(sealed.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testSealingWithoutAnImportedKeyFails() {
        TestKeys.remove()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        XCTAssertThrowsError(try sut.sealDEK(dek)) { error in
            guard case DocContentError.noEncryptionKey = error else {
                return XCTFail("Expected noEncryptionKey, got \(error)")
            }
        }
    }

    /// A DEK sealed to somebody else's public key must not open with this device's private key.
    func testDEKSealedToAnotherKeyPairCannotBeUnsealed() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let sealed = try sut.sealDEK(dek)

        TestKeys.remove()
        TestKeys.install()   // a different pair

        XCTAssertThrowsError(try sut.unsealDEK(sealed))
    }

    func testUnsealingGarbageFails() {
        XCTAssertThrowsError(try sut.unsealDEK("not-valid-base64url-$$$"))
    }

    // MARK: - Metadata

    func testEncryptedMetadataIsOpaqueBase64URL() throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let metadata = try sut.encryptMetadata(name: "Report.md", mimeType: DocItem.documentMIME,
                                               dek: dek, xcss: sodium.secretStream.xchacha20poly1305)

        XCTAssertFalse(metadata.contains("Report"), "The name must not be readable server-side")
        XCTAssertNil(metadata.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    // MARK: - Open

    func testLoadContentFetchesTheKeyThenTheBodyAndDecryptsIt() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let stored = NeutrinoDocumentCodec.encode(DocumentBody.text("# Hello"))
        let ciphertext = try sut.encrypt(text: stored, dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)
        let sealed = try sut.sealDEK(dek)
        stubContent(sealedKey: sealed, ciphertext: ciphertext)

        let (body, returnedDEK) = try await sut.loadContent(for: Fixture.doc(id: "d1"))

        XCTAssertEqual(body.plainText, "# Hello")
        XCTAssertEqual(returnedDEK, dek, "The session DEK is returned so saves need no re-unseal")
        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/v1/drive/files/d1/key", "/api/v1/drive/files/d1"])
    }

    func testLoadContentSendsTheBearerToken() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try sut.encrypt(text: "x", dek: dek, xcss: sodium.secretStream.xchacha20poly1305)
        stubContent(sealedKey: try sut.sealDEK(dek), ciphertext: ciphertext)

        _ = try await sut.loadContent(for: Fixture.doc(id: "d1"))

        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(TestTokens.defaultAccessToken)")
    }

    func testLoadContentWithoutASessionFails() async {
        TestTokens.remove()

        do {
            _ = try await sut.loadContent(for: Fixture.doc(id: "d1"))
            XCTFail("Expected notAuthenticated")
        } catch DocContentError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("Expected notAuthenticated, got \(error)")
        }
    }

    func testServerErrorWhileOpeningIsReported() async {
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        do {
            _ = try await sut.loadContent(for: Fixture.doc(id: "d1"))
            XCTFail("Expected a server error")
        } catch DocContentError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected serverError, got \(error)")
        }
    }

    // MARK: - Save

    func testSaveContentPUTsToAutosaveAndReturnsTheServerTimestamp() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let expected = Date(timeIntervalSince1970: 1_750_000_000)
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1", updatedAt: expected))

        let saved = try await sut.saveContent(DocumentBody.text("new text"),
                                              for: Fixture.doc(id: "d1"), dek: dek)

        let request = MockURLProtocol.requests.first
        XCTAssertEqual(request?.httpMethod, "PUT")
        XCTAssertEqual(request?.url?.path, "/api/v1/drive/files/d1/autosave")
        XCTAssertEqual(saved.updatedAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Save — optimistic concurrency

    /// The guard has to reach the server as a query parameter, or the write is unprotected and the
    /// whole scheme silently degrades to last-writer-wins.
    func testSaveSendsExpectedContentVersionWhenGiven() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1"))

        _ = try await sut.saveContent(DocumentBody.text("text"), for: Fixture.doc(id: "d1"),
                                      dek: dek, expectedContentVersion: 7)

        let url = try XCTUnwrap(MockURLProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/drive/files/d1/autosave")
        XCTAssertEqual(url.query, "expectedContentVersion=7")
    }

    /// A document with no known version — freshly created, or cached before versions were tracked
    /// — must still save, unguarded, rather than failing or sending a bogus version.
    func testSaveOmitsTheGuardWhenNoVersionIsKnown() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1"))

        _ = try await sut.saveContent(DocumentBody.text("text"), for: Fixture.doc(id: "d1"),
                                      dek: dek, expectedContentVersion: nil)

        XCTAssertNil(MockURLProtocol.requests.first?.url?.query)
    }

    /// A rejected write must arrive as its own error. Reported as a generic server error it would
    /// be retried or queued, which is precisely the overwrite the guard exists to prevent.
    func testStaleSaveSurfacesAsAContentVersionConflict() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(
            json: #"{"error":{"code":"CONTENT_VERSION_CONFLICT","message":"File d1 has changed on the server (expected content version 3, found 5)."}}"#,
            statusCode: 409
        )

        do {
            _ = try await sut.saveContent(DocumentBody.text("text"), for: Fixture.doc(id: "d1"),
                                          dek: dek, expectedContentVersion: 3)
            XCTFail("a stale save must not be reported as success")
        } catch DocContentError.contentVersionConflict(let current) {
            // The version the server holds is recovered from the message so a resolver can show it.
            XCTAssertEqual(current, 5)
        }
    }

    /// Drive answers 409 for other things too — a file whose blob is missing from storage, for one.
    /// Treating those as a stale write would tell the user to reload over a fault reloading cannot
    /// fix, and would drop their edit from the retry queue.
    func testUnrelated409IsNotReportedAsAVersionConflict() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(
            json: #"{"error":{"code":"CONTENT_MISSING","message":"File content is missing from storage"}}"#,
            statusCode: 409
        )

        do {
            _ = try await sut.saveContent(DocumentBody.text("text"), for: Fixture.doc(id: "d1"),
                                          dek: dek, expectedContentVersion: 3)
            XCTFail("expected the save to fail")
        } catch DocContentError.contentVersionConflict {
            XCTFail("an unrelated 409 must not be reported as a version conflict")
        } catch DocContentError.serverError(let code) {
            XCTAssertEqual(code, 409)
        }
    }

    /// Drive's actix-multipart handlers reject a raw octet-stream body, so the ciphertext has to be
    /// framed as a `file` part even though it is a single opaque blob.
    func testSaveSendsMultipartFormDataWithAFilePart() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1"))

        _ = try await sut.saveContent(DocumentBody.text("text"), for: Fixture.doc(id: "d1"),
                                      dek: dek)

        let contentType = MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = MockURLProtocol.bodies.first ?? Data()
        let asString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(asString.contains(#"name="file""#))
    }

    /// The whole point of end-to-end encryption: what leaves the device is not readable.
    func testSavedBodyDoesNotContainThePlaintext() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1"))
        let secret = "the launch code is 12345"

        _ = try await sut.saveContent(DocumentBody.text(secret), for: Fixture.doc(id: "d1"),
                                      dek: dek)

        let body = MockURLProtocol.bodies.first ?? Data()
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(secret))
    }

    /// What is uploaded must be exactly what a reader gets back.
    func testUploadedCiphertextDecryptsToWhatWasSaved() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "d1"))
        let original = DocumentBody.text("Saved content.")

        _ = try await sut.saveContent(original, for: Fixture.doc(id: "d1"), dek: dek)

        let body = MockURLProtocol.bodies.first ?? Data()
        let ciphertext = try XCTUnwrap(Self.extractFilePart(from: body))
        let stored = try sut.decrypt(data: ciphertext, dek: dek)
        XCTAssertEqual(NeutrinoDocumentCodec.decode(stored), original)
    }

    // MARK: - Create

    func testCreateDocumentUploadsThenStoresTheSealedKey() async throws {
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/files/upload") == true {
                return (ok, Data(Fixture.fileJSON(id: "new-1", name: "New.md").utf8))
            }
            return (ok, Data("{}".utf8))
        }

        let item = try await sut.createDocument(name: "New.md", parentID: "f1")

        XCTAssertEqual(item.id, "new-1")
        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/v1/drive/files/upload", "/api/v1/drive/files/new-1/key"])
        XCTAssertEqual(MockURLProtocol.requests.last?.httpMethod, "PUT")
    }

    func testCreateSendsEncryptedMetadataAndTheParentFolder() async throws {
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/files/upload") == true {
                return (ok, Data(Fixture.fileJSON(id: "new-1").utf8))
            }
            return (ok, Data("{}".utf8))
        }

        _ = try await sut.createDocument(name: "Secret Plans.md", parentID: "f1")

        let body = String(decoding: MockURLProtocol.bodies.first ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="encrypted_metadata""#))
        XCTAssertTrue(body.contains(#"name="folder_id""#))
        XCTAssertTrue(body.contains("f1"))
        XCTAssertFalse(body.contains("Secret Plans.md\r\n\r\n"),
                       "The name may appear only as the multipart filename, never as metadata")
    }

    func testCreateWithoutAnImportedKeyFails() async {
        TestKeys.remove()

        do {
            _ = try await sut.createDocument(name: "New.md", parentID: nil)
            XCTFail("Expected noEncryptionKey")
        } catch DocContentError.noEncryptionKey {
            // Expected.
        } catch {
            XCTFail("Expected noEncryptionKey, got \(error)")
        }
    }

    // MARK: - File info / conflict input

    func testFileInfoDecodesRoleAndTimestamp() async throws {
        let updated = Date(timeIntervalSince1970: 1_750_000_000)
        MockURLProtocol.respond(json: """
        {"id":"d1","name":"Notes.md","sizeBytes":42,"folderId":"f1",
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"\(Fixture.driveTimestamp(updated))",
         "yourRole":"editor"}
        """)

        let info = try await sut.fileInfo(for: "d1")

        XCTAssertEqual(info?.yourRole, .editor)
        XCTAssertEqual(info?.isLive, true)
        XCTAssertEqual(info?.updatedAt.timeIntervalSince1970 ?? 0, updated.timeIntervalSince1970, accuracy: 1)
    }

    /// 404 and 403 both mean "not mine to read", which is a fact rather than an error.
    func testFileInfoReturnsNilForUnavailableDocuments() async throws {
        for status in [404, 403] {
            MockURLProtocol.reset()
            MockURLProtocol.respond(json: "{}", statusCode: status)
            let info = try await sut.fileInfo(for: "d1")
            XCTAssertNil(info, "status \(status) should read as unavailable")
        }
    }

    func testFetchServerModifiedAtReturnsNilForATrashedDocument() async throws {
        MockURLProtocol.respond(json: """
        {"id":"d1","name":"Notes.md","sizeBytes":42,"folderId":null,
         "mimeType":"\(DocItem.documentMIME)","updatedAt":"\(Fixture.driveTimestamp(Date()))",
         "deletedAt":"\(Fixture.driveTimestamp(Date()))","yourRole":"owner"}
        """)

        let modifiedAt = try await sut.fetchServerModifiedAt(for: Fixture.doc(id: "d1"))

        XCTAssertNil(modifiedAt, "A trashed document is not somewhere an edit can land")
    }

    // MARK: - Offline support

    func testDownloadEncryptedReturnsTheServerBytesVerbatim() async throws {
        let dek = sodium.secretStream.xchacha20poly1305.key()
        let ciphertext = try sut.encrypt(text: "cached", dek: dek,
                                         xcss: sodium.secretStream.xchacha20poly1305)
        let sealed = try sut.sealDEK(dek)
        stubContent(sealedKey: sealed, ciphertext: ciphertext)

        let result = try await sut.downloadEncrypted(for: Fixture.doc(id: "d1"))

        XCTAssertEqual(result.ciphertext, ciphertext)
        XCTAssertEqual(result.sealedDEK, sealed)
    }

    // MARK: - Helpers

    private func stubContent(sealedKey: String, ciphertext: Data) {
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/key") == true {
                return (ok, Data(#"{"encryptedFileKey":"\#(sealedKey)"}"#.utf8))
            }
            return (ok, ciphertext)
        }
    }

    /// Pulls the `file` part's bytes back out of a multipart body, so a test can assert on what was
    /// actually uploaded rather than on the framing around it.
    static func extractFilePart(from body: Data) -> Data? {
        // The part's payload starts after the blank line following its headers, and ends at the
        // CRLF before the next boundary.
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = body.range(of: separator, options: [], in: body.startIndex..<body.endIndex) else {
            return nil
        }
        var searchStart = headerEnd.upperBound
        // Skip past the scalar fields to the last part, which is the file.
        while let next = body.range(of: separator, options: [], in: searchStart..<body.endIndex) {
            searchStart = next.upperBound
        }
        let boundaryMarker = Data("\r\n--".utf8)
        guard let tail = body.range(of: boundaryMarker, options: [], in: searchStart..<body.endIndex) else {
            return nil
        }
        return body.subdata(in: searchStart..<tail.lowerBound)
    }
}
