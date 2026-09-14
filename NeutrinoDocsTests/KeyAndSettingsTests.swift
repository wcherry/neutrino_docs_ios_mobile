import XCTest
import CryptoKit
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
@testable import NeutrinoDocs

// MARK: - KeychainServiceTests

/// Supports **Login** and the encryption deliverables: the store both depend on.
final class KeychainServiceTests: XCTestCase {

    private let key = "ndoc.tests.value"

    override func setUp() {
        super.setUp()
        KeychainService.delete(forKey: key)
    }

    override func tearDown() {
        KeychainService.delete(forKey: key)
        super.tearDown()
    }

    func testSaveThenLoadReturnsTheValue() {
        XCTAssertTrue(KeychainService.save("hello", forKey: key))
        XCTAssertEqual(KeychainService.load(forKey: key), "hello")
    }

    func testLoadingAnAbsentKeyReturnsNil() {
        XCTAssertNil(KeychainService.load(forKey: "ndoc.tests.definitely-absent"))
    }

    /// Saving twice must update rather than fail with a duplicate-item error.
    func testSavingOverAnExistingValueUpdatesIt() {
        KeychainService.save("first", forKey: key)

        XCTAssertTrue(KeychainService.save("second", forKey: key))
        XCTAssertEqual(KeychainService.load(forKey: key), "second")
    }

    func testDeleteRemovesTheValue() {
        KeychainService.save("hello", forKey: key)

        XCTAssertTrue(KeychainService.delete(forKey: key))
        XCTAssertNil(KeychainService.load(forKey: key))
    }

    func testUnicodeAndLongValuesRoundTrip() {
        let value = "🔐 " + String(repeating: "x", count: 4096)
        KeychainService.save(value, forKey: key)
        XCTAssertEqual(KeychainService.load(forKey: key), value)
    }

    func testDifferentKeysDoNotCollide() {
        let other = "ndoc.tests.other"
        defer { KeychainService.delete(forKey: other) }

        KeychainService.save("a", forKey: key)
        KeychainService.save("b", forKey: other)

        XCTAssertEqual(KeychainService.load(forKey: key), "a")
        XCTAssertEqual(KeychainService.load(forKey: other), "b")
    }
}

// MARK: - KeyImportServiceTests

/// Phase 1 — Encryption: "Import user key", "Store in Keychain", "Automatic key loading".
final class KeyImportServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        KeyImportService.removeKeys()
        super.tearDown()
    }

    // MARK: Parsing

    func testAValidKeyFileImports() throws {
        let bundle = try KeyImportService.importKey(from: TestKeys.keyFileJSON())

        XCTAssertFalse(bundle.publicKey.isEmpty)
        XCTAssertFalse(bundle.privateKey.isEmpty)
        XCTAssertEqual(bundle.keyVersion, "1")
    }

    /// The web app has used both spellings; both have to work or an older export stops importing.
    func testShortFieldNamesAreAccepted() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let json = try JSONSerialization.data(withJSONObject: [
            "pk": TestKeys.base64URL(priv.publicKey.rawRepresentation),
            "sk": TestKeys.base64URL(priv.rawRepresentation),
            "v": "2",
        ])

        let bundle = try KeyImportService.importKey(from: json)

        XCTAssertEqual(bundle.keyVersion, "2")
    }

    func testAMissingKeyVersionDefaultsToOne() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let json = try JSONSerialization.data(withJSONObject: [
            "public_key": TestKeys.base64URL(priv.publicKey.rawRepresentation),
            "private_key": TestKeys.base64URL(priv.rawRepresentation),
        ])

        XCTAssertEqual(try KeyImportService.importKey(from: json).keyVersion, "1")
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try KeyImportService.importKey(from: Data("{ not json".utf8))) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidJSON)
        }
    }

    func testMissingFieldsAreRejected() {
        let json = Data(#"{"public_key":"abc"}"#.utf8)
        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .missingFields)
        }
    }

    /// PEM is the wrong export from the web app; saying so beats a confusing Base64 failure.
    func testPEMKeysAreRejectedWithASpecificMessage() {
        let json = Data("""
        {"public_key":"-----BEGIN PUBLIC KEY-----\\nabc\\n-----END PUBLIC KEY-----",
         "private_key":"-----BEGIN PRIVATE KEY-----\\nxyz\\n-----END PRIVATE KEY-----"}
        """.utf8)

        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .unsupportedFormat)
        }
    }

    func testInvalidBase64IsRejected() {
        let json = Data(#"{"public_key":"not base64 !!!","private_key":"also not !!!"}"#.utf8)
        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidBase64)
        }
    }

    /// The important validation: two halves that are individually well-formed but do not belong
    /// together would produce a key that silently fails to decrypt anything.
    func testMismatchedKeyPairsAreRejected() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let json = try JSONSerialization.data(withJSONObject: [
            "public_key": TestKeys.base64URL(a.publicKey.rawRepresentation),
            "private_key": TestKeys.base64URL(b.rawRepresentation),
        ])

        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .keyPairMismatch)
        }
    }

    func testEd25519PairsAreAlsoAccepted() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let json = try JSONSerialization.data(withJSONObject: [
            "public_key": TestKeys.base64URL(priv.publicKey.rawRepresentation),
            "private_key": TestKeys.base64URL(priv.rawRepresentation),
        ])

        XCTAssertNoThrow(try KeyImportService.importKey(from: json))
    }

    func testStandardBase64WithPaddingIsAccepted() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let json = try JSONSerialization.data(withJSONObject: [
            "public_key": priv.publicKey.rawRepresentation.base64EncodedString(),
            "private_key": priv.rawRepresentation.base64EncodedString(),
        ])

        XCTAssertNoThrow(try KeyImportService.importKey(from: json))
    }

    // MARK: Storage

    func testStoredKeysAreReadBackVerbatim() throws {
        let bundle = try KeyImportService.importKey(from: TestKeys.keyFileJSON())

        KeyImportService.storeKeys(bundle)

        XCTAssertTrue(KeyImportService.hasStoredKeys())
        // Verbatim matters: re-encoding risks no longer matching the registered public key.
        XCTAssertEqual(KeyImportService.storedKeys(), bundle)
    }

    func testHasStoredKeysIsFalseUntilAllThreePartsExist() throws {
        XCTAssertFalse(KeyImportService.hasStoredKeys())

        KeychainService.save("pub", forKey: KeyImportService.publicKeyKeychainKey)
        XCTAssertFalse(KeyImportService.hasStoredKeys(), "A partial import is not an import")

        KeychainService.save("priv", forKey: KeyImportService.privateKeyKeychainKey)
        KeychainService.save("1", forKey: KeyImportService.keyVersionKeychainKey)
        XCTAssertTrue(KeyImportService.hasStoredKeys())
    }

    func testRemoveKeysClearsEveryPart() throws {
        KeyImportService.storeKeys(try KeyImportService.importKey(from: TestKeys.keyFileJSON()))

        KeyImportService.removeKeys()

        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertNil(KeyImportService.storedKeys())
    }

    func testDocsKeysDoNotCollideWithTheSiblingApps() {
        // Drive uses `nd.*` and Notes uses `nn.*`; Docs must not overwrite either on a device that
        // has all three installed.
        XCTAssertTrue(KeyImportService.publicKeyKeychainKey.hasPrefix("ndoc."))
        XCTAssertTrue(AuthService.accessTokenKey.hasPrefix("ndoc."))
    }
}

// MARK: - AppSettingsTests

/// Phase 1 — Settings: theme, font size, editor font, auto-save interval, sync settings.
@MainActor
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsMatchThePhaseOneIntent() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.theme, .system)
        XCTAssertEqual(settings.editorFont, .monospaced, "Code and tables need a fixed pitch")
        XCTAssertEqual(settings.fontSize, AppSettings.defaultFontSize)
        XCTAssertEqual(settings.autoSaveInterval, AppSettings.defaultAutoSaveInterval)
        XCTAssertTrue(settings.autoSyncEnabled)
        XCTAssertTrue(settings.cacheRecents)
        XCTAssertTrue(settings.cacheFavorites)
    }

    func testEverySettingPersists() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        settings.fontSize = 20
        settings.editorFont = .serif
        settings.autoSaveInterval = 10
        settings.autoSyncEnabled = false
        settings.syncOnCellular = false
        settings.cacheRecents = false
        settings.cacheFavorites = false

        let reloaded = AppSettings(defaults: defaults)

        XCTAssertEqual(reloaded.theme, .dark)
        XCTAssertEqual(reloaded.fontSize, 20)
        XCTAssertEqual(reloaded.editorFont, .serif)
        XCTAssertEqual(reloaded.autoSaveInterval, 10)
        XCTAssertFalse(reloaded.autoSyncEnabled)
        XCTAssertFalse(reloaded.syncOnCellular)
        XCTAssertFalse(reloaded.cacheRecents)
        XCTAssertFalse(reloaded.cacheFavorites)
    }

    func testFontSizeIsClampedOnWrite() {
        let settings = AppSettings(defaults: defaults)

        settings.fontSize = 999
        XCTAssertEqual(settings.fontSize, AppSettings.fontSizeRange.upperBound)

        settings.fontSize = -5
        XCTAssertEqual(settings.fontSize, AppSettings.fontSizeRange.lowerBound)
    }

    /// The value also arrives from `UserDefaults`, where a stale build could have left anything.
    func testAnOutOfRangeStoredFontSizeIsClampedOnLoad() {
        defaults.set(500.0, forKey: AppSettings.Keys.fontSize)

        XCTAssertEqual(AppSettings(defaults: defaults).fontSize, AppSettings.fontSizeRange.upperBound)
    }

    func testThemeMapsToAColorScheme() {
        XCTAssertNil(AppTheme.system.colorScheme, "System follows the device")
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testResetRestoresEveryDefault() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        settings.fontSize = 22
        settings.editorFont = .rounded
        settings.autoSyncEnabled = false

        settings.resetToDefaults()

        XCTAssertEqual(settings.theme, .system)
        XCTAssertEqual(settings.fontSize, AppSettings.defaultFontSize)
        XCTAssertEqual(settings.editorFont, .monospaced)
        XCTAssertTrue(settings.autoSyncEnabled)
    }

    func testAutoSaveOptionsAreLabelledReadably() {
        XCTAssertEqual(AppSettings.autoSaveLabel(for: 1), "Every second")
        XCTAssertEqual(AppSettings.autoSaveLabel(for: 5), "Every 5 seconds")
    }

    func testTheDefaultAutoSaveIntervalIsSelectable() {
        XCTAssertTrue(AppSettings.autoSaveIntervalOptions.contains(AppSettings.defaultAutoSaveInterval),
                      "A default the picker cannot show would silently reset on first edit")
    }

    func testEditorFontHonoursBothFaceAndSize() {
        let settings = AppSettings(defaults: defaults)
        settings.fontSize = 20
        settings.editorFont = .monospaced

        let font = settings.editorUIFont

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertGreaterThan(font.pointSize, 0)
    }

    /// Until the user picks an order, each section keeps its own: Recent newest-first, Home A–Z.
    func testAnUnchosenSortOrderLeavesEverySectionOnItsOwnDefault() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(settings.sortOrder)
        XCTAssertEqual(settings.sortOrder(for: .recent), .newest)
        XCTAssertEqual(settings.sortOrder(for: .home), .nameAscending)
    }

    /// Once chosen, the order is the user's answer for every listing — including Recent.
    func testAChosenSortOrderAppliesToEverySectionAndPersists() {
        let settings = AppSettings(defaults: defaults)
        settings.sortOrder = .nameDescending

        for section in DocsSection.allCases {
            XCTAssertEqual(settings.sortOrder(for: section), .nameDescending, section.rawValue)
        }
        XCTAssertEqual(AppSettings(defaults: defaults).sortOrder, .nameDescending)
    }

    func testResetForgetsTheChosenSortOrder() {
        let settings = AppSettings(defaults: defaults)
        settings.sortOrder = .oldest

        settings.resetToDefaults()

        XCTAssertNil(settings.sortOrder)
        XCTAssertNil(AppSettings(defaults: defaults).sortOrder,
                     "A reset has to clear the stored value, not just the one in memory")
        XCTAssertEqual(settings.sortOrder(for: .recent), .newest)
    }

    /// A value left by another build is not a reason to start up with no listing order at all.
    func testAnUnrecognisedStoredSortOrderFallsBackToTheSectionDefaults() {
        defaults.set("byColour", forKey: AppSettings.Keys.sortOrder)

        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(settings.sortOrder)
        XCTAssertEqual(settings.sortOrder(for: .home), .nameAscending)
    }

    func testSettingsAreIsolatedFromTheRealPreferences() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark

        XCTAssertNil(UserDefaults.standard.string(forKey: AppSettings.Keys.theme),
                     "Tests must not disturb the user's own settings")
    }
}

// MARK: - DeviceIdentityTests

/// Phase 1 — Authentication: "Device registration".
final class DeviceIdentityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeviceIdentity.setDeviceName(nil)
    }

    override func tearDown() {
        DeviceIdentity.setDeviceName(nil)
        super.tearDown()
    }

    /// Drive, Notes, and Docs all report the same `UIDevice.name`; without the app suffix the
    /// account's device list cannot tell them apart.
    func testTheDefaultDeviceNameIdentifiesThisApp() {
        XCTAssertTrue(DeviceIdentity.deviceName.contains("Neutrino Docs"))
    }

    func testAUserSetNameWins() {
        DeviceIdentity.setDeviceName("Work iPad")
        XCTAssertEqual(DeviceIdentity.deviceName, "Work iPad")
    }

    func testABlankNameFallsBackToTheDefault() {
        DeviceIdentity.setDeviceName("   ")
        XCTAssertTrue(DeviceIdentity.deviceName.contains("Neutrino Docs"))
    }

    func testClearingRestoresTheDefault() {
        DeviceIdentity.setDeviceName("Work iPad")
        DeviceIdentity.setDeviceName(nil)
        XCTAssertTrue(DeviceIdentity.deviceName.contains("Neutrino Docs"))
    }

    func testTheRegistrationHeaderIsTheOneTheServerReads() {
        // src/auth/api.rs reads `X-Device-Name` off the login request.
        XCTAssertEqual(DeviceIdentity.deviceNameHeader, "X-Device-Name")
    }
}

// MARK: - DeviceSessionTests

final class DeviceSessionTests: XCTestCase {

    override func tearDown() {
        DeviceIdentity.setDeviceName(nil)
        super.tearDown()
    }

    func testSessionsDecodeFromTheServerShape() throws {
        let json = Data("""
        {"sessions":[{"id":"s1","deviceName":"Will's iPhone — Neutrino Docs",
                      "userAgent":"NeutrinoDocs/1.0","ipAddress":"10.0.0.1",
                      "createdAt":"2026-07-30T14:25:36.123456",
                      "lastUsedAt":"2026-08-01T09:00:00.000000"}]}
        """.utf8)
        struct Response: Decodable { let sessions: [DeviceSession] }

        let sessions = try DeviceSession.decoder.decode(Response.self, from: json).sessions

        XCTAssertEqual(sessions.first?.id, "s1")
        XCTAssertEqual(sessions.first?.deviceName, "Will's iPhone — Neutrino Docs")
        XCTAssertNotNil(sessions.first?.lastUsedAt)
    }

    func testANullDeviceNameDecodesAndFallsBackForDisplay() throws {
        let json = Data("""
        {"id":"s1","deviceName":null,"userAgent":"curl/8.0","ipAddress":null,
         "createdAt":"2026-07-30T14:25:36.123456","lastUsedAt":null}
        """.utf8)

        let session = try DeviceSession.decoder.decode(DeviceSession.self, from: json)

        XCTAssertEqual(session.displayName, "curl/8.0", "Never leave the row blank")
    }

    func testAnEntirelyAnonymousSessionStillHasALabel() {
        let session = DeviceSession(id: "s1", deviceName: nil, userAgent: nil,
                                    createdAt: Date())
        XCTAssertEqual(session.displayName, "Unknown device")
    }

    /// The server does not mark the caller's own session, so the registered name is the only join
    /// available.
    func testTheCurrentDeviceIsRecognisedByItsRegisteredName() {
        DeviceIdentity.setDeviceName("This Device")

        let mine = DeviceSession(id: "s1", deviceName: "This Device", createdAt: Date())
        let theirs = DeviceSession(id: "s2", deviceName: "Someone Else's iPad", createdAt: Date())

        XCTAssertTrue(mine.isCurrentDevice)
        XCTAssertFalse(theirs.isCurrentDevice)
    }

    func testLastUsedTextDistinguishesUsedFromMerelyRegistered() {
        let used = DeviceSession(id: "s1", deviceName: "x", createdAt: Date(),
                                 lastUsedAt: Date())
        let never = DeviceSession(id: "s2", deviceName: "y", createdAt: Date())

        XCTAssertTrue(used.lastUsedText.hasPrefix("Last used"))
        XCTAssertTrue(never.lastUsedText.hasPrefix("Registered"))
    }
}
