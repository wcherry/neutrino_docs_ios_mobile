import Foundation
import CryptoKit

// MARK: - KeyBundle

struct KeyBundle: Equatable {
    let publicKey: String
    let privateKey: String
    /// Which keyring version this keypair *is* — `user_public_keys.version` on
    /// the server, and what a file's key ref names. The web app's mobile key
    /// code carries it, so on a rotated account it is not "1".
    let keyVersion: String
}

// MARK: - KeyLookup

/// The result of resolving a file's key version against this device.
///
/// Three outcomes, not two, because "this device has no key" and "this device
/// has a key but not *that* one" send the user to different places: the first
/// means import a key, the second means the account rotated and this device's
/// archive is incomplete. Collapsing them into a nil is how a rotation turns
/// into an unexplained decrypt failure.
enum KeyLookup: Equatable {
    case found(publicKey: String, privateKey: String)
    case noKey
    case missingVersion(Int)
}

// MARK: - KeyImportError

enum KeyImportError: LocalizedError, Equatable {
    case invalidJSON
    case missingFields
    case invalidBase64
    case keyPairMismatch
    /// PEM detected — the web app exports raw/X9.63 Base64, so a PEM file is the wrong export.
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidJSON:       return "The file is not valid JSON."
        case .missingFields:     return "The key file is missing required fields."
        case .invalidBase64:     return "One or more keys contain invalid Base64 data."
        case .keyPairMismatch:   return "The public key and private key do not form a matching pair."
        case .unsupportedFormat: return "PEM-encoded keys are not supported. Please use raw or X9.63 Base64 encoding."
        }
    }
}

// MARK: - KeyImportService

/// Imports the user's end-to-end encryption key pair from the JSON file the Neutrino web app
/// exports, validates it, and stores it in the Keychain.
///
/// The same key pair is used by Drive, Notes, and Docs — a document encrypted on the web is
/// readable here and vice versa — so this deliberately mirrors the sibling apps' import format
/// rather than inventing one.
enum KeyImportService {

    // MARK: - Keychain keys

    static let publicKeyKeychainKey  = "ndoc.encryption.public_key"
    static let privateKeyKeychainKey = "ndoc.encryption.private_key"
    static let keyVersionKeychainKey = "ndoc.encryption.key_version"

    // MARK: - Import

    /// Parses and validates JSON containing a key pair. Throws `KeyImportError` on any failure.
    static func importKey(from data: Data) throws -> KeyBundle {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KeyImportError.invalidJSON
        }

        // Accepts both the long and short field spellings the web app has used.
        guard let dict = parsed as? [String: String] else { throw KeyImportError.missingFields }
        guard
            let publicKeyString  = dict["public_key"]  ?? dict["pk"],
            let privateKeyString = dict["private_key"] ?? dict["sk"]
        else {
            throw KeyImportError.missingFields
        }
        let keyVersionString = dict["key_version"] ?? dict["v"] ?? "1"

        if publicKeyString.hasPrefix("-----BEGIN") || privateKeyString.hasPrefix("-----BEGIN") {
            throw KeyImportError.unsupportedFormat
        }

        let pubData  = try decodeBase64(publicKeyString)
        let privData = try decodeBase64(privateKeyString)

        guard validateKeyPair(pubData: pubData, privData: privData) else {
            throw KeyImportError.keyPairMismatch
        }

        // The original strings are kept verbatim: they are what the server issued, and
        // re-encoding them risks a round-trip that no longer matches the registered public key.
        return KeyBundle(publicKey: publicKeyString,
                         privateKey: privateKeyString,
                         keyVersion: keyVersionString)
    }

    // MARK: - Storage

    /// Persists a validated bundle to the Keychain.
    static func storeKeys(_ bundle: KeyBundle) {
        KeychainService.save(bundle.publicKey,  forKey: publicKeyKeychainKey)
        KeychainService.save(bundle.privateKey, forKey: privateKeyKeychainKey)
        KeychainService.save(bundle.keyVersion, forKey: keyVersionKeychainKey)
    }

    /// True when all three entries are present — Phase 1's "Automatic key loading" is simply that
    /// the services read them straight from the Keychain on demand, so there is nothing to load.
    static func hasStoredKeys() -> Bool {
        KeychainService.load(forKey: publicKeyKeychainKey)  != nil &&
        KeychainService.load(forKey: privateKeyKeychainKey) != nil &&
        KeychainService.load(forKey: keyVersionKeychainKey) != nil
    }

    /// Reads the stored bundle back, or nil when any part is missing.
    static func storedKeys() -> KeyBundle? {
        guard let publicKey = KeychainService.load(forKey: publicKeyKeychainKey),
              let privateKey = KeychainService.load(forKey: privateKeyKeychainKey),
              let keyVersion = KeychainService.load(forKey: keyVersionKeychainKey) else {
            return nil
        }
        return KeyBundle(publicKey: publicKey, privateKey: privateKey, keyVersion: keyVersion)
    }

    /// The version new work is sealed to.
    ///
    /// Defaults to 1 for a key stored before the field meant anything — which is
    /// also what the server defaults `file_key_refs.key_version` to, so the two
    /// agree about a pre-rotation account.
    static func activeKeyVersion() -> Int {
        Int(KeychainService.load(forKey: keyVersionKeychainKey) ?? "") ?? 1
    }

    // MARK: - Version resolution

    /// The keypair that opens a DEK sealed to `version`.
    ///
    /// Checks the active key first — it is the one nearly every read wants — and
    /// falls back to the retired keys `KeyFileService` pulled down. A version
    /// that is in neither is reported by number rather than as a bare failure,
    /// because "this document needs key version 2" is actionable and "could not
    /// decrypt" is not.
    static func keyPair(forVersion version: Int) -> KeyLookup {
        guard let active = storedKeys() else { return .noKey }
        if activeKeyVersion() == version {
            return .found(publicKey: active.publicKey, privateKey: active.privateKey)
        }
        if let archived = KeyArchive.keyPair(forVersion: version) {
            return .found(publicKey: archived.publicKey, privateKey: archived.privateKey)
        }
        return .missingVersion(version)
    }

    static func removeKeys() {
        KeychainService.delete(forKey: publicKeyKeychainKey)
        KeychainService.delete(forKey: privateKeyKeychainKey)
        KeychainService.delete(forKey: keyVersionKeychainKey)
        // The retired keys are worth no less than the active one and are opened
        // by the same person; forgetting the identity has to forget all of it.
        KeyArchive.clear()
    }

    // MARK: - Validation

    /// True when the two halves form a real key pair. Tries X25519, then Ed25519, then P-256.
    private static func validateKeyPair(pubData: Data, privData: Data) -> Bool {
        // X25519: derive the public key from the private one and compare.
        //
        // Constructing a Curve25519 key never throws for any 32-byte input — raw keys are just
        // clamped scalars — so a non-matching result here has to fall through to the other key
        // types rather than return false immediately.
        if let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privData),
           priv.publicKey.rawRepresentation == pubData {
            return true
        }
        if let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData),
           priv.publicKey.rawRepresentation == pubData {
            return true
        }
        // P-256 exposes no way to derive the public key from a raw private one, so the pairing is
        // proved by signing with one half and verifying with the other.
        let p256priv = (try? P256.Signing.PrivateKey(rawRepresentation: privData))
                    ?? (try? P256.Signing.PrivateKey(x963Representation: privData))
        let p256pub  = (try? P256.Signing.PublicKey(rawRepresentation: pubData))
                    ?? (try? P256.Signing.PublicKey(x963Representation: pubData))
        if let priv = p256priv, let pub = p256pub,
           let signature = try? priv.signature(for: Data(validationPayload.utf8)) {
            return pub.isValidSignature(signature, for: Data(validationPayload.utf8))
        }
        return false
    }

    private static let validationPayload = "neutrino-key-validation"

    /// Converts Base64URL to standard Base64 and decodes.
    private static func decodeBase64(_ input: String) throws -> Data {
        var standard = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: standard) else {
            throw KeyImportError.invalidBase64
        }
        return decoded
    }
}
