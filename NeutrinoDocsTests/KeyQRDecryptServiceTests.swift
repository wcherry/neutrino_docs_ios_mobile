import XCTest
import CryptoKit
import CommonCrypto
import Foundation
import Sodium
import NeutrinoCrypto
@testable import NeutrinoDocs

/// Tests for `KeyQRDecryptService`.
///
/// `makeQRString` performs genuine PBKDF2-SHA256 key derivation and XSalsa20-Poly1305 encryption
/// with swift-sodium, mirroring the envelope the web app produces, so the happy path exercises a
/// real cryptographic round-trip rather than fixture data.
final class KeyQRDecryptServiceTests: XCTestCase {

    // MARK: - Helpers

    private let sodium = Sodium()

    /// A real P-256 key pair serialised the way the web app exports it, so the decrypted payload
    /// also survives `KeyImportService.importKey`'s pair validation.
    private func makeKeyPairJSON() -> String {
        let privateKey = P256.Signing.PrivateKey()
        let dict: [String: String] = [
            "public_key":  privateKey.publicKey.x963Representation.base64EncodedString(),
            "private_key": privateKey.rawRepresentation.base64EncodedString(),
            "key_version": "1",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        return String(data: data, encoding: .utf8)!
    }

    /// Encrypts `plaintextJSON` under `pin` with the protocol `decrypt` must reverse, returning the
    /// outer QR JSON. The iteration count is deliberately low so the tests stay fast.
    private func makeQRString(plaintextJSON: String, pin: String, iterations: Int = 1000) -> String {
        let saltData  = Data(sodium.randomBytes.buf(length: 16)!)
        let nonceData = Data(sodium.randomBytes.buf(length: 24)!)

        let key = pbkdf2SHA256(password: pin, salt: saltData, iterations: iterations, keyLength: 32)

        guard let cipherBytes = sodium.secretBox.seal(
            message: Array(plaintextJSON.utf8),
            secretKey: Array(key),
            nonce: Array(nonceData)
        ) else {
            XCTFail("XSalsa20-Poly1305 encryption failed in test helper")
            return "{}"
        }

        let outerDict: [String: Any] = [
            "v":     1,
            "alg":   "pbkdf2-sha256+xsalsa20",
            "salt":  base64URL(saltData),
            "nonce": base64URL(nonceData),
            "ct":    base64URL(Data(cipherBytes)),
            "iter":  iterations,
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outerDict)
        return String(data: outerData, encoding: .utf8)!
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(repeating: 0, count: keyLength)

        _ = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return derivedKey
    }

    // MARK: - Happy Path

    /// The correct PIN returns the exact bytes that were encrypted, and those bytes are a key file
    /// `KeyImportService` accepts — the two halves of the QR import path meeting.
    func test_decrypt_withValidQRAndCorrectPIN_returnsKeyPairData() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString      = makeQRString(plaintextJSON: plaintextJSON, pin: "test-pin-1234")

        let resultData = try KeyQRDecryptService.decrypt(qrString: qrString, pin: "test-pin-1234")

        XCTAssertEqual(resultData, Data(plaintextJSON.utf8))

        let bundle = try KeyImportService.importKey(from: resultData)
        XCTAssertEqual(bundle.keyVersion, "1")
        XCTAssertFalse(bundle.publicKey.isEmpty)
        XCTAssertFalse(bundle.privateKey.isEmpty)
    }

    /// The QR envelope is shared with the sibling apps, where `v` has been seen as a string.
    func test_decrypt_withStringVersionField_succeeds() throws {
        let plaintextJSON = makeKeyPairJSON()
        let qrString = makeQRString(plaintextJSON: plaintextJSON, pin: "pin")
        var json = try JSONSerialization.jsonObject(with: Data(qrString.utf8)) as! [String: Any]
        json["v"] = "1"
        let restrung = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!

        XCTAssertEqual(try KeyQRDecryptService.decrypt(qrString: restrung, pin: "pin"),
                       Data(plaintextJSON.utf8))
    }

    // MARK: - Wrong PIN

    /// A different PIN derives a different key, so the Poly1305 tag fails to verify.
    func test_decrypt_withWrongPIN_throwsDecryptionFailure() {
        let qrString = makeQRString(plaintextJSON: makeKeyPairJSON(), pin: "correct-pin")

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "wrong-pin")
        ) { error in
            guard case KeyQRDecryptError.decryptionFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.decryptionFailure, got \(error)")
            }
        }
    }

    // MARK: - Malformed Payload

    /// A field that isn't valid Base64 must fail before any cryptographic work is attempted.
    func test_decrypt_withInvalidBase64Field_throwsBase64DecodeFailure() {
        let qrString = makeOuterJSON(["v": 1,
                                      "alg": "pbkdf2-sha256+xsalsa20",
                                      "salt": "not valid base64!!!",
                                      "nonce": "dGVzdA",
                                      "ct": "dGVzdA"])

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.base64DecodeFailure = error else {
                return XCTFail("Expected KeyQRDecryptError.base64DecodeFailure, got \(error)")
            }
        }
    }

    // MARK: - Unsupported Envelope

    /// A future envelope version must be reported as such rather than half-decoded.
    func test_decrypt_withUnsupportedVersion_throwsUnsupportedVersion() {
        let qrString = makeOuterJSON(["v": 99,
                                      "alg": "pbkdf2-sha256+xsalsa20",
                                      "salt": "dGVzdA",
                                      "nonce": "dGVzdA",
                                      "ct": "dGVzdA"])

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedVersion = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedVersion, got \(error)")
            }
        }
    }

    /// Likewise for an algorithm this build has no implementation for.
    func test_decrypt_withUnsupportedAlgorithm_throwsUnsupportedAlgorithm() {
        let qrString = makeOuterJSON(["v": 1,
                                      "alg": "aes-gcm",
                                      "salt": "dGVzdA",
                                      "nonce": "dGVzdA",
                                      "ct": "dGVzdA"])

        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: qrString, pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.unsupportedAlgorithm = error else {
                return XCTFail("Expected KeyQRDecryptError.unsupportedAlgorithm, got \(error)")
            }
        }
    }

    // MARK: - Garbage QR String

    /// Scanning some other app's QR code must say so, not fail as a decryption error.
    func test_decrypt_withGarbageQRString_throwsInvalidQRFormat() {
        XCTAssertThrowsError(
            try KeyQRDecryptService.decrypt(qrString: "not json at all", pin: "any-pin")
        ) { error in
            guard case KeyQRDecryptError.invalidQRFormat = error else {
                return XCTFail("Expected KeyQRDecryptError.invalidQRFormat, got \(error)")
            }
        }
    }

    // MARK: - Private

    private func makeOuterJSON(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }
}
