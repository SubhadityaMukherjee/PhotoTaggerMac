import Foundation

/// Normalizes raw vision-model output into clean, Photos-searchable keywords.
///
/// The model is asked for a comma-separated list, but real output can contain
/// thinking blocks, markdown, JSON, or bulleted lists — every format that has
/// shown up in testing is handled here so a malformed answer never writes junk
/// keywords into the photo library.
enum TagParser {

    struct Options {
        var maxTags = 12
        /// "woman in yellow shirt" (4 words) is a perfect search tag; 5+ is prose.
        var maxWordsPerTag = 4
        var maxCharacters = 32
        /// Tags that carry no search value on their own.
        var fillers: Set<String> = [
            "photo", "photograph", "image", "picture", "pic", "photo of", "tag",
            "tags", "none", "n/a", "unknown", "unclear", "not visible", "no",
            "yes", "the", "and", "screenshot",
        ]
    }

    private static let thinkBlock = try! NSRegularExpression(
        pattern: #"<think>[\s\S]*?</think>"#, options: [])
    private static let openThink = try! NSRegularExpression(
        pattern: #"<think>[\s\S]*"#, options: [])
    private static let listMarker = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•–—]+|\d+[.)])\s*"#, options: [])
    private static let codeFence = try! NSRegularExpression(
        pattern: #"`{1,3}"#, options: [])

    static func parse(_ raw: String, options: Options = Options()) -> [String] {
        var text = stripThinking(raw)
        text = stripWrappers(text)

        // JSON array support ("["tag a", "tag b"]") — extract and re-split.
        if let tags = parseJSONArray(text) {
            return clean(tags, options: options)
        }

        let candidates = text.components(
            separatedBy: CharacterSet(charactersIn: ",;\n\r•·|")
        )
        return clean(candidates, options: options)
    }

    // MARK: - Steps

    /// Removes <think>…</think> reasoning blocks and unterminated thinking.
    private static func stripThinking(_ text: String) -> String {
        var out = thinkBlock.stringByReplacingMatches(
            in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: "")
        // Model ran out of tokens mid-think: keep whatever precedes it.
        out = openThink.stringByReplacingMatches(
            in: out, options: [], range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "")
        return out
    }

    /// Strips markdown fences, "Tags:" prefixes and surrounding prose lines
    /// that carry no tags.
    private static func stripWrappers(_ text: String) -> String {
        var out = codeFence.stringByReplacingMatches(
            in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: "")
        out = out.replacingOccurrences(of: #"^\s*(?:tags?|keywords?)\s*[:\-]\s*"#,
                                       with: "",
                                       options: .regularExpression)
        return out
    }

    private static func parseJSONArray(_ text: String) -> [String]? {
        guard let start = text.firstIndex(of: "["),
            let end = text.lastIndex(of: "]"), start < end
        else { return nil }
        let inner = String(text[text.index(after: start)..<end])
        return inner.components(separatedBy: "\"").count > 1
            ? inner.components(separatedBy: CharacterSet(charactersIn: "\","))
            : inner.components(separatedBy: ",")
    }

    private static func clean(_ candidates: [String], options: Options) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for candidate in candidates {
            guard let tag = normalize(candidate, options: options) else { continue }
            if seen.insert(tag).inserted {
                result.append(tag)
                if result.count >= options.maxTags { break }
            }
        }
        return result
    }

    private static func normalize(_ candidate: String, options: Options) -> String? {
        var tag = candidate

        // Leading list markers ("1.", "-", "•") and quotes; trim characters
        // also strip stray leading dashes left behind by "3. - tag" inputs.
        tag = listMarker.stringByReplacingMatches(
            in: tag, options: [], range: NSRange(tag.startIndex..<tag.endIndex, in: tag),
            withTemplate: "")
        tag = tag.trimmingCharacters(
            in: CharacterSet(charactersIn: " \"'`\t .-*•–—"))

        // Lowercase and collapse whitespace.
        tag = tag.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Drop leading articles ("a woman" → "woman").
        for article in ["a ", "an "] where tag.hasPrefix(article) {
            tag = String(tag.dropFirst(article.count))
        }

        // Reject structural leftovers / junk.
        guard !tag.isEmpty, tag.count >= 2, tag.count <= options.maxCharacters,
            !tag.contains(where: { "{}[]()<>/\\:;#=%$@!?*\"'`".contains($0) })
        else { return nil }

        let words = tag.components(separatedBy: " ")
        guard words.count <= options.maxWordsPerTag, !options.fillers.contains(tag)
        else { return nil }

        return tag
    }
}
