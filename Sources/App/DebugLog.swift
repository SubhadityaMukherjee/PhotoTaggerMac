import Foundation
import Observation

/// In-app event log shown in the Debug pane (sidebar → Debug Log). The pane
/// is hidden by default; reveal it with View ▸ Show Debug Panel (⇧⌘D).
///
/// A shared instance so services that have no `AppModel` reference
/// (`ModelStore`, `PhotoLibraryService`) can record events too. Like the rest
/// of the app's state it is main-actor confined, and every entry is mirrored
/// to `NSLog` so Console.app and `log show` keep working unchanged.
@MainActor
@Observable
final class DebugLog {

    static let shared = DebugLog()

    enum Level {
        case error
        case warning
        case info

        var label: String {
            switch self {
            case .error: return "error"
            case .warning: return "warning"
            case .info: return "info"
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let level: Level
        /// Broad origin: "Model", "Photos", "Run", …
        let category: String
        let message: String
    }

    /// Newest first, capped so long runs can't grow it unbounded.
    private(set) var entries: [Entry] = []

    private(set) var errorCount = 0
    private(set) var warningCount = 0

    private let capacity = 1000

    /// Entries are also appended here so problems can be inspected after a
    /// run (the in-app pane is memory-only). Rotated at ~4 MB. The handle
    /// stays open — entries are frequent during failure storms.
    nonisolated private static let fileURL = URL.homeDirectory
        .appendingPathComponent("Library/Logs/PhotoTagger/debug.log")
    @ObservationIgnored private var fileHandle: FileHandle?
    @ObservationIgnored private var fileBytes = 0

    // MARK: - Recording

    func error(_ category: String, _ message: String) {
        record(.error, category, message)
    }

    func warning(_ category: String, _ message: String) {
        record(.warning, category, message)
    }

    func info(_ category: String, _ message: String) {
        record(.info, category, message)
    }

    private func record(_ level: Level, _ category: String, _ message: String) {
        entries.insert(Entry(level: level, category: category, message: message), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        switch level {
        case .error: errorCount += 1
        case .warning: warningCount += 1
        case .info: break
        }
        // "%@" — messages can contain model output with % characters.
        NSLog("%@", "PhotoTagger [\(category)] \(level.label): \(message)")
        appendToFile(level: level, category: category, message: message)
    }

    private func appendToFile(level: Level, category: String, message: String) {
        if fileHandle == nil { openLogFile() }
        if fileBytes > 4_000_000 {
            // Rotate: close, delete, start fresh.
            try? fileHandle?.close()
            try? FileManager.default.removeItem(at: Self.fileURL)
            fileHandle = nil
            openLogFile()
        }
        guard let handle = fileHandle else { return }

        let time = Date().formatted(
            .dateTime.hour().minute().second().secondFraction(.fractional(3)))
        let chunk = Data("\(time) [\(level.label)] [\(category)] \(message)\n".utf8)
        do {
            try handle.write(contentsOf: chunk)
            fileBytes += chunk.count
        } catch {
            // Next entry tries to reopen.
            fileHandle = nil
        }
    }

    /// Opens (creating if needed) the log file once and keeps the handle
    /// around, so each entry is a single write instead of open/stat/close.
    private func openLogFile() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        fileHandle = handle
        fileBytes = Int((try? handle.offset()) ?? 0)
    }

    func clear() {
        entries.removeAll()
        errorCount = 0
        warningCount = 0
    }

    /// Oldest → newest plain-text dump, for the Copy All button.
    func transcript() -> String {
        entries.reversed()
            .map { entry in
                let time = entry.date.formatted(
                    .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                return "\(time)  [\(entry.level.label)] [\(entry.category)]  \(entry.message)"
            }
            .joined(separator: "\n")
    }
}
