import Foundation
import MLXLMCommon

#if canImport(HuggingFace)
    import HuggingFace
#endif
#if canImport(Tokenizers)
    import Tokenizers
#endif

/// Bridges `HubClient` (swift-huggingface) into MLX's `Downloader` protocol.
///
/// Mirrors what MLXHuggingFace's `#hubDownloader()` macro expands to, minus
/// the macro. The default client caches under `~/.cache/huggingface/hub`
/// (shared with Python clients), so the ~5 GB of weights are downloaded once.
struct HubDownloader: Downloader {

    let client: HubClient

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw ModelStoreError.invalidRepositoryID(id)
        }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            })
    }
}

/// Bridges `Tokenizers.AutoTokenizer` into MLX's `Tokenizer` protocol
/// (the expansion of `#huggingFaceTokenizerLoader()`).
struct HuggingFaceTokenizerLoader: TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return BridgedTokenizer(upstream: upstream)
    }
}

struct BridgedTokenizer: MLXLMCommon.Tokenizer {

    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum ModelStoreError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository id: \(id)"
        }
    }
}
