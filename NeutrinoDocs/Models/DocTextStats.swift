import Foundation

// MARK: - DocTextStats

/// Word/character counts and estimated reading time for what a document says.
/// Pulled out of the editor view so the arithmetic can be unit tested directly.
struct DocTextStats: Equatable {

    let wordCount: Int
    let characterCount: Int
    let readingTimeMinutes: Int

    /// Average adult silent reading speed, in words per minute. 200 is the low end of the usual
    /// 200–250 range — an estimate that runs slightly long is the kinder error.
    static let wordsPerMinute = 200.0

    static func compute(from text: String) -> DocTextStats {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let wordCount = words.count
        let readingTimeMinutes = wordCount == 0
            ? 0
            : max(1, Int((Double(wordCount) / wordsPerMinute).rounded(.up)))
        return DocTextStats(
            wordCount: wordCount,
            characterCount: text.count,
            readingTimeMinutes: readingTimeMinutes
        )
    }

    var readingTimeText: String {
        readingTimeMinutes <= 1 ? "1 min read" : "\(readingTimeMinutes) min read"
    }

    /// "128 words · 742 characters · 1 min read"
    var summaryText: String {
        let words = wordCount == 1 ? "1 word" : "\(wordCount) words"
        let characters = characterCount == 1 ? "1 character" : "\(characterCount) characters"
        return "\(words) · \(characters) · \(readingTimeText)"
    }
}
