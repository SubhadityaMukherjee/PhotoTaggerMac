import Foundation
import Photos

/// Remembers which assets PhotoTagger has already tagged, so "Tag All" can be
/// clicked repeatedly and resumes where it left off.
///
/// Persisted in UserDefaults as a plain array of PHAsset localIdentifiers.
@MainActor
@Observable
final class TaggedAssetStore {

    private static let key = "PhotoTagger.taggedAssetIDs"
    private static let flushInterval = 25

    private let defaults: UserDefaults
    private(set) var ids: Set<String>
    private var dirtyCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func insert(_ id: String) {
        guard ids.insert(id).inserted else { return }
        dirtyCount += 1
        if dirtyCount >= Self.flushInterval { flush() }
    }

    /// Write-through on run completion / app quit.
    func flush() {
        guard dirtyCount > 0 else { return }
        defaults.set(Array(ids), forKey: Self.key)
        dirtyCount = 0
    }
}
