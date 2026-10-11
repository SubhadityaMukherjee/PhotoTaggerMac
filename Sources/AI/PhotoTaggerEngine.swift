import CoreGraphics
import CoreImage
import Foundation
import MLXLMCommon

/// Runs the Qwen3-VL model over one photo and returns its raw text answer.
///
/// A fresh `ChatSession` is created per photo so each image is described
/// independently — no tags can leak from a previous photo via conversation
/// history. The heavyweight `ModelContainer` (weights on GPU) is shared.
struct PhotoTaggerEngine {

    let container: ModelContainer

    static let prompt = """
        You tag photos in a personal photo library so they can be found by search. Tags must be specific and descriptive — "person", "indoor", "outdoor" are useless.

        Output ONLY a comma-separated list of 8-12 tags. Each tag is 1 or 2 lowercase words, never more; hyphenated compounds count as one word ("mid-air", "close-up"). No other text.

        Cover what is clearly visible:
        - subject: "woman", "toddler", "golden retriever", "red bicycle"
        - pose or action: "sitting cross-legged", "mid-air jump", "arms crossed", "cutting cake"
        - clothing with color: "yellow shirt", "red raincoat", "blue saree"
        - specific setting: "rocky beach", "hiking trail", "temple courtyard", "dinner table"
        - occasion: "birthday party", "wedding", "street food"
        - framing and style: "close-up", "selfie", "golden hour", "monochrome", "candid"

        Prefer two precise words over one generic word. Never guess names, places or relationships.
        """

    func rawTags(for image: CGImage) async throws -> String {
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 64, temperature: 0),
            processing: UserInput.Processing(resize: nil)
        )
        let ciImage = CIImage(cgImage: image)
        return try await session.respond(to: Self.prompt, image: .ciImage(ciImage))
    }
}

/// Serializes GPU inference across workers. MLX's Metal command-encoder
/// table is not safe under simultaneous eval from multiple tasks (it can
/// segfault — verified by a crash report), so workers take turns on the
/// model while their image loads and Photos writes overlap another
/// worker's inference.
actor InferenceSerializer {
    func rawTags(_ engine: PhotoTaggerEngine, for image: CGImage) async throws -> String {
        try await engine.rawTags(for: image)
    }
}
