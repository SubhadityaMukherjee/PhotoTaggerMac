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
        You tag photos in a personal photo library so they can be found later by searching. Tags must be SPECIFIC and DESCRIPTIVE — generic tags like "person", "people", "indoor" or "outdoor" are useless for search.

        Look at the photo and output ONLY a comma-separated list of 8-12 tags. No other text, no explanations.

        Every tag is 1 or 2 lowercase words — never 3 or more. Hyphenated compounds count as one word ("mid-air", "close-up", "cross-legged").

        Cover as many of these as are clearly visible:
        - subject: who or what ("woman", "toddler", "golden retriever", "red bicycle")
        - pose or action: "sitting cross-legged", "mid-air jump", "lying down", "looking away", "arms crossed", "cutting cake"
        - clothing with color: "yellow shirt", "red raincoat", "white kurta", "blue saree"
        - specific setting: "rocky beach", "dinner table", "hiking trail", "temple courtyard", "apartment balcony"
        - occasion: "birthday party", "street food", "wedding", "road trip"
        - framing and style: "close-up", "selfie", "golden hour", "backlit", "monochrome", "candid"

        Prefer two precise words over one generic word ("red raincoat", not "clothing"). Never guess names, places or relationships you cannot see.
        """

    func rawTags(for image: CGImage) async throws -> String {
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 96, temperature: 0),
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
