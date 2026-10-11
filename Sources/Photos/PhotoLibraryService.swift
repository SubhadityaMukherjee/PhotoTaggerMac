import AppKit
import Foundation
import ImageIO
import Photos

struct AlbumSummary: Identifiable, Hashable {
    /// Pseudo-id for the whole-library entry ("All Photos"), which is not a
    /// real PHAssetCollection.
    static let allPhotosID = "__all_photos__"

    let id: String  // PHAssetCollection localIdentifier, or allPhotosID
    let title: String
    let assetCount: Int
    let isSmartAlbum: Bool
    let isAllPhotos: Bool

    init(
        id: String, title: String, assetCount: Int, isSmartAlbum: Bool,
        isAllPhotos: Bool = false
    ) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
        self.isSmartAlbum = isSmartAlbum
        self.isAllPhotos = isAllPhotos
    }

    static func allPhotos(imageCount: Int) -> AlbumSummary {
        AlbumSummary(
            id: allPhotosID,
            title: "All Photos",
            assetCount: imageCount,
            isSmartAlbum: false,
            isAllPhotos: true)
    }
}

struct AlbumAssets {
    let summary: AlbumSummary
    let images: [PHAsset]
    let videoCount: Int
}

enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    case imageUnavailable
    /// The asset rejects property edits (e.g. photos inside shared iCloud
    /// albums). Surfaced as a skip, not a failure.
    case assetNotEditable(fileName: String?)
    case changeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "PhotoTagger needs access to your photo library."
        case .imageUnavailable:
            return "Could not load this photo's image data."
        case .assetNotEditable(let fileName):
            return
                "\(fileName ?? "Photo") is read-only in Photos (e.g. a shared-album photo) — skipped."
        case .changeFailed(let reason):
            return "Photos rejected the keyword change: \(reason)"
        }
    }
}

/// Names for the PHPhotosError codes we may see, so problems show up as
/// "Photos error 3300 (changeNotSupported)" instead of a bare domain.
private let photoErrorCodeNames: [Int: String] = [
    -1: "internalError",
    3072: "userCancelled",
    3114: "libraryVolumeOffline",
    3142: "relinquishingLibraryToWriter",
    3143: "switchingSystemPhotoLibrary",
    3164: "networkAccessRequired",
    3169: "networkError",
    3201: "identifierNotFound",
    3202: "multipleIdentifiersFound",
    3300: "changeNotSupported",
    3301: "operationInterrupted",
    3302: "invalidResource",
    3303: "missingResource",
    3305: "notEnoughSpace",
    3306: "requestNotSupportedForAsset",
    3307: "limitExceeded",
    3310: "accessRestricted",
    3311: "accessUserDenied",
]

/// All PhotoKit access in one place: authorization, album listing, image
/// loading (HEIC-aware, orientation-corrected, downscaled), and the one kind
/// of write this app performs — adding keywords.
@MainActor
final class PhotoLibraryService {

    // MARK: - Authorization

    var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var isAuthorized: Bool {
        switch status {
        case .authorized, .limited: return true
        default: return false
        }
    }

    func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Albums

    private static func imageFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    private static func videoCountFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        return options
    }

    /// "All Photos" (the whole library) followed by user albums and smart
    /// albums (Recents, Favorites, …), all filtered to non-empty.
    func fetchAlbums() -> [AlbumSummary] {
        guard isAuthorized else { return [] }
        var results: [AlbumSummary] = []

        let libraryImages = PHAsset.fetchAssets(with: Self.imageFetchOptions())
        if libraryImages.count > 0 {
            results.append(AlbumSummary.allPhotos(imageCount: libraryImages.count))
        }

        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            results.append(
                AlbumSummary(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled Album",
                    assetCount: count,
                    isSmartAlbum: false))
        }

        let smart = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { collection, _, _ in
            let subtype = collection.assetCollectionSubtype
            // Skip the ones that make no sense to tag.
            guard subtype != .smartAlbumAllHidden,
                subtype != .smartAlbumUnableToUpload
            else { return }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            results.append(
                AlbumSummary(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Album",
                    assetCount: count,
                    isSmartAlbum: true))
        }

        return results
    }

    /// Loads the target's assets, split into photos (to tag) and a video
    /// count (to report as skipped). "All Photos" spans the whole library;
    /// everything else is a PHAssetCollection.
    func fetchAssets(for album: AlbumSummary) -> AlbumAssets {
        if album.isAllPhotos {
            let imageFetch = PHAsset.fetchAssets(with: Self.imageFetchOptions())
            var images: [PHAsset] = []
            images.reserveCapacity(imageFetch.count)
            imageFetch.enumerateObjects { asset, _, _ in images.append(asset) }

            let videoCount = PHAsset.fetchAssets(
                with: Self.videoCountFetchOptions()
            ).count

            return AlbumAssets(summary: album, images: images, videoCount: videoCount)
        }

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [album.id], options: nil)
        guard let collection = collections.firstObject else {
            return AlbumAssets(summary: album, images: [], videoCount: 0)
        }

        let imageFetch = PHAsset.fetchAssets(in: collection, options: Self.imageFetchOptions())
        var images: [PHAsset] = []
        images.reserveCapacity(imageFetch.count)
        imageFetch.enumerateObjects { asset, _, _ in images.append(asset) }

        let videoCount = PHAsset.fetchAssets(
            in: collection, options: Self.videoCountFetchOptions()
        ).count

        return AlbumAssets(summary: album, images: images, videoCount: videoCount)
    }

    // MARK: - Image loading

    /// Loads a downscaled, orientation-corrected bitmap for the asset.
    ///
    /// `requestImageDataAndOrientation` returns the current version (so
    /// edits made in Photos are what the model sees) and works with iCloud
    /// originals; ImageIO then produces a ~1024 px thumbnail with the EXIF
    /// rotation baked in — plenty of detail for tagging at a fraction of the
    /// vision-token cost.
    ///
    /// When tagging runs fast (small models + pipelining), iCloud-backed
    /// originals are requested quicker than PhotoKit likes and single
    /// requests can fail transiently — so one retry after a beat.
    func loadImage(for asset: PHAsset, maxPixelSize: CGFloat = 1024) async throws -> CGImage {
        do {
            return try await fetchImage(for: asset, maxPixelSize: maxPixelSize)
        } catch {
            let name = PhotoLibraryService.displayName(for: asset) ?? "photo"
            DebugLog.shared.warning(
                "Photos",
                "\(name): image data request failed (\(error)) — retrying once")
            try? await Task.sleep(nanoseconds: 800_000_000)
            return try await fetchImage(for: asset, maxPixelSize: maxPixelSize)
        }
    }

    private func fetchImage(for asset: PHAsset, maxPixelSize: CGFloat) async throws -> CGImage {
        let data = try await fetchImageData(for: asset)
        // Decode off the main actor: a 12 MP HEIC decode takes 100-300 ms
        // and PhotoKit delivers its callback on an arbitrary thread — often
        // the main one — which would jank the UI and serialize with
        // everything else running there.
        return try await Task.detached(priority: .userInitiated) {
            try Self.decode(data, maxPixelSize: maxPixelSize)
        }.value
    }

    private func fetchImageData(for asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, info in
                guard !resumed else { return }
                resumed = true

                guard let data else {
                    // Preserve the underlying Photos error when present, and
                    // annotate the request context so the debug log shows
                    // whether iCloud was involved.
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    let underlying = (info?[PHImageErrorKey] as? Error)
                    let ns = underlying as? NSError
                    let annotated = NSError(
                        domain: ns?.domain ?? "PhotoTagger",
                        code: ns?.code ?? 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "\(ns?.localizedDescription ?? "image data unavailable")"
                                + " [inCloud=\(inCloud)]"
                        ])
                    continuation.resume(throwing: annotated)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated private static func decode(_ data: Data, maxPixelSize: CGFloat) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else {
            throw PhotoLibraryError.imageUnavailable
        }
        return image
    }

    // MARK: - Display name

    /// Best-effort filename for UI display. PHAssetResource is the only
    /// supported way to get a filename; fall back to a date if unavailable.
    nonisolated static func displayName(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
            ?? resources.first
        {
            return resource.originalFilename
        }
        if let date = asset.creationDate {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return nil
    }

    // MARK: - The only write: adding keywords

    /// Adds `tags` to the asset's keywords. Uses the macOS 27 keyword API:
    /// Photos itself merges additively — "adding a keyword that is already
    /// associated will be silently ignored" — so existing keywords are
    /// guaranteed to survive untouched and there is no read-modify-write
    /// race. Nothing else about the asset (pixels, dates, albums) changes.
    ///
    /// Read-only assets (shared iCloud albums, restricted items) are
    /// detected up front and reported as `assetNotEditable`; transient
    /// Photos errors are retried once; a per-asset keyword limit falls back
    /// to fewer tags rather than failing the photo.
    @discardableResult
    func addKeywords(_ tags: [String], to asset: PHAsset) async throws -> Bool {
        guard !tags.isEmpty else { return false }

        guard asset.canPerform(.properties) else {
            throw PhotoLibraryError.assetNotEditable(
                fileName: PhotoLibraryService.displayName(for: asset))
        }

        do {
            try await performKeywordChange(tags, for: asset)
            return true
        } catch {
            let ns = error as NSError
            guard ns.domain == PHPhotosErrorDomain else {
                throw PhotoLibraryError.changeFailed(describe(error))
            }

            let fileName = PhotoLibraryService.displayName(for: asset) ?? "photo"

            // Transient library hiccups: one retry after a beat.
            let transient = [-1, 3301]  // internalError, operationInterrupted
            if transient.contains(ns.code) {
                DebugLog.shared.warning(
                    "Photos",
                    "\(fileName): transient \(describe(error)) — retrying once (\(asset.localIdentifier))")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                do {
                    try await performKeywordChange(tags, for: asset)
                    return true
                } catch {
                    throw PhotoLibraryError.changeFailed(describe(error))
                }
            }

            // Per-asset keyword limit: retry with a trimmed set instead of
            // losing the photo entirely.
            if ns.code == 3307, tags.count > 6 {
                DebugLog.shared.warning(
                    "Photos",
                    "\(fileName): keyword limit exceeded with \(tags.count) tags — retrying with the first 6 (\(asset.localIdentifier))")
                do {
                    try await performKeywordChange(Array(tags.prefix(6)), for: asset)
                    return true
                } catch {
                    throw PhotoLibraryError.changeFailed(describe(error))
                }
            }

            throw PhotoLibraryError.changeFailed(describe(error))
        }
    }

    private func performKeywordChange(_ tags: [String], for asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            for tag in tags {
                request.addKeyword(tag)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain,
            let name = photoErrorCodeNames[ns.code]
        {
            return "Photos error \(ns.code) (\(name)) — \(ns.localizedDescription)"
        }
        return ns.localizedDescription
    }
}
