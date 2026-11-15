import Foundation
import Testing
@testable import Lecture_Me_Faster

/// The split proposal follows a change of model or settings (2026-11-13: it kept the old model's numbers).
@MainActor
@Suite(.serialized)
struct ReplanTests {
    private static let host = "replan.lecture-me-faster.test"

    private func waitUntilSettled(_ session: LectureSession) async throws {
        for _ in 0..<400 where session.isBusy || session.isReplanning { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func proposal(_ session: LectureSession) -> LectureSession.SplitProposal? {
        if case .awaitingSplitApproval(let proposal) = session.phase { proposal } else { nil }
    }

    @Test func changingTheModelWorksTheProposalOutAgainWithoutWriting() async throws {
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"small"},{"id":"large"}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let root = FileManager.default.temporaryDirectory.appending(path: "Replan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LectureHistory(root: root)
        // About 30,000 tokens of transcript.
        let transcript = (0..<1500).map {
            TranscriptSegment(seconds: Double($0) * 3, text: "Sentence \($0) of a long lecture about recursion, base cases and stacks.")
        }
        let saved = try history.save(title: "Recursion", transcript: transcript, frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(saved)

        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(Self.host)/v1"
        stored.openAIModel = "small"
        stored.openAIContextTokens = 16_384
        let settings = AppSettings(unsaved: stored)

        session.resummarize(settings: settings, detail: .detailed)
        try await waitUntilSettled(session)
        let first = try #require(proposal(session), "Too long for 16K: asks first")
        #expect(first.parts > 1)
        #expect(first.model == "small")

        // A model with a much larger window: the proposal now says it fits, and nothing was written.
        settings.stored.openAIModel = "large"
        settings.stored.openAIContextTokens = 262_144
        session.replan(settings: settings)
        try await waitUntilSettled(session)
        let second = try #require(proposal(session))
        #expect(second.model == "large")
        #expect(second.fitsInOneRequest)
        #expect(second.contextTokens == 262_144)
        #expect(!log.requestURLs.contains { $0.path().hasSuffix("chat/completions") }, "Re-planning never writes")

        // Back to the small one: parts again.
        settings.stored.openAIContextTokens = 16_384
        session.replan(settings: settings)
        try await waitUntilSettled(session)
        #expect(try #require(proposal(session)).parts == first.parts)

        // Writing after re-planning uses the new choice.
        settings.stored.openAIContextTokens = 262_144
        session.replan(settings: settings)
        try await waitUntilSettled(session)
        session.approveSplit(settings: settings)
        try await waitUntilSettled(session)
        #expect(session.phase == .done)
        #expect(log.requestURLs.filter { $0.path().hasSuffix("chat/completions") }.count == 1, "One request with the large window")
    }

    @Test func theChosenModelIsNamedForTheToolbar() {
        var stored = AppSettings.Stored()
        stored.provider = .claude
        stored.claudeModel = "claude-opus-5-5"
        #expect(AppSettings(unsaved: stored).chosenModelName == "Claude: claude-opus-5-5")
        stored.provider = .apple
        #expect(AppSettings(unsaved: stored).chosenModelName == AIProvider.apple.label)
        let before = AppSettings(unsaved: stored).planningKey
        stored.maxFrames += 5
        #expect(AppSettings(unsaved: stored).planningKey != before, "Slide settings change the plan too")
    }
}
