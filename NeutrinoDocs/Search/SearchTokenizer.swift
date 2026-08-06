import Foundation

// MARK: - SearchTokenizer

/// Splits text into the terms the index stores.
///
/// The rules deliberately match the web app's tokenizer (`@neutrino/search`) — NFC normalize,
/// lowercase, replace anything that is neither a letter nor a number with a space, split on
/// whitespace. Two clients indexing the same document have to produce the same terms, or a query
/// typed on a phone would find a different set of documents than the same query typed in a browser.
///
/// Terms are stored as plain text. Hashing them would make the index opaque at rest but would also
/// destroy the shared prefix between "mod" and "modesto", which is what prefix search ranges over;
/// the index is protected by being encrypted as a whole instead (see `SearchIndexStore`).
enum SearchTokenizer {

    /// Query terms shorter than this are dropped rather than prefix-matched. A one or two letter
    /// prefix matches a large share of the index, which costs a big scan to return a result nobody
    /// wanted.
    static let minimumPrefixLength = 3

    // MARK: - Words

    /// The words of `text`, in order, with duplicates kept.
    static func words(in text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The distinct words of `text`.
    static func normalize(_ text: String) -> [String] {
        var seen = Set<String>()
        return words(in: text).filter { seen.insert($0).inserted }
    }

    // MARK: - Terms with positions

    /// Every distinct term in `text`, with the word offsets it appears at.
    ///
    /// Positions are kept because a snippet has to be able to point at where a term actually
    /// occurred, not just say that it did.
    static func tokenize(_ text: String) -> [String: [Int]] {
        var positions: [String: [Int]] = [:]
        for (offset, word) in words(in: text).enumerated() {
            positions[word, default: []].append(offset)
        }
        return positions
    }

    /// The terms of a query that are long enough to search with.
    static func queryPrefixes(_ query: String) -> [String] {
        normalize(query).filter { $0.count >= minimumPrefixLength }
    }
}
