import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Writes notes with Apple's on-device model (the Foundation Models framework): free, offline, and
/// private, on any Mac or device with Apple Intelligence. Its context window is small (4,096 tokens on
/// OS 26, 8,192 on newer devices with OS 27, read at runtime), so most lectures are written in parts
/// by `LongLectures`.
nonisolated enum AppleIntelligence {
    /// The model ID used in settings. There is one on-device model.
    static let modelID = "on-device"

    enum Failure: LocalizedError {
        case unavailable(String)
        case tooLong
        case declined

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .tooLong: "Part of this lecture was still too long for Apple Intelligence's context window, even split into smaller parts. Try turning off Send slides to the model under Settings > Advanced."
            case .declined: "Apple Intelligence declined to write notes for this part of the lecture."
            }
        }
    }

    // MARK: Availability

    /// Why Apple Intelligence can't be used here, or nil if it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence. Choose another provider."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings > Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The model's context window in tokens on this device.
    static var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// What the model list shows for Apple Intelligence.
    static var model: AvailableModel {
        AvailableModel(
            id: modelID, displayName: "On this device",
            contextTokens: isAvailable ? contextSize : nil, acceptsImages: true,
            summary: "Apple's on-device model: free, private, and works offline. Its context window is small, so lectures are written in several parts."
        )
    }

    // MARK: Measuring

    /// How many tokens the model counts for some text, using Apple's own tokenizer.
    static func tokens(in text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }

    /// Characters per token for this kind of text with Apple's tokenizer, measured on a sample and
    /// lowered by 15% for safety. English lecture text measured about 5; the generic estimate is 3.
    static func charactersPerToken(sample: String) async -> Double? {
        let sample = String(sample.prefix(4_000))
        guard sample.count >= 200, let count = try? await tokens(in: sample), count > 0 else { return nil }
        return max(1.5, Double(sample.count) / Double(count) * 0.85)
    }

    /// How many tokens one slide image costs, measured with Apple's tokenizer.
    static func tokens(forImage jpeg: Data) async throws -> Int? {
        guard let image = cgImage(from: jpeg) else { return nil }
        return try await SystemLanguageModel.default.tokenCount(for: Attachment(image))
    }

    // MARK: Writing

    /// Describes one slide's visuals in a few sentences, for notes models that can't see images. The
    /// slide's text is read separately (Vision), so this focuses on diagrams, charts, and layout.
    static func describeSlide(_ jpeg: Data) async throws -> String {
        let instructions = """
            You describe lecture slides for a student who cannot see them. In two to four plain sentences, \
            describe what the slide shows visually: diagrams, charts, graphs, tables, equations, arrows, and \
            how parts relate. Do not copy out long passages of text; the text is provided separately. If the \
            slide is only text, say so in one sentence. Describe only what is visible; never guess.
            """
        var text = ""
        for try await chunk in stream([.text("Describe this slide."), .image(jpeg)], system: instructions, maximumTokens: 200) {
            text += chunk
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the model's reply to `parts` (text and slide images) with `system` as its instructions.
    /// The framework reports the whole reply so far each time; this yields just the new text.
    static func stream(_ parts: [FileToAI.Part], system: String, maximumTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = unavailableReason { throw Failure.unavailable(reason) }
                    let session = LanguageModelSession(model: .default, instructions: system)
                    let response = session.streamResponse(
                        to: prompt(from: parts),
                        // The model's own sampling: always taking the most likely word made it loop on a
                        // real 89-minute lecture (2026-11-13).
                        options: GenerationOptions(samplingMode: nil, temperature: nil, maximumResponseTokens: maximumTokens)
                    )
                    var sent = ""
                    for try await snapshot in response {
                        let delta = newText(in: snapshot.content, after: sent)
                        sent = snapshot.content
                        if !delta.isEmpty { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The part of `snapshot` not yet sent. Snapshots normally grow by appending; if one doesn't start
    /// with what was sent (the model revised earlier text), only what lies beyond it is sent.
    static func newText(in snapshot: String, after sent: String) -> String {
        if snapshot.hasPrefix(sent) { return String(snapshot.dropFirst(sent.count)) }
        return snapshot.count > sent.count ? String(snapshot.dropFirst(sent.count)) : ""
    }

    /// Text and images in order, as one prompt.
    private static func prompt(from parts: [FileToAI.Part]) -> Prompt {
        let pieces: [Prompt] = parts.compactMap { part in
            switch part {
            case .text(let text):
                return Prompt(text)
            case .image(let jpeg):
                return cgImage(from: jpeg).map { Prompt(Attachment($0)) }
            }
        }
        return Prompt(pieces)
    }

    private static func cgImage(from jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Turns the framework's errors into ones the app can act on and explain.
    static func translate(_ error: any Error) -> any Error {
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded: return Failure.tooLong
            case .guardrailViolation, .refusal: return Failure.declined
            default: return error
            }
        }
        return translateLegacy(error)
    }

    /// The error type used before OS 27 (deprecated, but possibly still thrown). Marked deprecated so
    /// using it here doesn't warn.
    @available(*, deprecated, message: "Only for errors from before LanguageModelError")
    private static func translateLegacy(_ error: any Error) -> any Error {
        guard let generation = error as? LanguageModelSession.GenerationError else { return error }
        switch generation {
        case .exceededContextWindowSize: return Failure.tooLong
        case .guardrailViolation, .refusal: return Failure.declined
        default: return error
        }
    }
}
