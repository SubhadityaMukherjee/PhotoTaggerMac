import Foundation
import Photos

/// Remembers which assets PhotoTagger has already tagged, so "Tag All" can be
/// clicked repeatedly and resumes where it left off. Also remembers assets
/// that reject keyword writes (shared iCloud albums etc.) so they are never
/// re-processed.
///
/// Persisted in UserDefaults as plain arrays of PHAsset localIdentifiers.
@MainActor
@Observable
final class TaggedAssetStore {

    private static let key = "PhotoTagger.taggedAssetIDs"
    private static let readOnlyKey = "PhotoTagger.readOnlyAssetIDs"
    private static let flushInterval = 25

    private let defaults: UserDefaults
    private(set) var ids: Set<String>
    private(set) var readOnlyIDs: Set<String>
    private var dirtyCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
        self.readOnlyIDs = Set(defaults.stringArray(forKey: Self.readOnlyKey) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }
    func isKnownReadOnly(_ id: String) -> Bool { readOnlyIDs.contains(id) }

    func insert(_ id: String) {
        guard ids.insert(id).inserted else { return }
        dirtyCount += 1
        if dirtyCount >= Self.flushInterval { flush() }
    }

    func insertReadOnly(_ id: String) {
        guard readOnlyIDs.insert(id).inserted else { return }
        dirtyCount += 1
        if dirtyCount >= Self.flushInterval { flush() }
    }

    /// Write-through on run completion / app quit.
    func flush() {
        guard dirtyCount > 0 else { return }
        defaults.set(Array(ids), forKey: Self.key)
        defaults.set(Array(readOnlyIDs), forKey: Self.readOnlyKey)
        dirtyCount = 0
    }
}
