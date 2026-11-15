import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Two failures seen on 2026-11-13: an expired API key was reported as "931 parts, 1 million tokens"
/// instead of as a rejected key, because images kept adding requests.
@Suite(.serialized)
struct KeyAndImagePlanningTests {
    // MARK: Images never add requests

    /// A 90-minute lecture with 653 slides, planned for a 32K window (the fallback when the window
    /// can't be looked up), the way `LectureSession.summarize` does it.
    private func lecture() -> (transcript: [TranscriptSegment], tokens: [Int], isImage: [Bool], scores: [Double]) {
        let transcript = (0..<1000).map {
            TranscriptSegment(seconds: Double($0) * 5.4, text: "Sentence \($0) about pointers and arrays, explained slowly with examples for the class.")
        }
        let scores = (0..<653).map { Double(($0 * 37) % 100) / 100 }
        // The 30 most visual go as images (1,600 tokens); the rest as their text (about 40).
        let isImage = VideoToFrames.imageChoice(visualScores: scores, limit: 30)
        return (transcript, isImage.map { $0 ? LongLectures.tokensPerImage : 40 }, isImage, scores)
    }

    @Test func aSmallWindowLeavesRoomForTheLecture() {
        // Claude's reply reserve used to be a flat 64K, so a 32K window left only the 4,000 minimum.
        #expect(LongLectures.inputBudget(provider: .claude, contextTokens: 32_768) == 24_576)
        #expect(LongLectures.inputBudget(provider: .claude, contextTokens: 1_000_000) == 936_000)
        #expect(LongLectures.claudeFallbackContextTokens == 200_000)
    }

    @Test func addingImagesNeverAddsRequests() {
        let (transcript, tokens, isImage, scores) = lecture()
        let frameTimes = (0..<653).map { Double($0) * 8 }
        let budget = LongLectures.inputBudget(provider: .claude, contextTokens: 32_768)
        let plan = LongLectures.plan(transcript: transcript, frameTimes: frameTimes, documents: [], budget: budget, frameTokens: tokens)
        #expect(plan.sections.count < 20, "A handful of requests, not hundreds: \(plan.sections.count)")

        let choice = LongLectures.imagesThatFit(
            plan: plan, transcript: transcript, frameTokens: tokens, isImage: isImage,
            imageTokens: LongLectures.tokensPerImage, visualScores: scores, limit: 30
        )
        #expect(choice.asImage.count { $0 } >= 30, "Never fewer images than the lecture-wide limit")
        // Every section still fits with its added images, and has at most 30.
        for section in plan.sections {
            let images = section.frames.count { choice.asImage[$0] }
            #expect(images <= 30)
            let used = plan.overhead
                + section.transcript.reduce(0) { $0 + LongLectures.tokens(in: transcript[$1].text) + 4 }
                + section.frames.reduce(0) { $0 + (choice.asImage[$1] ? LongLectures.tokensPerImage : tokens[$1]) }
            #expect(used <= plan.budget, "Section over budget: \(used) > \(plan.budget)")
        }
        // Planning again with the added images gives the same number of requests or fewer... never more.
        let after = LongLectures.plan(
            transcript: transcript, frameTimes: frameTimes, documents: [], budget: budget,
            frameTokens: zip(choice.asImage, tokens).map { $0 ? LongLectures.tokensPerImage : $1 }
        )
        #expect(after.sections.count <= plan.sections.count + 1, "Re-planned: \(after.sections.count) vs \(plan.sections.count)")
    }

    @Test func imagesGoWhereThereIsRoom() {
        // One section with room for exactly two more images.
        let transcript = [TranscriptSegment(seconds: 0, text: "Short.")]
        let plan = LongLectures.Plan(
            sections: [.init(transcript: 0..<1, frames: 0..<4, documents: [])],
            estimatedTokens: 0, budget: 3_000 + 4 + 3 + 4 * 40 + 2 * (1_600 - 40) + 10, overhead: 3_000
        )
        let choice = LongLectures.imagesThatFit(
            plan: plan, transcript: transcript, frameTokens: [40, 40, 40, 40], isImage: [false, false, false, false],
            imageTokens: 1_600, visualScores: [0.1, 0.9, 0.5, 0.7], limit: 30
        )
        #expect(choice.asImage == [false, true, false, true], "The two most visual")
        #expect(choice.addedTokens == 2 * 1_560)
    }

    // MARK: Rejected keys

    @Test func httpErrorsBecomeHelpfulMessages() {
        let rejected = FileToAI.Failure.forStatus(401, detail: "invalid x-api-key")
        #expect(rejected == .keyRejected("invalid x-api-key"))
        #expect(rejected.localizedDescription.contains("may have expired"))
        #expect(rejected.localizedDescription.contains("invalid x-api-key"))
        #expect(FileToAI.Failure.forStatus(403, detail: "") == .keyRejected(""))
        #expect(FileToAI.Failure.forStatus(402, detail: "").localizedDescription.contains("out of credit"))
        #expect(FileToAI.Failure.forStatus(429, detail: "").localizedDescription.contains("Wait a minute"))
        #expect(FileToAI.Failure.forStatus(400, detail: "bad").localizedDescription == "The model server returned an error (HTTP 400): bad")
    }

    private static let host = "expired-key.lecture-me-faster.test"

    @Test func anExpiredKeyStopsBeforePlanningWithAClearMessage() async throws {
        let log = MockModelServer.start(host: Self.host) { _ in
            (401, #"{"error":{"message":"API key expired","type":"invalid_request_error"}}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let root = FileManager.default.temporaryDirectory.appending(path: "ExpiredKey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LectureHistory(root: root)
        let transcript = (0..<3000).map { TranscriptSegment(seconds: Double($0), text: "A long lecture sentence number \($0).") }
        let saved = try history.save(title: "Long", transcript: transcript, frames: [], distinctFrameCount: 0)
        let session = await LectureSession(history: history)
        await session.open(saved)
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(Self.host)/v1"
        stored.openAIModel = "some-model"
        stored.openAIContextTokens = 8_000
        let settings = AppSettings(unsaved: stored)
        settings.openAIKey = "expired-key"

        await session.resummarize(settings: settings, detail: .detailed)
        for _ in 0..<200 where await session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        let phase = await session.phase
        guard case .failed(let message) = phase else { Issue.record("Expected a failure, got \(phase)"); return }
        #expect(message.contains("API key was rejected"))
        #expect(message.contains("API key expired"), "The provider's own words are kept")
        #expect(!log.requestURLs.contains { $0.path().hasSuffix("chat/completions") }, "Nothing sent with a rejected key")
    }
}
