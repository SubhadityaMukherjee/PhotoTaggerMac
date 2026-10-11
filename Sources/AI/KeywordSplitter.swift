import Foundation

/// Splits multi-word keywords (written by earlier prompts) into 1-2 word
/// keywords, cutting at logical boundaries so natural pairs survive:
/// "woman in yellow shirt" → "woman", "yellow shirt".
///
/// Pure string logic — fully unit-tested; the library rewrite lives in
/// `KeywordSplitService`.
enum KeywordSplitter {

    /// Words that mark a boundary between concepts. They never belong in a
    /// 1-2 word tag themselves, and what surrounds them ("yellow shirt")
    /// usually forms a natural pair.
    private static let linkingWords: Set<String> = [
        "a", "an", "the",
        "in", "on", "at", "of", "by", "or", "and", "with",
        "over", "under", "into", "onto", "near", "beside", "for", "from",
        "wearing", "wears", "while", "during", "that", "says",
    ]

    /// The replacement keywords for `keyword`: itself when already 1-2
    /// words, otherwise its logical 1-2 word pieces (deduplicated, order
    /// preserved). Empty only if every word was a linking word.
    static func split(_ keyword: String) -> [String] {
        let words = keyword.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count > 2 else { return [keyword] }

        // Splice into runs at linking words.
        var runs: [[String]] = []
        var current: [String] = []
        for word in words {
            if linkingWords.contains(word) {
                if !current.isEmpty { runs.append(current) }
                current = []
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { runs.append(current) }

        var pieces: [String] = []
        for run in runs {
            appendPieces(of: run, into: &pieces)
        }
        // Degenerate case (all linking words) — fall back to whole-word chunking.
        if pieces.isEmpty {
            appendPieces(of: words, into: &pieces)
        }

        var seen = Set<String>()
        return pieces.filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    /// A run of content words becomes: the final two words as one tag (the
    /// head noun phrase — "dinner table"), with any leading modifier words
    /// standing alone ("candlelit").
    private static func appendPieces(of run: [String], into pieces: inout [String]) {
        guard !run.isEmpty else { return }
        if run.count <= 2 {
            pieces.append(run.joined(separator: " "))
            return
        }
        pieces.append(contentsOf: run.dropLast(2))
        pieces.append(run.suffix(2).joined(separator: " "))
    }
}
