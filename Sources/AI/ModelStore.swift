import Foundation
import MLXLMCommon
import MLXVLM
import HuggingFace

/// The taggable models, all Qwen3-VL Instruct 4-bit MLX builds. Decode is
/// memory-bandwidth bound (every token reads the whole weight set), so a
/// smaller model is dramatically faster; tagging quality drops only a
/// little down to 4B and modestly at 2B.
enum ModelChoice: String, CaseIterable, Identifiable {
    case fast2B
    case balanced4B
    case best8B

    var id: String { rawValue }

    var modelID: String {
        switch self {
        case .fast2B: return "mlx-community/Qwen3-VL-2B-Instruct-4bit"
        case .balanced4B: return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
        case .best8B: return "mlx-community/Qwen3-VL-8B-Instruct-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .fast2B: return "Qwen3-VL 2B (4-bit)"
        case .balanced4B: return "Qwen3-VL 4B (4-bit)"
        case .best8B: return "Qwen3-VL 8B (4-bit)"
        }
    }

    var shortName: String {
        switch self {
        case .fast2B: return "2B · fastest"
        case .balanced4B: return "4B · balanced"
        case .best8B: return "8B · best"
        }
    }

    /// Rough on-disk size, used for labels until download progress reports
    /// the real total.
    var approximateBytes: Int64 {
        switch self {
        case .fast2B: return 1_700_000_000
        case .balanced4B: return 3_000_000_000
        case .best8B: return 5_200_000_000
        }
    }
}

/// Downloads (first run) and loads the selected model into memory.
///
/// The model runs fully on-device via MLX (Apple's Metal-backed array
/// framework) — no server, no API keys, nothing leaves the machine.
///
/// The store owns one background load task; callers observe `phase` (and
/// `containerIfReady`) while awaiting it. A download interrupted by the user
/// continues in the background — the next "Tag All" resumes where it left
/// off via the Hugging Face cache. Switching `choice` drops whatever is
/// loaded so the next run downloads/loads the new model.
@MainActor
@Observable
final class ModelStore {

    static let defaultChoice = ModelChoice.balanced4B
    nonisolated private static let choiceKey = "modelChoice"

    private(set) var choice: ModelChoice

    var modelID: String { choice.modelID }
    var displayName: String { choice.displayName }
    var approximateBytes: Int64 { choice.approximateBytes }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.choiceKey),
            let stored = ModelChoice(rawValue: raw)
        {
            choice = stored
        } else {
            choice = Self.defaultChoice
        }
    }

    /// Switches model: cancels any in-flight load/download and forgets the
    /// loaded container; the next "Tag All" fetches the new one.
    func switchModel(to newChoice: ModelChoice) {
        guard newChoice != choice else { return }
        choice = newChoice
        UserDefaults.standard.set(newChoice.rawValue, forKey: Self.choiceKey)
        loadTask?.cancel()
        loadTask = nil
        container = nil
        phase = .notLoaded
        DebugLog.shared.info("Model", "Switched model to \(displayName)")
    }

    enum Phase: Equatable {
        case notLoaded
        case downloading(totalBytes: Int64, receivedBytes: Int64)
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .loading: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .notLoaded

    @ObservationIgnored
    private var container: ModelContainer?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    var containerIfReady: ModelContainer? { container }

    /// Starts the one-time download + load if needed. Safe to call anytime.
    func startLoadingIfNeeded() {
        guard container == nil, loadTask == nil, !phase.isBusy else { return }
        phase = .downloading(totalBytes: approximateBytes, receivedBytes: 0)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await self.loadFromHub()
                self.container = container
                self.phase = .ready
                DebugLog.shared.info("Model", "Model ready — \(self.displayName)")
            } catch is CancellationError {
                if self.container == nil { self.phase = .notLoaded }
            } catch {
                DebugLog.shared.error("Model", "Model load failed: \(error)")
                if self.container == nil {
                    self.phase = .failed(error.localizedDescription)
                }
            }
            self.loadTask = nil
        }
    }

    // MARK: - Loading

    private func loadFromHub() async throws -> ModelContainer {
        let client = HubClient()
        let loader = HuggingFaceTokenizerLoader()
        let downloader = HubDownloader(client: client)

        // The factory download (revision "main") always re-lists the repo
        // tree and fetches anything missing from the HF cache, so
        // interrupted downloads resume correctly. There is deliberately NO
        // localFilesOnly fast path: that API can hand back a partially
        // downloaded snapshot, and MLX's loader traps (crashes) on missing
        // weight shards. We therefore download ourselves, validate the
        // snapshot before MLX ever sees it, and — if incomplete — wipe the
        // repo cache and download fresh once more.
        do {
            let directory = try await downloadValidated(downloader)
            return try await loadModelContainer(from: directory, using: loader)
        } catch {
            guard error is ModelValidationError else { throw error }
            DebugLog.shared.warning(
                "Model",
                "Downloaded model snapshot failed validation (\(error.localizedDescription)) — clearing the cache and retrying once")
            try Self.wipeRepoCache(modelID: choice.modelID)
            let directory = try await downloadValidated(downloader)
            return try await loadModelContainer(from: directory, using: loader)
        }
    }

    private func downloadValidated(_ downloader: HubDownloader) async throws -> URL {
        phase = .downloading(totalBytes: approximateBytes, receivedBytes: 0)
        let directory = try await downloader.download(
            id: choice.modelID,
            revision: nil,
            matching: ["*.safetensors", "*.json", "*.jinja"],
            useLatest: false,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.handleProgress(progress)
                }
            })
        phase = .loading
        try await Self.validateSnapshot(at: directory, modelID: choice.modelID)
        return directory
    }

    // MARK: - Snapshot validation

    enum ModelValidationError: LocalizedError {
        case noWeightFiles
        case treeListingFailed(String)
        case incompleteSnapshot(missing: [String], sizeMismatches: [String])
        case corruptWeightFile(String)

        var errorDescription: String? {
            switch self {
            case .noWeightFiles:
                return "The model download contains no weight files. The cached copy was cleared — try again."
            case .treeListingFailed(let message):
                return "Could not verify the model against huggingface.co (\(message)). Check your connection and try again."
            case .incompleteSnapshot(let missing, let sizeMismatches):
                var parts: [String] = []
                if !missing.isEmpty {
                    parts.append("missing files: \(missing.prefix(3).joined(separator: ", "))")
                }
                if !sizeMismatches.isEmpty {
                    parts.append(
                        "truncated files: \(sizeMismatches.prefix(3).joined(separator: ", "))")
                }
                return
                    "The model download was incomplete (\(parts.joined(separator: "; "))). The cached copy was cleared — try again."
            case .corruptWeightFile(let name):
                return
                    "A model weight file is unreadable (\(name)). The cached copy was cleared — try again."
            }
        }
    }

    /// Verifies the downloaded snapshot against the repo's file tree before
    /// MLX ever sees it. MLX's loader **traps** (hard crash) on missing or
    /// mismatched weights rather than throwing, so this is the safety net
    /// that turns a partial download into a clean error.
    ///
    /// The check is deliberately index-independent: repos on the hub can
    /// carry a stale `model.safetensors.index.json` (shard names/counts from
    /// a different upload) while their actual safetensors files are complete
    /// and load fine via MLX's conventional-name fallback. So we trust the
    /// git tree listing instead: every `*.safetensors` it names must be
    /// present at the exact expected size, and each file's safetensors
    /// header must parse.
    nonisolated static func validateSnapshot(at directory: URL, modelID: String) async throws {
        let entries = try await fetchTreeEntries(modelID: modelID)
        let expected: [(path: String, size: Int)] =
            entries
            .compactMap { entry in
                guard entry["path"] as? String != nil,
                    entry["type"] as? String == "file",
                    (entry["path"] as! String).hasSuffix(".safetensors")
                else { return nil }
                let path = entry["path"] as! String
                let lfsSize = (entry["lfs"] as? [String: Any])?["size"] as? Int
                let size = lfsSize ?? (entry["size"] as? Int)
                return size.map { (path, $0) }
            }

        guard !expected.isEmpty else { throw ModelValidationError.noWeightFiles }

        var missing: [String] = []
        var mismatches: [String] = []
        for (path, expectedSize) in expected {
            // Snapshot entries are symlinks into the blob store — resolve
            // before asking for the size, or you measure the link itself.
            let url = directory.appendingPathComponent(path)
                .resolvingSymlinksInPath()
            let actual =
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                ?? nil
            if actual == nil {
                missing.append(path)
            } else if actual != expectedSize {
                mismatches.append(path)
            }
        }
        if !missing.isEmpty || !mismatches.isEmpty {
            throw ModelValidationError.incompleteSnapshot(
                missing: missing, sizeMismatches: mismatches)
        }

        for (path, _) in expected {
            _ = try safetensorsTensorNames(
                at: directory.appendingPathComponent(path),
                fileName: path)
        }
    }

    /// First page of `GET /api/models/{id}/tree/{revision}?recursive=true`.
    /// The model repos in use have well under one page of files.
    nonisolated private static func fetchTreeEntries(modelID: String) async throws -> [[String: Any]] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(modelID)/tree/main"
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components.url else {
            throw ModelValidationError.treeListingFailed("bad URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelValidationError.treeListingFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw ModelValidationError.treeListingFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return json
    }

    /// Tensor names from a safetensors file header (first 8 bytes = header
    /// length, then JSON). Only the header is read — a few MB at most.
    nonisolated private static func safetensorsTensorNames(at url: URL, fileName: String) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8 else {
            throw ModelValidationError.corruptWeightFile(fileName)
        }
        let headerLength = lengthBytes.reversed().reduce(0) { ($0 << 8) + UInt64($1) }  // little-endian
        guard headerLength >= 2, headerLength < 64_000_000 else {
            throw ModelValidationError.corruptWeightFile(fileName)
        }
        guard
            let headerData = try handle.read(upToCount: Int(headerLength)),
            headerData.count == Int(headerLength),
            let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else {
            throw ModelValidationError.corruptWeightFile(fileName)
        }
        return Set(json.keys.filter { $0 != "__metadata__" })
    }

    /// Removes the HF cache for this repo so a corrupted/partial snapshot
    /// can't come back. HF cache dirs are named `models--org--name` (the
    /// `models--` kind prefix included) under `~/.cache/huggingface/hub`.
    nonisolated static func wipeRepoCache(modelID: String) throws {
        let cacheRoot = URL.homeDirectory
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = cacheRoot.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        guard FileManager.default.fileExists(atPath: repoDir.path) else { return }
        try FileManager.default.removeItem(at: repoDir)
    }

    private func handleProgress(_ progress: Progress) {
        guard case .downloading = phase else { return }
        let total = progress.totalUnitCount > 0
            ? progress.totalUnitCount : approximateBytes
        guard total > 0, progress.completedUnitCount > 0 else { return }

        if progress.completedUnitCount >= total {
            // Bytes are all in — what remains is unquantize + GPU upload.
            phase = .loading
        } else {
            phase = .downloading(totalBytes: total, receivedBytes: progress.completedUnitCount)
        }
    }
}
