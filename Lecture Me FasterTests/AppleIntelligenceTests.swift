import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Apple Intelligence as a provider, and the splitting it relies on.
@MainActor
struct AppleIntelligenceTests {
    @Test func newInstallsUseAppleIntelligence() {
        #expect(AppSettings.Stored().provider == .apple)
        #expect(AIProvider.allCases.first == .apple)
        #expect(AIProvider.apple.label == "Apple Intelligence (free)")
    }

    @Test func itNeedsNoAddressOrKey() throws {
        var stored = AppSettings.Stored()
        stored.provider = .apple
        let settings = AppSettings(unsaved: stored)
        #expect(settings.connection()?.provider == .apple)
        #expect(settings.connection()?.apiKey == "")
        if AppleIntelligence.isAvailable {
            #expect(try settings.configuration().model == AppleIntelligence.modelID)
        } else {
            #expect(throws: AppSettings.Problem.self) { try settings.configuration() }
        }
    }

    @Test func streamingSendsOnlyTheNewText() {
        #expect(AppleIntelligence.newText(in: "Entropy", after: "") == "Entropy")
        #expect(AppleIntelligence.newText(in: "Entropy is", after: "Entropy") == " is")
        #expect(AppleIntelligence.newText(in: "Entropy is", after: "Entropy is") == "")
        #expect(AppleIntelligence.newText(in: "Entrophy is high", after: "Entropy is") == "s high", "A revised snapshot yields what lies past the old length; already-sent text cannot be taken back")
        #expect(AppleIntelligence.newText(in: "Short", after: "Much longer text") == "")
    }

    @Test func theModelListHasTheOneOnDeviceModel() async throws {
        let models = try await ModelCatalog.models(for: AppSettings.appleConfiguration)
        #expect(models.map(\.id) == [AppleIntelligence.modelID])
        #expect(models.first?.acceptsImages == true)
        let lines = AIModelFields.describeBrief(models.first, provider: .apple)
        #expect(lines.first?.hasPrefix("Apple's on-device model") == true)
    }
}

/// Planning and combining for small windows like Apple Intelligence's.
@MainActor
@Suite(.serialized)
struct SmallWindowTests {
    private func transcript(_ count: Int, tokens: Int = 300) -> [TranscriptSegment] {
        (0..<count).map { TranscriptSegment(seconds: Double($0) * 30, text: "Segment \($0) " + String(repeating: "x", count: tokens * 3)) }
    }

    @Test func measuredSizesMakeFewerBiggerParts() {
        let segments = transcript(60)
        let generic = LongLectures.plan(transcript: segments, frameTimes: [], documents: [], budget: 6_144)
        let measured = LongLectures.plan(
            transcript: segments, frameTimes: [], documents: [], budget: 6_144,
            overhead: 1_000, imageTokens: 400, charactersPerToken: 4.5
        )
        #expect(generic.overhead == LongLectures.overheadTokens)
        #expect(measured.overhead == 1_000)
        #expect(measured.sections.count < generic.sections.count, "Apple's real token counts fit more in each part")
        #expect(measured.sections.flatMap { Array($0.transcript) } == Array(0..<60))
    }

    @Test func measuredImageCostDecidesHowManySlidesFit() {
        let slides = stride(from: 0.0, to: 600, by: 30).map { $0 }  // 20 slides, no transcript
        let cheap = LongLectures.plan(transcript: [], frameTimes: slides, documents: [], budget: 6_000, overhead: 1_000, imageTokens: 250)
        let costly = LongLectures.plan(transcript: [], frameTimes: slides, documents: [], budget: 6_000, overhead: 1_000, imageTokens: 1_600)
        #expect(cheap.sections.count == 1)
        #expect(costly.sections.count == 7)
    }

    @Test func notesAreGroupedSoEachMergeFits() {
        let note = String(repeating: "n", count: 3_000)  // about 1,000 tokens
        let groups = LongLectures.batches(Array(repeating: note, count: 7), budget: 4_000, overhead: 1_000)
        #expect(groups.map(\.count) == [2, 2, 2, 1])
        #expect(LongLectures.batches([String(repeating: "h", count: 30_000)], budget: 4_000, overhead: 1_000).map(\.count) == [1], "A note too big to share goes alone")
        #expect(LongLectures.fits("short", budget: 1_100, overhead: 1_000))
        #expect(!LongLectures.fits(note, budget: 1_500, overhead: 1_000))
    }

    @Test func inBetweenMergesDontAddTakeaways() {
        let round = LongLectures.combineRequest(partNotes: ["a", "b"], detail: .concise, isFinal: false)
        #expect(round.contains("consecutive parts of a longer lecture"))
        #expect(round.contains("Don't add an introduction or key takeaways"))
        #expect(LongLectures.combineRequest(partNotes: ["a", "b"], detail: .concise).contains("end with a short list of key takeaways"))
    }

    // MARK: Combining in rounds, end to end

    /// Parts get long replies (so all of them can't be merged at once); merges get short ones.
    private func startServer(host: String) -> MockModelServer.Log {
        MockModelServer.start(host: host) { request in
            let body = String(decoding: request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? request.httpBody ?? Data(), as: UTF8.self)
            let reply: String
            if body.contains("This is part") {
                reply = "PART " + String(repeating: "p", count: 9_000)  // about 3,000 tokens
            } else if body.contains("consecutive parts of a longer lecture") {
                reply = "MERGED"
            } else {
                reply = "FINAL"
            }
            return (200, "data: {\"choices\":[{\"delta\":{\"content\":\"\(reply)\"}}]}\n\ndata: [DONE]\n\n")
        }
    }

    private func settings(host: String, detail: NoteDetail) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(host)/v1"
        stored.openAIModel = "mock"
        stored.openAIContextTokens = 16_384  // budget 12,288 with 3,000 overhead
        stored.splitWithoutAsking = true
        stored.noteDetail = detail
        return AppSettings(unsaved: stored)
    }

    private func run(detail: NoteDetail, host: String) async throws -> (LectureSession, MockModelServer.Log) {
        let log = startServer(host: host)
        let session = LectureSession()
        let saved = SavedLecture(id: UUID(), title: "Long", createdAt: .now, transcript: transcript(100), frameSeconds: [], distinctFrameCount: 0, summary: "", deletedAt: nil)
        session.open(saved)
        session.resummarize(settings: settings(host: host, detail: detail), detail: detail)
        for _ in 0..<400 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        return (session, log)
    }

    @Test func briefNotesTooLongToMergeAtOnceAreMergedInRounds() async throws {
        let host = "rounds-concise.test"
        defer { MockModelServer.stop(host: host) }
        let (session, log) = try await run(detail: .concise, host: host)

        #expect(session.phase == .done)
        let parts = log.requests.filter { $0.contains("This is part") }.count
        let merges = log.requests.filter { $0.contains("consecutive parts of a longer lecture") }.count
        #expect(parts >= 3)
        #expect(merges >= 1, "The parts' notes didn't fit one request, so they were merged in rounds first")
        #expect(log.requests.last?.contains("Combine them into one set of notes") == true)
        #expect(session.notes(for: .concise) == "FINAL")
    }

    @Test func detailedNotesKeepEveryPartWhileTheTakeawaysUseRounds() async throws {
        let host = "rounds-detailed.test"
        defer { MockModelServer.stop(host: host) }
        let (session, log) = try await run(detail: .detailed, host: host)

        #expect(session.phase == .done)
        let parts = log.requests.filter { $0.contains("This is part") }.count
        #expect(log.requests.contains { $0.contains("consecutive parts of a longer lecture") })
        #expect(log.requests.last?.contains("## Key takeaways") == true)
        let notes = session.notes(for: .detailed)
        #expect(notes.components(separatedBy: "PART ").count - 1 == parts, "Every part's notes are kept as written")
        #expect(notes.hasSuffix("FINAL"))
        #expect(!notes.contains("MERGED"), "Merged copies only feed the takeaways")
    }
}

/// The real on-device model. Free and private, but each run takes real time, so these only run when
/// asked: `TEST_RUNNER_LMF_LIVE_APPLE=1 xcodebuild test ...`
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LMF_LIVE_APPLE"] == "1" && AppleIntelligence.isAvailable))
struct LiveAppleIntelligenceTests {
    @Test func measuresTextAndImages() async throws {
        #expect(AppleIntelligence.contextSize >= 4_096)
        let perToken = try #require(await AppleIntelligence.charactersPerToken(sample: String(repeating: "The second law of thermodynamics says entropy increases. ", count: 20)))
        #expect(perToken > 3, "English is more than 3 characters per token for Apple's tokenizer")
        let frame = try await TestMedia.makeSlideVideo(slides: 1, secondsPerSlide: 2)
        defer { try? FileManager.default.removeItem(at: frame) }
        let output = try await VideoToFrames.extract(from: frame) { _ in }
        let imageTokens = try await AppleIntelligence.tokens(forImage: try #require(output.frames.first).jpeg)
        #expect((imageTokens ?? 0) > 0)
    }

    @Test func writesALongLectureInPartsOnTheDevice() async throws {
        let sentences = [
            "Today we cover the first law of thermodynamics: energy is conserved.",
            "Heat added to a system equals the change in internal energy plus the work done by the system.",
            "Next, the second law: the entropy of an isolated system never decreases.",
            "A Carnot engine is the most efficient engine possible between two temperatures.",
        ]
        // About 15,000 tokens of transcript: about two to four parts in an 8,192-token window.
        let transcript = (0..<240).map { TranscriptSegment(seconds: Double($0) * 15, text: sentences[$0 % 4] + " " + sentences[($0 + 1) % 4]) }
        var stored = AppSettings.Stored()
        stored.provider = .apple
        stored.noteDetail = .keyPoints
        let settings = AppSettings(unsaved: stored)
        let session = LectureSession()
        session.open(SavedLecture(id: UUID(), title: "Thermodynamics", createdAt: .now, transcript: transcript, frameSeconds: [], distinctFrameCount: 0, summary: "", deletedAt: nil))

        let start = Date()
        session.resummarize(settings: settings, detail: .keyPoints)
        for _ in 0..<1_200 where session.isBusy { try await Task.sleep(for: .milliseconds(250)) }
        let notes = session.notes(for: .keyPoints)
        print("LIVE: phase=\(session.phase) parts=\(session.versions.first?.parts.map(String.init) ?? "1") seconds=\(Int(Date().timeIntervalSince(start))) chars=\(notes.count)")
        print("LIVE NOTES:\n\(notes.prefix(1_500))")
        #expect(session.phase == .done)
        #expect((session.versions.first?.parts ?? 1) > 1, "Too long for one request, so it was written in parts without asking")
        #expect(notes.localizedCaseInsensitiveContains("entropy"))
    }
}
