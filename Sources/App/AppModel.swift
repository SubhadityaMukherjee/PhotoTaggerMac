import AppKit
import Foundation
import ImageIO
import MLXLMCommon
import Photos
import SwiftUI

/// Central state: photo-library access, albums, model lifecycle, and the
/// "Tag All" run loop. All state is touched on the main actor; the heavy
/// inference runs inside MLX while awaiting `respond`.
@MainActor
@Observable
final class AppModel {

    enum AccessPhase: Equatable {
        case checking
        case needsPermission
        case denied
        case granted
    }

    struct TagEvent: Identifiable, Hashable {
        let id = UUID()
        let assetLocalID: String
        let fileName: String?
        let tags: [String]
        let date = Date()
    }

    struct RunStats {
        var total = 0
        var done = 0
        var failed = 0
        var skippedVideos = 0
        var skippedAlreadyTagged = 0
        var skippedReadOnly = 0
    }

    /// Pseudo-id for the hidden developer pane selected from the sidebar.
    static let debugSidebarID = "__debug__"

    // MARK: - State

    private(set) var accessPhase: AccessPhase = .checking
    private(set) var albums: [AlbumSummary] = []
    var selectedAlbumID: String?

    /// Whether the Debug Log section appears in the sidebar. Off by
    /// default; toggled via View ▸ Show Debug Panel (⇧⌘D).
    var showDebugPanel = false {
        didSet {
            if !showDebugPanel, selectedAlbumID == Self.debugSidebarID {
                selectedAlbumID = nil
                selectedAssets = nil
                taggedCount = 0
            }
        }
    }

    private(set) var selectedAssets: AlbumAssets?
    /// How many photos in the selected album this app has already tagged.
    private(set) var taggedCount = 0

    let library = PhotoLibraryService()
    let store = TaggedAssetStore()
    let modelStore = ModelStore()

    // Run state (nil when idle)
    private(set) var runIsActive = false
    private(set) var runAlbumTitle = ""
    private(set) var runStats = RunStats()
    private(set) var runStartedAt: Date?
    private(set) var currentThumbnail: CGImage?
    private(set) var currentFileName: String?
    private(set) var currentTags: [String] = []
    private(set) var recentEvents: [TagEvent] = []
    private(set) var lastFailureMessage: String?
    private(set) var stopRequested = false

    /// How many photos are tagged simultaneously. Workers run real
    /// inferences concurrently over the shared model (each photo gets its
    /// own ChatSession/KV cache), and each one keeps an image prefetch in
    /// flight; every extra worker costs a few hundred MB of memory.
    /// Persisted; 1 restores the old strictly-sequential behavior.
    var parallelTagging: Int = {
        let stored = UserDefaults.standard.integer(forKey: AppModel.parallelTaggingKey)
        return min(max(stored == 0 ? 2 : stored, 1), 4)
    }() {
        didSet {
            let clamped = min(max(parallelTagging, 1), 4)
            if clamped != parallelTagging {
                parallelTagging = clamped
                return
            }
            UserDefaults.standard.set(parallelTagging, forKey: Self.parallelTaggingKey)
        }
    }
    nonisolated private static let parallelTaggingKey = "parallelTagging"

    /// Longest image edge (px) fed to the model. Vision tokens scale with
    /// pixel area, so smaller images prefill much faster at some cost in
    /// fine detail. Persisted; 640 / 768 / 1024.
    var visionDetail: Int = {
        let stored = UserDefaults.standard.integer(forKey: AppModel.visionDetailKey)
        return [640, 768, 1024].contains(stored) ? stored : 1024
    }() {
        didSet {
            guard [640, 768, 1024].contains(visionDetail) else {
                visionDetail = 1024
                return
            }
            UserDefaults.standard.set(visionDetail, forKey: AppModel.visionDetailKey)
        }
    }
    nonisolated private static let visionDetailKey = "visionDetail"

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    // MARK: - Bootstrap

    func bootstrap() async {
        // Debug/verification hooks:
        //   -preloadModel              download + load the model immediately
        //   -selfTestImage <path.jpg>  tag one image, log the result, quit
        let args = CommandLine.arguments
        if args.contains("-diagnoseWrites") {
            Task { await diagnoseWrites() }
            return
        }
        if args.contains("-tagFirstPhoto") {
            modelStore.startLoadingIfNeeded()
            Task { await tagFirstPhoto() }
            return
        }
        if let idx = args.firstIndex(of: "-selfTestImage"), idx + 1 < args.count {
            let path = args[idx + 1]
            modelStore.startLoadingIfNeeded()
            Task { await selfTest(imagePath: path) }
            return
        }
        if let idx = args.firstIndex(of: "-concurrencyProbe"), idx + 1 < args.count {
            let path = args[idx + 1]
            var workers = UserDefaults.standard.integer(forKey: "probeWorkers")
            if workers <= 0 { workers = 2 }
            workers = min(workers, 8)
            var rounds = UserDefaults.standard.integer(forKey: "probeRounds")
            if rounds <= 0 { rounds = 2 }
            modelStore.startLoadingIfNeeded()
            Task { await concurrencyProbe(imagePath: path, workers: workers, rounds: rounds) }
            return
        }
        if args.contains("-preloadModel") {
            modelStore.startLoadingIfNeeded()
        }

        let status = library.status
        switch status {
        case .notDetermined:
            accessPhase = .needsPermission
            let granted = await library.requestAccess()
            accessPhase = granted.isAuthorizedPhase ? .granted : .denied
        case .restricted, .denied:
            accessPhase = .denied
        default:
            accessPhase = .granted
        }
        if accessPhase == .granted { refreshAlbums() }
    }

    func refreshAlbums() {
        albums = library.fetchAlbums()
        if let id = selectedAlbumID, id != Self.debugSidebarID,
            !albums.contains(where: { $0.id == id })
        {
            selectedAlbumID = nil
            selectedAssets = nil
            taggedCount = 0
        }
    }

    /// Shows the developer log pane (sidebar → Debug Log).
    func selectDebugPane() {
        selectedAlbumID = Self.debugSidebarID
        selectedAssets = nil
        taggedCount = 0
    }

    func select(_ album: AlbumSummary?) {
        selectedAlbumID = album?.id
        guard let album else {
            selectedAssets = nil
            taggedCount = 0
            return
        }
        let assets = library.fetchAssets(for: album)
        selectedAssets = assets
        taggedCount = assets.images.filter { store.contains($0.localIdentifier) }.count
    }

    /// Number of photos a "Tag All" run would process right now.
    var pendingCount: Int {
        guard let assets = selectedAssets else { return 0 }
        return assets.images.count - taggedCount
    }

    // MARK: - Tag All

    func startTagging(includeAlreadyTagged: Bool) {
        guard !runIsActive, let assets = selectedAssets, !assets.images.isEmpty else { return }

        let targets =
            includeAlreadyTagged
            ? assets.images.filter { !store.isKnownReadOnly($0.localIdentifier) }
            : assets.images.filter {
                !store.contains($0.localIdentifier) && !store.isKnownReadOnly($0.localIdentifier)
            }

        guard !targets.isEmpty else { return }

        runIsActive = true
        runAlbumTitle = assets.summary.title
        runStats = RunStats(total: targets.count)
        runStats.skippedVideos = assets.videoCount
        if !includeAlreadyTagged {
            runStats.skippedAlreadyTagged = assets.images.count - targets.count
        }
        runStartedAt = Date()
        currentThumbnail = nil
        currentFileName = nil
        currentTags = []
        recentEvents = []
        lastFailureMessage = nil
        stopRequested = false

        modelStore.startLoadingIfNeeded()

        runTask = Task { [weak self] in
            await self?.runLoop(targets: targets)
        }
    }

    /// Stop takes effect within one photo (the current photo finishes first).
    /// A model download, if one is running, continues in the background.
    func stopTagging() {
        guard runIsActive, !stopRequested else { return }
        stopRequested = true
        runTask?.cancel()
    }

    private func runLoop(targets: [PHAsset]) async {
        let log = DebugLog.shared
        let workers = min(parallelTagging, targets.count)
        log.info(
            "Run",
            "Tagging \(targets.count) photos in “\(runAlbumTitle)” — \(workers) in parallel")
        defer {
            runIsActive = false
            stopRequested = false
            store.flush()
            currentThumbnail = nil
            runTask = nil
            if Task.isCancelled {
                log.warning("Run", "Stopped by user after \(runStats.done) of \(runStats.total) photos")
            } else {
                log.info(
                    "Run",
                    "Finished: \(runStats.done) tagged, \(runStats.failed) failed, "
                        + "\(runStats.skippedReadOnly) read-only skipped in "
                        + "\(Int(runElapsed.rounded()))s"
                )
            }
            // Refresh the selected album so "already tagged" counts reflect
            // what just happened.
            if let id = selectedAlbumID, id != Self.debugSidebarID,
                let album = albums.first(where: { $0.id == id })
            {
                select(album)
            }
        }

        // Wait for the model (downloading/loading), while remaining
        // stoppable the whole time.
        var container: ModelContainer? = modelStore.containerIfReady
        while container == nil {
            if Task.isCancelled { return }
            if case .failed(let message) = modelStore.phase {
                lastFailureMessage = "Could not load the AI model: \(message)"
                log.error("Model", "Run aborted — could not load the AI model: \(message)")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            container = modelStore.containerIfReady
        }

        let engine = PhotoTaggerEngine(container: container!)

        // The model container is designed for multiple concurrent
        // ChatSessions (each photo gets its own), so workers run real
        // inferences simultaneously on the shared weights. Striding the
        // target list keeps each worker's prefetch simple.
        await withTaskGroup(of: Void.self) { group in
            for offset in 0..<workers {
                let slice = stride(from: offset, to: targets.count, by: workers)
                    .map { targets[$0] }
                group.addTask { [weak self] in
                    await self?.workerLoop(engine: engine, assets: slice)
                }
            }
        }
    }

    /// One inference worker over its (strided) slice of assets. Keeps one
    /// image prefetch in flight so the next photo's network fetch + HEIC
    /// decode overlap the current photo's GPU inference.
    private func workerLoop(engine: PhotoTaggerEngine, assets: [PHAsset]) async {
        let log = DebugLog.shared
        guard !assets.isEmpty else { return }

        var nextIndex = 1
        var pendingLoad: Task<(PHAsset, Result<CGImage, Error>), Never>? =
            prefetchImage(for: assets[0])
        defer { pendingLoad?.cancel() }

        while let current = pendingLoad, !Task.isCancelled {
            pendingLoad = nextIndex < assets.count ? prefetchImage(for: assets[nextIndex]) : nil
            if pendingLoad != nil { nextIndex += 1 }

            let (asset, result) = await current.value
            if Task.isCancelled { break }

            switch result {
            case .success(let image):
                await process(asset, image, engine: engine)
            case .failure(let error):
                if let libraryError = error as? PhotoLibraryError,
                    case .assetNotEditable = libraryError
                {
                    // Read-only assets are filtered at prefetch time.
                    store.insertReadOnly(asset.localIdentifier)
                    runStats.skippedReadOnly += 1
                    log.info(
                        "Photos",
                        "\(PhotoLibraryService.displayName(for: asset) ?? "photo") is read-only — skipped (\(asset.localIdentifier))"
                    )
                } else if error is CancellationError {
                    break
                } else {
                    runStats.failed += 1
                    let name = PhotoLibraryService.displayName(for: asset) ?? "photo"
                    lastFailureMessage = "\(name): \(error.localizedDescription)"
                    log.error(
                        "Photos",
                        "image load failed for \(name) (\(asset.localIdentifier)): \(error)")
                }
            }
        }
    }

    /// Starts the next image load without waiting for the current photo's
    /// inference. The decode itself happens off the main actor inside
    /// PHImageManager/ImageIO.
    private func prefetchImage(for asset: PHAsset) -> Task<(PHAsset, Result<CGImage, Error>), Never> {
        Task {
            // Skip known read-only assets before spending a network fetch
            // on them (shared iCloud albums reject property edits).
            guard asset.canPerform(.properties) else {
                return (asset, .failure(PhotoLibraryError.assetNotEditable(fileName: nil)))
            }
            do {
                return (asset, .success(try await library.loadImage(
                    for: asset, maxPixelSize: CGFloat(visionDetail))))
            } catch {
                return (asset, .failure(error))
            }
        }
    }

    /// Tags and writes one photo. Shared by all workers; per-photo failures
    /// are counted, never fatal to the run.
    private func process(_ asset: PHAsset, _ image: CGImage, engine: PhotoTaggerEngine) async {
        let log = DebugLog.shared

        // Defense in depth: the prefetch pre-check can race Photos state.
        guard asset.canPerform(.properties) else {
            store.insertReadOnly(asset.localIdentifier)
            runStats.skippedReadOnly += 1
            log.info(
                "Photos",
                "\(PhotoLibraryService.displayName(for: asset) ?? "photo") is read-only — skipped (\(asset.localIdentifier))"
            )
            return
        }

        currentFileName = PhotoLibraryService.displayName(for: asset)
        currentThumbnail = image
        currentTags = []

        do {
            let raw = try await engine.rawTags(for: image)
            if Task.isCancelled { return }

            let tags = TagParser.parse(raw)
            guard !tags.isEmpty else {
                runStats.failed += 1
                log.warning(
                    "Model",
                    "\(currentFileName ?? "photo"): model produced no usable tags — "
                        + "raw answer: \(raw.prefix(300))")
                return
            }

            try await library.addKeywords(tags, to: asset)
            store.insert(asset.localIdentifier)

            runStats.done += 1
            currentTags = tags
            recentEvents.insert(
                TagEvent(assetLocalID: asset.localIdentifier, fileName: currentFileName, tags: tags),
                at: 0)
            if recentEvents.count > 100 { recentEvents.removeLast(recentEvents.count - 100) }
        } catch let error as PhotoLibraryError {
            if case .assetNotEditable = error {
                // Shared-album / restricted photos: expected, not a failure.
                store.insertReadOnly(asset.localIdentifier)
                runStats.skippedReadOnly += 1
                log.info(
                    "Photos",
                    "\(currentFileName ?? "photo") is read-only — skipped (\(asset.localIdentifier))")
            } else {
                runStats.failed += 1
                lastFailureMessage = "\(currentFileName ?? "photo"): \(error.localizedDescription)"
                log.error(
                    "Photos",
                    "write failed for \(currentFileName ?? "?") (\(asset.localIdentifier)): \(error)")
            }
        } catch is CancellationError {
            // Run is stopping; leave counts as they are.
        } catch {
            // Per-photo failures shouldn't kill the run.
            runStats.failed += 1
            lastFailureMessage = "\(currentFileName ?? "photo"): \(error.localizedDescription)"
            log.error(
                "Run",
                "photo failed \(currentFileName ?? "?") (\(asset.localIdentifier)): \(error)")
        }
    }

    /// Full end-to-end pipeline on the first photo of the real library:
    /// load image → model → parse → write keywords. This is exactly what the
    /// Tag All loop does, for one photo. Launched via `-tagFirstPhoto`.
    private func tagFirstPhoto() async {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else {
            NSLog("PhotoTagger e2e: no image assets in library")
            exit(1)
        }
        NSLog(
            "PhotoTagger e2e: asset \(asset.localIdentifier) canPerform(.properties)=\(asset.canPerform(.properties))"
        )

        do {
            var container: ModelContainer? = modelStore.containerIfReady
            while container == nil {
                if case .failed(let message) = modelStore.phase {
                    NSLog("PhotoTagger e2e: model failed: \(message)")
                    exit(1)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                container = modelStore.containerIfReady
            }

            let started = Date()
            let image = try await library.loadImage(for: asset)
            NSLog("PhotoTagger e2e: image loaded (\(image.width)×\(image.height))")

            let raw = try await PhotoTaggerEngine(container: container!).rawTags(for: image)
            let tags = TagParser.parse(raw)
            NSLog("PhotoTagger e2e: model said: \(raw)")
            NSLog("PhotoTagger e2e: parsed tags: \(tags)")

            try await library.addKeywords(tags, to: asset)
            NSLog("PhotoTagger e2e: keywords WRITTEN in %.1fs total", Date().timeIntervalSince(started))
            exit(0)
        } catch {
            NSLog("PhotoTagger e2e: FAILED \(error as NSError)")
            exit(1)
        }
    }

    // MARK: - Self test

    /// Runs several inferences on one image file simultaneously to verify
    /// that concurrent ChatSessions over a single shared model container
    /// work on this machine (the run loop relies on it) and to measure the
    /// throughput scaling of extra workers. Launched via
    /// `-concurrencyProbe <path>`; worker count via `defaults write …
    /// probeWorkers N`, rounds per worker via `probeRounds N`, and image
    /// size via `visionDetail`. Never touches the photo library.
    private func concurrencyProbe(imagePath: String, workers: Int, rounds: Int) async {
        guard
            let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: imagePath) as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: CGFloat(visionDetail),
                ] as CFDictionary)
        else {
            NSLog("PhotoTagger probe: cannot load image \(imagePath)")
            exit(1)
        }

        var container: ModelContainer? = modelStore.containerIfReady
        while container == nil {
            if case .failed(let message) = modelStore.phase {
                NSLog("PhotoTagger probe: model failed: \(message)")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            container = modelStore.containerIfReady
        }

        let engine = PhotoTaggerEngine(container: container!)

        // Untimed warm-up: the first inference in a process pays Metal
        // kernel compilation, which would skew the measurement.
        _ = try? await engine.rawTags(for: image)

        let started = Date()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    var completed = 0
                    for _ in 0..<rounds {
                        let t0 = Date()
                        do {
                            _ = try await engine.rawTags(for: image)
                            completed += 1
                            NSLog(
                                "PhotoTagger probe: ok in %.1fs",
                                Date().timeIntervalSince(t0))
                        } catch {
                            NSLog(
                                "PhotoTagger probe: FAILED after %.1fs: %@",
                                Date().timeIntervalSince(t0), String(describing: error))
                        }
                    }
                    return completed
                }
            }
            var total = 0
            for await n in group { total += n }
            let elapsed = Date().timeIntervalSince(started)
            let rss = Double(Self.getpidMemoryFootprint() ?? 0) / 1_073_741_824
            NSLog(
                "PhotoTagger probe summary: %@",
                "\(workers) workers × \(rounds) rounds @\(visionDetail)px — \(total)/\(workers * rounds) ok in \(String(format: "%.1f", elapsed))s = \(String(format: "%.2f", elapsed / Double(max(total, 1)))) s/photo ≈ \(String(format: "%.1f", Double(total) / elapsed * 60)) photos/min (footprint \(String(format: "%.1f", rss)) GB)")
        }
        exit(0)
    }

    /// Diagnoses the keyword-write path against the real library without
    /// writing anything: reports authorization, capability flags, and runs a
    /// no-op performChanges. Launched via `-diagnoseWrites`.
    private func diagnoseWrites() async {
        let status = library.status
        NSLog("PhotoTagger diag: authorization = \(status.rawValue)")

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 5
        let fetch = PHAsset.fetchAssets(with: options)
        NSLog("PhotoTagger diag: sampling \(fetch.count) image assets")

        fetch.enumerateObjects { asset, idx, _ in
            NSLog(
                "PhotoTagger diag[\(idx)]: \(asset.localIdentifier) mediaSubtypes=\(asset.mediaSubtypes.rawValue) source=\(asset.sourceType.rawValue) canPerform(.properties)=\(asset.canPerform(.properties)) canPerform(.content)=\(asset.canPerform(.content)) canPerform(.delete)=\(asset.canPerform(.delete))"
            )
        }

        // No-op change: exercises the write authorization path while
        // touching nothing.
        do {
            try await PHPhotoLibrary.shared().performChanges {}
            NSLog("PhotoTagger diag: no-op performChanges OK")
        } catch {
            NSLog("PhotoTagger diag: no-op performChanges FAILED: \(error as NSError)")
        }

        // One real keyword write to the first asset, then remove it in the
        // same transaction-style follow-up, so we can see the true error.
        if let asset = fetch.firstObject {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).addKeyword("phototagger diag")
                }
                NSLog("PhotoTagger diag: keyword write OK — now removing test keyword")
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).removeKeyword("phototagger diag")
                }
                NSLog("PhotoTagger diag: test keyword removed — everything works")
            } catch {
                NSLog("PhotoTagger diag: keyword write FAILED: \(error as NSError)")
            }
        }
        exit(0)
    }

    /// Tags a single image file end-to-end (model → prompt → parse) and logs
    /// the result. Used via `-selfTestImage <path>` to verify releases.
    private func selfTest(imagePath: String) async {
        do {
            guard
                let source = CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: imagePath) as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
            else {
                throw PhotoLibraryError.imageUnavailable
            }

            var container: ModelContainer? = modelStore.containerIfReady
            while container == nil {
                if case .failed(let message) = modelStore.phase {
                    NSLog("PhotoTagger selftest: model failed: \(message)")
                    exit(1)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                container = modelStore.containerIfReady
            }

            let engine = PhotoTaggerEngine(container: container!)
            let started = Date()
            let raw = try await engine.rawTags(for: image)
            let elapsed = Date().timeIntervalSince(started)
            let tags = TagParser.parse(raw)
            let rss = Double(Self.getpidMemoryFootprint() ?? 0) / 1_073_741_824
            NSLog(
                "PhotoTagger selftest: OK in %.1fs (footprint %.1f GB)\n  raw: \(raw)\n  tags: \(tags.joined(separator: ", "))",
                elapsed, rss)
            exit(0)
        } catch {
            NSLog("PhotoTagger selftest: FAILED \(error)")
            exit(1)
        }
    }

    // MARK: - Formatting helpers

    /// Physical memory footprint in bytes via proc_pidinfo (resident size).
    nonisolated private static func getpidMemoryFootprint() -> Int? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: MemoryLayout<proc_taskinfo>.size / MemoryLayout<integer_t>.size) {
                proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
        }
        guard result > 0 else { return nil }
        return Int(info.pti_resident_size)
    }

    var runElapsed: TimeInterval {
        runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Photos per minute, computed over the current run.
    var runPace: Double {
        let elapsed = runElapsed
        guard elapsed > 5, runStats.done + runStats.failed > 0 else { return 0 }
        return Double(runStats.done + runStats.failed) / (elapsed / 60)
    }

    /// Photos left in the current run.
    var runRemainingCount: Int {
        let processed = runStats.done + runStats.failed + runStats.skippedReadOnly
        return max(runStats.total - processed, 0)
    }

    /// Estimated seconds until the run finishes, once a pace is measurable.
    var runETASeconds: TimeInterval? {
        guard runPace > 0, runRemainingCount > 0 else { return nil }
        return Double(runRemainingCount) / runPace * 60
    }

    nonisolated static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Human "3 h 12 min" / "45 min" / "less than a minute" for ETAs.
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "less than a minute" }
        if s < 3600 { return "\(s / 60) min" }
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
    }
}

private extension PHAuthorizationStatus {
    var isAuthorizedPhase: Bool {
        self == .authorized || self == .limited
    }
}
