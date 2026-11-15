import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Key points written in many parts stay short (2026-11-13: with Apple Intelligence's small window, each
/// part wrote a full summary and they were pasted together, longer than Detailed).
@MainActor
@Suite(.serialized)
struct BriefLengthTests {
    private static let host = "brief-length.lecture-me-faster.test"

    @Test func briefLevelsHaveATargetAndEachPartGetsAShare() {
        #expect(LongLectures.targetWords(.keyPoints, lectureMinutes: 90) == 500)
        #expect(LongLectures.targetWords(.concise, lectureMinutes: 90) == 1_350)
        #expect(LongLectures.targetWords(.concise, lectureMinutes: 10) == 800)
        #expect(LongLectures.targetWords(.concise, lectureMinutes: 600) == 3_000)
        #expect(LongLectures.targetWords(.detailed, lectureMinutes: 90) == nil)
        #expect(LongLectures.shareOfWords(500, parts: 1, of: 17) == 60, "Never under 60")
        #expect(LongLectures.shareOfWords(1_350, parts: 3, of: 9) == 450)
        let section = LongLectures.Plan.Section(transcript: 0..<1, frames: 0..<0, documents: [])
        let text = LongLectures.sectionInstructions(
            index: 0, count: 4, section: section, transcript: [TranscriptSegment(seconds: 0, text: "x")], frameTimes: [], wordLimit: 125
        )
        #expect(text.contains("at most about 125 words"))
    }

    @Test func keyPointsInManyPartsAreShortenedAndCombinedNeverPastedTogether() async throws {
        // Each part answers far longer than asked (as small models do); shortening and combining don't.
        let long = String(repeating: "A long point about recursion and base cases that goes on. ", count: 220)
        let log = MockModelServer.start(host: Self.host, chat: { body in
            if body.contains("Shorten them to at most about") { return "Short part." }
            if body.contains("Combine them into one set of notes") { return "FINAL KEY POINTS" }
            if body.contains("consecutive parts of a longer lecture") { return "Merged parts." }
            return long
        })
        defer { MockModelServer.stop(host: Self.host) }
        let root = FileManager.default.temporaryDirectory.appending(path: "BriefLength-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LectureHistory(root: root)
        let transcript = (0..<2000).map {
            TranscriptSegment(seconds: Double($0) * 3, text: "Sentence \($0) about recursion, base cases, stacks and frames.")
        }
        let saved = try history.save(title: "Recursion", transcript: transcript, frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(saved)
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(Self.host)/v1"
        stored.openAIModel = "small"
        stored.openAIContextTokens = 8_192
        stored.splitWithoutAsking = true

        session.resummarize(settings: AppSettings(unsaved: stored), detail: .keyPoints)
        for _ in 0..<800 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(session.phase == .done)
        #expect(session.notes(for: .keyPoints) == "FINAL KEY POINTS", "One combined summary, not the parts pasted together")

        let chats = log.requests.filter { $0.contains("\"messages\"") }
        let parts = chats.filter { $0.contains("This is part") }
        #expect(parts.count > 3, "Written in parts: \(parts.count)")
        #expect(parts.allSatisfy { $0.contains("at most about") }, "Every part is told its share")
        #expect(chats.contains { $0.contains("Shorten them to at most about") }, "Too-long parts were shortened")
        #expect(chats.last?.contains("at most about 500 words") == true, "The final summary has the Key points length")
    }
}
