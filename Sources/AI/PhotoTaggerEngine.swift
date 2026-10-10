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
        You tag photos in a personal photo library so they can be found later by searching.

        Look at the photo and output ONLY a comma-separated list of 5-12 tags describing it. No other text, no explanations.

        Rules for the tags:
        - Each tag is 1-3 lowercase words, plain text (no hashtags, no punctuation).
        - Cover: the main subject (people, animals, objects), notable clothing with its color (e.g. "yellow shirt", "woman in red dress"), the setting or location (e.g. "lake", "kitchen", "city street", "mountains"), the activity or occasion (e.g. "hiking", "birthday party", "dinner"), and the style or mood when clear (e.g. "sunset", "black and white", "selfie", "close-up").
        - Combine color + object or color + clothing whenever a color stands out.
        - Only describe what is clearly visible. Skip a category if it does not apply.
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
