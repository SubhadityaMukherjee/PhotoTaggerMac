import AppKit
import Foundation
import ImageIO
import Photos

struct AlbumSummary: Identifiable, Hashable {
    let id: String  // PHAssetCollection localIdentifier
    let title: String
    let assetCount: Int
    let isSmartAlbum: Bool
}

struct AlbumAssets {
    let summary: AlbumSummary
    let images: [PHAsset]
    let videoCount: Int
}

enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    case imageUnavailable
    case changeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "PhotoTagger needs access to your photo library."
        case .imageUnavailable:
            return "Could not load this photo's image data."
        case .changeFailed(let reason):
            return "Photos rejected the keyword change: \(reason)"
        }
    }
}

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

    /// User albums followed by smart albums (Recents, Favorites, …),
    /// both filtered to non-empty.
    func fetchAlbums() -> [AlbumSummary] {
        guard isAuthorized else { return [] }
        var results: [AlbumSummary] = []

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

    /// Loads the album's assets, split into photos (to tag) and a video count
    /// (to report as skipped).
    func fetchAssets(for album: AlbumSummary) -> AlbumAssets {
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [album.id], options: nil)
        guard let collection = collections.firstObject else {
            return AlbumAssets(summary: album, images: [], videoCount: 0)
        }

        let imageOptions = PHFetchOptions()
        imageOptions.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        imageOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let imageFetch = PHAsset.fetchAssets(in: collection, options: imageOptions)
        var images: [PHAsset] = []
        images.reserveCapacity(imageFetch.count)
        imageFetch.enumerateObjects { asset, _, _ in images.append(asset) }

        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let videoCount = PHAsset.fetchAssets(in: collection, options: videoOptions).count

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
    func loadImage(for asset: PHAsset, maxPixelSize: CGFloat = 1024) async throws -> CGImage {
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

                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, let data,
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
                    if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: PhotoLibraryError.imageUnavailable)
                    }
                    return
                }
                continuation.resume(returning: image)
            }
        }
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
    @discardableResult
    func addKeywords(_ tags: [String], to asset: PHAsset) async throws -> Bool {
        guard !tags.isEmpty else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                for tag in tags {
                    request.addKeyword(tag)
                }
            }
            return true
        } catch {
            throw PhotoLibraryError.changeFailed(error.localizedDescription)
        }
    }
}
