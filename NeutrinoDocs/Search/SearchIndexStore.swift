import Foundation
import Sodium
import os.log

// MARK: - SearchIndexStore

/// Persists the search index, encrypted at rest.
///
/// The index is derived from decrypted documents — terms, titles, headings, tags and a short
/// preview — so writing it to disk in the clear would undo the cache-at-rest guarantee the offline
/// store goes to such lengths for. It is sealed with an XChaCha20-Poly1305 secretstream under a key
/// this app generates once and keeps in the Keychain, alongside the E2EE key pair and with the same
/// `AfterFirstUnlockThisDeviceOnly` protection: readable by background sync, never in an iCloud
/// backup, never off this device.
///
/// The index key is *not* the user's E2EE key and is never sent anywhere. It protects a local
/// derivative of documents the user can already read; sharing it would serve no purpose, and
/// deriving it from the E2EE key would tie a local cache's lifetime to a key that may be rotated.
@MainActor
final class SearchIndexStore {

    // MARK: - Keychain

    /// Where the index key lives. Deleting this item makes the stored index unreadable, which is
    /// exactly what should happen when the user signs out.
    static let indexKeyKeychainKey = "com.neutrino.docs.searchIndexKey"

    // MARK: - Private

    private static let sodium = Sodium()
    private static let secretStreamHeaderSize = 24

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoDocs",
                                category: "SearchIndexStore")

    private let directory: URL
    private static let indexFileName = "index.bin"
    private static let savedSearchesFileName = "searches.bin"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Init

    /// - Parameter directory: `nil` uses Application Support/SearchIndex. Tests pass a temp directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        prepareDirectory()
    }

    // MARK: - Load / Save

    /// Reads the stored index, or an empty one when there is nothing readable on disk.
    ///
    /// A missing key, a corrupt file, or a file written under a key that has since been replaced
    /// all mean the same thing operationally — there is no index — and all resolve the same way:
    /// start empty and let `SearchService` rebuild. The index is a cache of documents the server
    /// still holds, so losing it costs time and never data.
    func load() -> SearchIndex {
        guard var index: SearchIndex = read(Self.indexFileName) else { return SearchIndex() }
        index.prepareForQuerying()
        logger.debug("load: \(index.documentCount) documents")
        return index
    }

    func save(_ index: SearchIndex) throws {
        try write(index, to: Self.indexFileName)
        logger.debug("save: \(index.documentCount) documents")
    }

    // MARK: - Saved searches

    func loadSavedSearches() -> [SavedSearch] {
        read(Self.savedSearchesFileName) ?? []
    }

    func save(savedSearches: [SavedSearch]) throws {
        try write(savedSearches, to: Self.savedSearchesFileName)
    }

    // MARK: - Sign-out

    /// Drops everything stored and the key itself. Called on sign-out: the index describes
    /// documents the signed-out account could read, and the next account must not inherit it.
    func destroy() {
        try? FileManager.default.removeItem(at: url(for: Self.indexFileName))
        try? FileManager.default.removeItem(at: url(for: Self.savedSearchesFileName))
        _ = KeychainService.delete(forKey: Self.indexKeyKeychainKey)
        logger.debug("destroy: stored index, saved searches, and key removed")
    }

    // MARK: - Encrypted files

    /// Reads and decrypts one file, or nil when there is nothing readable there.
    ///
    /// A missing key, a corrupt file, and a file written under a key that has since been replaced
    /// all mean the same thing operationally — there is nothing here — and all resolve the same
    /// way. What is stored is a cache of documents the server still holds, so losing it costs time
    /// and never data.
    private func read<T: Decodable>(_ fileName: String) -> T? {
        let url = url(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let key = loadKey(createIfMissing: false),
              let ciphertext = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            return try Self.decoder.decode(T.self, from: try decrypt(ciphertext, key: key))
        } catch {
            logger.error("read \(fileName, privacy: .public): unreadable, discarding: \(error, privacy: .public)")
            // A file we cannot read is a file we will never be able to read; leaving it in place
            // would mean failing this way on every launch.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to fileName: String) throws {
        guard let key = loadKey(createIfMissing: true) else {
            throw SearchIndexStoreError.noIndexKey
        }
        let ciphertext = try encrypt(try Self.encoder.encode(value), key: key)
        do {
            try ciphertext.write(to: url(for: fileName),
                                 options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            throw SearchIndexStoreError.ioFailure(underlying: error)
        }
    }

    // MARK: - Key

    /// The index key, generated on first use.
    ///
    /// - Parameter createIfMissing: false when loading — a read must not mint a key, because doing
    ///   so would quietly replace the one that could have decrypted an index written earlier.
    private func loadKey(createIfMissing: Bool) -> Bytes? {
        if let stored = KeychainService.load(forKey: Self.indexKeyKeychainKey),
           let data = Data(base64Encoded: stored) {
            return Array(data)
        }
        guard createIfMissing else { return nil }

        let key = Self.sodium.secretStream.xchacha20poly1305.key()
        guard KeychainService.save(Data(key).base64EncodedString(),
                                   forKey: Self.indexKeyKeychainKey) else {
            logger.error("loadKey: could not store a new index key")
            return nil
        }
        logger.debug("loadKey: generated a new index key")
        return key
    }

    // MARK: - Crypto

    /// Same framing as a document body — `[24-byte header][ciphertext]` — so there is one shape of
    /// encrypted blob on this device rather than two.
    private func encrypt(_ data: Data, key: Bytes) throws -> Data {
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        guard let stream = xcss.initPush(secretKey: key),
              let cipher = stream.push(message: Array(data), tag: .FINAL) else {
            throw SearchIndexStoreError.encryptionFailed
        }
        return Data(stream.header() + cipher)
    }

    private func decrypt(_ data: Data, key: Bytes) throws -> Data {
        guard data.count > Self.secretStreamHeaderSize else {
            throw SearchIndexStoreError.decryptionFailed
        }
        let header = Array(data.prefix(Self.secretStreamHeaderSize))
        let body = Array(data.dropFirst(Self.secretStreamHeaderSize))

        guard let pull = Self.sodium.secretStream.xchacha20poly1305.initPull(secretKey: key,
                                                                            header: header),
              let (plaintext, _) = pull.pull(cipherText: body) else {
            throw SearchIndexStoreError.decryptionFailed
        }
        return Data(plaintext)
    }

    // MARK: - Paths

    private func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SearchIndex", isDirectory: true)
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - SearchIndexStoreError

enum SearchIndexStoreError: LocalizedError {
    case noIndexKey
    case encryptionFailed
    case decryptionFailed
    case ioFailure(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noIndexKey:         return "Could not access the search index key."
        case .encryptionFailed:   return "Failed to encrypt the search index."
        case .decryptionFailed:   return "Failed to decrypt the search index."
        case .ioFailure(let err): return "Search index storage error: \(err.localizedDescription)"
        }
    }
}
