import AppKit
import Foundation

/// One-shot maintenance job: rewrites the keywords of already-tagged photos
/// so every keyword is 1-2 words, splitting older multi-word keywords at
/// logical boundaries ("woman in yellow shirt" → "woman", "yellow shirt").
///
/// PhotoKit on macOS can only *add* keywords — reading and replacing them
/// requires AppleScript against the Photos app, so the first run triggers
/// macOS' "control Photos" Automation permission prompt. Keywords that don't
/// look machine-generated (mixed case, punctuation, dates…) are never
/// touched, so anything the user added by hand survives verbatim.
@MainActor
@Observable
final class KeywordSplitService {

    struct Progress: Equatable {
        var total = 0
        var scanned = 0
        var rewritten = 0
        var failed = 0
        var isRunning = false
        var isDone = false

        var summary: String {
            "Scanned \(scanned) of \(total) — \(rewritten) rewritten, \(failed) failed"
        }
    }

    private(set) var progress = Progress()
    private var cancelRequested = false

    func cancel() {
        cancelRequested = true
        DebugLog.shared.warning("Keywords", "Split job cancellation requested — stopping after the current photo")
    }

    /// Splits multi-word keywords on every photo in `ids` (Photos asset
    /// localIdentifiers, as tracked by the tagged-asset store).
    func run(ids: [String]) async {
        guard !progress.isRunning else { return }
        cancelRequested = false
        progress = Progress(total: ids.count, isRunning: true)
        DebugLog.shared.info(
            "Keywords",
            "Splitting multi-word keywords across \(ids.count) tagged photos (AppleScript; Photos must allow control)")

        for id in ids {
            if cancelRequested { break }
            do {
                let keywords = try await Self.keywords(of: id)
                let splitThese = keywords.filter { Self.looksGenerated($0) && Self.wordCount($0) > 2 }
                if !splitThese.isEmpty {
                    var merged = keywords.filter { !splitThese.contains($0) }
                    merged.append(
                        contentsOf: Self.mergedPieces(of: splitThese, excluding: merged))
                    try await Self.setKeywords(merged, of: id)
                    progress.rewritten += 1
                }
                progress.scanned += 1
            } catch {
                progress.scanned += 1
                progress.failed += 1
                if progress.failed <= 20 {
                    DebugLog.shared.warning("Keywords", "Could not rewrite \(id): \(error)")
                }
            }
        }

        progress.isRunning = false
        progress.isDone = true
        DebugLog.shared.info(
            "Keywords",
            "Split job finished: scanned \(progress.scanned)/\(progress.total), rewritten \(progress.rewritten), failed \(progress.failed)"
                + (cancelRequested ? " (cancelled early)" : ""))
    }

    // MARK: - Merging

    /// Split pieces for the replaced keywords, minus anything already
    /// present on the photo, order preserved.
    nonisolated private static func mergedPieces(
        of replaced: [String], excluding existing: [String]
    ) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var pieces: [String] = []
        for keyword in replaced {
            for piece in KeywordSplitter.split(keyword) where !seen.contains(piece) {
                seen.insert(piece)
                pieces.append(piece)
            }
        }
        return pieces
    }

    /// TagParser output is always lowercase with no punctuation beyond
    /// spaces/hyphens — anything else is a keyword the user made by hand.
    nonisolated private static func looksGenerated(_ keyword: String) -> Bool {
        keyword == keyword.lowercased()
            && !keyword.isEmpty
            && keyword.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
    }

    nonisolated private static func wordCount(_ keyword: String) -> Int {
        keyword.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    // MARK: - AppleScript

    nonisolated private static func keywords(of id: String) async throws -> [String] {
        let descriptor = try await runAppleScript("""
            tell application "Photos"
                keywords of media item id "\(escape(id))"
            end tell
            """)
        var keywords: [String] = []
        for index in 1...max(descriptor.numberOfItems, 0) {
            if let keyword = descriptor.atIndex(index)?.stringValue {
                keywords.append(keyword)
            }
        }
        return keywords
    }

    nonisolated private static func setKeywords(_ keywords: [String], of id: String) async throws {
        let list = keywords.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        _ = try await runAppleScript("""
            tell application "Photos"
                set keywords of media item id "\(escape(id))" to {\(list)}
            end tell
            """)
    }

    nonisolated private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// NSAppleScript blocks while Photos processes the event, so it runs on
    /// a detached task; calls stay sequential from the main actor.
    nonisolated private static func runAppleScript(_ source: String) async throws -> NSAppleEventDescriptor {
        try await Task.detached(priority: .utility) { () -> NSAppleEventDescriptor in
            guard let script = NSAppleScript(source: source) else {
                throw NSError(
                    domain: "PhotoTagger.KeywordSplit", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not compile AppleScript"])
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                throw NSError(
                    domain: "PhotoTagger.KeywordSplit", code: 2,
                    userInfo: error as? [String: Any] ?? [:])
            }
            return result
        }.value
    }
}
