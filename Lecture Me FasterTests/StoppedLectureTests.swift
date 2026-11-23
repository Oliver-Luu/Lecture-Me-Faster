import Foundation
import Testing
@testable import Lecture_Me_Faster

/// A chat server that sends the start of a reply and then never finishes, so a request can be stopped
/// partway. Its model list names one model, "m".
final class StallingModelServer: URLProtocol, @unchecked Sendable {
    static let host = "stalling.lecture-me-faster.test"
    static let partialReply = "Partial notes"
    static let registration: Void = { URLProtocol.registerClass(StallingModelServer.self) }()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isChat = request.url!.path().hasSuffix("chat/completions")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["content-type": isChat ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isChat {
            let chunk = #"{"choices":[{"delta":{"content":"\#(Self.partialReply)"}}]}"#
            client?.urlProtocol(self, didLoad: Data("data: \(chunk)\n\n".utf8))
        } else {
            client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"m"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A lecture that is stopped leaves nothing behind. All four were real bugs found on 2026-11-16: work that
/// was cancelled carried on, because a cancelled transcription or model stream ends quietly instead of
/// failing, and nothing checked.
@MainActor
@Suite(.serialized)
struct StoppedLectureTests {
    private func settings(host: String) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(host)/v1"
        stored.openAIModel = "m"
        stored.openAIContextTokens = 262_144
        return AppSettings(unsaved: stored)
    }

    private func makeHistory() -> (history: LectureHistory, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Stopped-\(UUID().uuidString)")
        return (LectureHistory(root: root), root)
    }

    private let transcript = (0..<20).map {
        TranscriptSegment(seconds: Double($0) * 5, text: "Sentence \($0) about recursion and base cases.")
    }

    private func wait(upTo seconds: Double = 10, until condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 100) where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A session showing a saved lecture whose Detailed notes have started to arrive and will never finish.
    private func sessionWritingNotes(_ history: LectureHistory) async throws -> (LectureSession, SavedLecture, AppSettings) {
        _ = StallingModelServer.registration
        let saved = try history.save(title: "Old", transcript: transcript, frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(saved)
        let settings = settings(host: StallingModelServer.host)
        session.resummarize(settings: settings, detail: .detailed)
        try await wait { session.liveNotes == StallingModelServer.partialReply }
        #expect(session.phase == .summarizing)
        return (session, saved, settings)
    }

    /// "Stop and Start New Lecture" while notes are streaming in.
    @Test func aNewLectureGetsNothingFromTheOneItReplaced() async throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, saved, settings) = try await sessionWritingNotes(history)

        let material = FileManager.default.temporaryDirectory.appending(path: "stopped-\(UUID().uuidString).txt")
        try "Binary search halves the range at each step.".write(to: material, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: material) }
        session.start([], materials: [material], title: "New", settings: settings)

        var phases: [LectureSession.Phase] = []
        for _ in 0..<400 {
            if phases.last != session.phase { phases.append(session.phase) }
            if session.title == "New", session.liveNotes == StallingModelServer.partialReply { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(phases == [.processing, .summarizing], "The new lecture never looks finished while it is being made")
        #expect(session.versions.isEmpty, "The stopped lecture's unfinished notes are not the new lecture's notes")
        #expect(session.writingDetail == .detailed)
        #expect(history.lecture(saved.id)?.hasNotes == false, "Notes cut short are not saved as finished")
        session.reset()
    }

    /// Asking for notes again while notes are being written.
    @Test func aStoppedRequestIsNotSavedAndLeavesTheNextOneAlone() async throws {
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, saved, settings) = try await sessionWritingNotes(history)

        session.resummarize(settings: settings, detail: .concise)
        try await wait { session.liveNotes == StallingModelServer.partialReply && session.writingDetail == .concise }
        try await Task.sleep(for: .milliseconds(200))
        #expect(history.lecture(saved.id)?.hasNotes == false)
        #expect(session.versions.isEmpty)
        #expect(session.phase == .summarizing)
        #expect(session.writingDetail == .concise, "The second request is still marked as being written")
        #expect(session.failedDetail == nil)
        session.reset()
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .idle)
        #expect(session.versions.isEmpty)
    }

    /// A model that answers with nothing (seen with models that only "think", and with a filtered reply).
    @Test func anEmptyReplyIsAFailureNotNotes() async throws {
        let host = "empty.lecture-me-faster.test"
        MockModelServer.start(host: host, chat: { _ in "  \n" })
        defer { MockModelServer.stop(host: host) }
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try history.save(title: "Old", transcript: transcript, frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(saved)

        session.resummarize(settings: settings(host: host), detail: .detailed)
        try await wait { !session.isBusy }
        #expect(session.phase == .failed(FileToAI.Failure.empty.localizedDescription))
        #expect(session.failedDetail == .detailed)
        #expect(!session.hasVersion(.detailed))
        #expect(history.lecture(saved.id)?.hasNotes == false, "The sidebar still says the notes are unfinished")
    }

    /// The Cancel button while a recording is being transcribed. A cancelled transcription returns the part
    /// it had finished instead of failing; before the fix that part was saved as a lecture with no name
    /// and sent to the model.
    @Test(.timeLimit(.minutes(3))) func cancelWhileTranscribingSavesAndSendsNothing() async throws {
        let sentence = "A pointer is a variable that holds the address of another variable, and an array name is the address of its first element. "
        let audio = try await TestMedia.makeSpeech(String(repeating: sentence, count: 60))
        defer { try? FileManager.default.removeItem(at: audio) }
        let host = "cancel.lecture-me-faster.test"
        let log = MockModelServer.start(host: host)
        defer { MockModelServer.stop(host: host) }
        let (history, root) = makeHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LectureSession(history: history)

        session.start([audio], title: "Cancelled", settings: settings(host: host))
        // Press Cancel once some of the speech has been recognized.
        try await wait(upTo: 60) { session.transcriptProgress > 0.05 || !session.isBusy }
        try #require(session.phase == .processing, "The recording must still be being transcribed when Cancel is pressed")
        session.reset()

        // Long enough for the stopped work to have come back and (before the fix) saved itself.
        try await Task.sleep(for: .seconds(4))
        #expect(session.phase == .idle)
        #expect(session.transcript.isEmpty)
        #expect(session.runningParts.isEmpty)
        #expect(history.lectures.isEmpty, "A cancelled lecture is not saved")
        #expect(!log.requestURLs.contains { $0.path().hasSuffix("chat/completions") }, "A cancelled lecture is not sent to the model")
    }
}
