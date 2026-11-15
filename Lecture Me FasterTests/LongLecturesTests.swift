import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Lectures too long for one request: sizes, planning, prompts, and the whole write-in-parts flow.
/// Serialized because the flow tests share one mock server registered for the whole process.
@MainActor
@Suite(.serialized)
struct LongLecturesTests {
    /// A transcript of `count` 30-second segments, each about `tokens` tokens long.
    private func transcript(_ count: Int, tokens: Int = 300) -> [TranscriptSegment] {
        (0..<count).map { TranscriptSegment(seconds: Double($0) * 30, text: "Segment \($0) " + String(repeating: "x", count: tokens * 3)) }
    }

    private func sectionTokens(_ section: LongLectures.Plan.Section, _ transcript: [TranscriptSegment], frames: Int = 0) -> Int {
        LongLectures.overheadTokens
            + section.transcript.reduce(0) { $0 + LongLectures.tokens(in: transcript[$1].text) + 4 }
            + section.frames.count * LongLectures.tokensPerImage
            + section.documents.reduce(0) { $0 + LongLectures.tokens(in: $1.text) + 20 }
    }

    // MARK: Budgets and windows

    @Test func budgetsLeaveRoomForTheNotes() {
        #expect(LongLectures.inputBudget(provider: .claude, contextTokens: 1_000_000) == 936_000)
        #expect(LongLectures.inputBudget(provider: .ollama, contextTokens: 131_072) == 131_072 - 16_384)
        #expect(LongLectures.inputBudget(provider: .ollama, contextTokens: 8_192) == 8_192 - 2_048)
        #expect(LongLectures.inputBudget(provider: .openAICompatible, contextTokens: 1_000) == 4_000, "Never below a floor")
    }

    @Test func readsOllamaContextLength() throws {
        let gemma = Data(#"{"model_info":{"general.architecture":"gemma3","gemma3.context_length":131072,"gemma3.embedding_length":3840}}"#.utf8)
        #expect(LongLectures.ollamaContextLength(from: gemma) == 131_072)
        let noArchitecture = Data(#"{"model_info":{"llama.context_length":8192}}"#.utf8)
        #expect(LongLectures.ollamaContextLength(from: noArchitecture) == 8_192)
        #expect(LongLectures.ollamaContextLength(from: Data(#"{"details":{}}"#.utf8)) == nil)
    }

    @Test func readsClaudeContextWindow() {
        let model = Data(#"{"id":"claude-opus-5-5","max_input_tokens":1000000,"max_tokens":128000}"#.utf8)
        #expect(LongLectures.claudeContextWindow(from: model) == 1_000_000)
        #expect(LongLectures.claudeContextWindow(from: Data("{}".utf8)) == nil)
    }

    @Test func openAICompatibleServersUseTheSetting() async {
        let config = AIConfiguration(provider: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:9")!, model: "m", apiKey: "")
        #expect(await LongLectures.contextWindow(for: config, openAICompatibleSetting: 16_384) == 16_384)
    }

    @Test func ollamaSettingIsUsedWithoutAskingTheServer() async {
        // Port 9 answers nothing, so a result other than the fallback must come from the setting.
        let config = AIConfiguration(provider: .ollama, baseURL: URL(string: "http://127.0.0.1:9")!, model: "nemotron3:33b-mlx", apiKey: "")
        #expect(await LongLectures.contextWindow(for: config, openAICompatibleSetting: 0, ollamaSetting: 262_144) == 262_144)
        #expect(await LongLectures.contextWindow(for: config, openAICompatibleSetting: 0) == LongLectures.fallbackContextTokens)
    }

    // MARK: Planning

    @Test func aLectureThatFitsIsOneRequest() {
        let segments = transcript(10)
        let plan = LongLectures.plan(transcript: segments, frameTimes: [0, 60], documents: [], budget: 100_000)
        #expect(!plan.needsSplitting)
        #expect(plan.sections == [.init(transcript: 0..<10, frames: 0..<2, documents: [])])
    }

    @Test func aLongLectureIsSplitByTimeWithEveryPieceUsedOnce() {
        let segments = transcript(100)  // about 30,000 tokens
        let frameTimes = stride(from: 0.0, to: 3_000, by: 300).map { $0 }  // 10 slides
        let budget = 10_000
        let plan = LongLectures.plan(transcript: segments, frameTimes: frameTimes, documents: [], budget: budget)

        #expect(plan.needsSplitting)
        #expect(plan.sections.count >= 4)
        // Contiguous and in order: every segment and slide exactly once.
        #expect(plan.sections.flatMap { Array($0.transcript) } == Array(0..<100))
        #expect(plan.sections.flatMap { Array($0.frames) } == Array(0..<10))
        for section in plan.sections {
            #expect(sectionTokens(section, segments) <= budget, "Each part fits the window")
            // Slides go with the part of the lecture they were shown in.
            let times = section.transcript.map { segments[$0].seconds }
            for frame in section.frames where !times.isEmpty {
                #expect(frameTimes[frame] <= times.max()! + 30)
            }
        }
    }

    @Test func smallMaterialsAreSentWithEveryPart() {
        let reading = LectureDocument(name: "reading.pdf", kind: .pdf, text: String(repeating: "r", count: 3_000))
        let plan = LongLectures.plan(transcript: transcript(100), frameTimes: [], documents: [reading], budget: 10_000)
        #expect(plan.needsSplitting)
        #expect(plan.sections.allSatisfy { $0.documents == [reading] })
    }

    @Test func largeMaterialsGetTheirOwnPartsSplitAtParagraphs() {
        let paragraphs = (0..<40).map { "Paragraph \($0) " + String(repeating: "p", count: 1_500) }
        let book = LectureDocument(name: "book.docx", kind: .word, text: paragraphs.joined(separator: "\n\n"))  // ~20,000 tokens
        let segments = transcript(10)
        let plan = LongLectures.plan(transcript: segments, frameTimes: [], documents: [book], budget: 10_000)

        let lectureParts = plan.sections.filter { !$0.isMaterialsOnly }
        let materialParts = plan.sections.filter(\.isMaterialsOnly)
        #expect(lectureParts.allSatisfy { $0.documents.isEmpty }, "Too big to send with every part")
        #expect(materialParts.count >= 2)
        let pieces = materialParts.flatMap(\.documents)
        #expect(pieces.first?.name == "book.docx (part 1 of \(pieces.count))")
        #expect(pieces.map(\.text).joined(separator: "\n\n") == book.text, "Split at paragraph breaks, nothing lost")
        for section in materialParts { #expect(sectionTokens(section, segments) <= 10_000) }
    }

    @Test func splittingTextKeepsParagraphsWhole() {
        let text = ["aaaa", "bbbb", "cccc"].joined(separator: "\n\n")
        #expect(LongLectures.split(text, maxTokens: 100) == [text])
        #expect(LongLectures.split(text, maxTokens: 4) == ["aaaa", "bbbb", "cccc"])
        let oneLongParagraph = String(repeating: "z", count: 100)
        #expect(LongLectures.split(oneLongParagraph, maxTokens: 11).joined() == oneLongParagraph)
        #expect(LongLectures.split(oneLongParagraph, maxTokens: 11).allSatisfy { $0.count <= 30 })
    }

    // MARK: Prompts

    @Test func eachPartIsToldWhereItIs() {
        let segments = transcript(4)
        let section = LongLectures.Plan.Section(transcript: 2..<4, frames: 0..<0, documents: [])
        let text = LongLectures.sectionInstructions(index: 1, count: 3, section: section, transcript: segments, frameTimes: [])
        #expect(text.contains("part 2 of 3"))
        #expect(text.contains("from [1:00] to about [1:30]"))
        #expect(text.contains("Don't write an introduction"))

        let materials = LongLectures.Plan.Section(transcript: 0..<0, frames: 0..<0, documents: [])
        #expect(LongLectures.sectionInstructions(index: 2, count: 3, section: materials, transcript: segments, frameTimes: [])
            .contains("only some of the supporting materials"))
    }

    @Test func briefLevelsAreRewrittenAndDetailedLevelsJoined() {
        #expect(LongLectures.combinesByRewriting(.keyPoints))
        #expect(LongLectures.combinesByRewriting(.concise))
        #expect(!LongLectures.combinesByRewriting(.detailed))
        #expect(!LongLectures.combinesByRewriting(.complete))
        #expect(LongLectures.joined(partNotes: ["# A\n", "# B"], takeaways: "## Key takeaways\n- x") == "# A\n\n---\n\n# B\n\n## Key takeaways\n- x")
        #expect(LongLectures.combineRequest(partNotes: ["one", "two"], detail: .concise).contains("=== Part 2 ===\ntwo"))
    }

    @Test func aMaterialsOnlyPartDoesNotClaimThereIsNoRecording() {
        let section = FileToAI.promptParts(title: "T", transcript: [], frames: [], documents: [], isSection: true)
        let whole = FileToAI.promptParts(title: "T", transcript: [], frames: [], documents: [])
        func texts(_ parts: [FileToAI.Part]) -> [String] { parts.compactMap { if case .text(let t) = $0 { t } else { nil } } }
        #expect(!texts(section).contains("There is no recording transcript for this lecture."))
        #expect(texts(whole).contains("There is no recording transcript for this lecture."))
    }

    // MARK: The whole flow

    /// An OpenAI-compatible server on a made-up host, answered inside the app by `MockModelServer`.
    private func settings(contextTokens: Int, splitWithoutAsking: Bool = false, detail: NoteDetail = .detailed) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(MockModelServer.host)/v1"
        stored.openAIModel = "mock-model"
        stored.openAIContextTokens = contextTokens
        stored.splitWithoutAsking = splitWithoutAsking
        stored.noteDetail = detail
        return AppSettings(unsaved: stored)
    }

    private func waitUntilIdle(_ session: LectureSession) async throws {
        for _ in 0..<400 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!session.isBusy)
    }

    private func lecture(_ segments: [TranscriptSegment], history: LectureHistory) throws -> LectureSession {
        let saved = try history.save(title: "Long lecture", transcript: segments, frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(saved)
        return session
    }

    @Test(arguments: [NoteDetail.detailed, .concise])
    func aLongLectureAsksFirstThenWritesInPartsAndCombines(detail: NoteDetail) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LongLecturesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockModelServer.start()
        defer { MockModelServer.stop() }
        let history = LectureHistory(root: root)
        let session = try lecture(transcript(100), history: history)  // ~30,000 tokens
        let settings = settings(contextTokens: 16_384, detail: detail)  // budget 12,288

        session.resummarize(settings: settings, detail: detail)
        try await waitUntilIdle(session)
        guard case .awaitingSplitApproval(let proposal) = session.phase else {
            Issue.record("Expected to be asked first, got \(session.phase)"); return
        }
        #expect(server.requests.isEmpty, "Nothing is sent before the user agrees")
        #expect(proposal.parts >= 3)
        #expect(proposal.requests == proposal.parts + 1)
        #expect(proposal.contextTokens == 16_384)
        #expect(proposal.detail == detail)

        session.approveSplit(settings: settings)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        #expect(server.requests.count == proposal.parts + 1, "One request per part, plus combining")
        #expect(server.requests.dropLast().enumerated().allSatisfy { $1.contains("This is part \($0 + 1) of \(proposal.parts)") })
        #expect(session.partProgress == nil)

        let notes = session.notes(for: detail)
        if LongLectures.combinesByRewriting(detail) {
            #expect(server.requests.last?.contains("Combine them into one set of notes") == true)
            #expect(notes == "Reply \(proposal.parts + 1)", "The rewrite replaces the parts")
        } else {
            #expect(server.requests.last?.contains("## Key takeaways") == true)
            let expected = (1...proposal.parts).map { "Reply \($0)" }
            #expect(notes == LongLectures.joined(partNotes: expected, takeaways: "Reply \(proposal.parts + 1)"))
        }
        let saved = try #require(LectureHistory(root: root).lectures.first?.noteVersions.first { $0.detail == detail })
        #expect(saved.parts == proposal.parts)
        #expect(saved.text == notes)
    }

    @Test func declining_leavesEverythingAsItWas() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LongLecturesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockModelServer.start()
        defer { MockModelServer.stop() }
        let session = try lecture(transcript(100), history: LectureHistory(root: root))

        session.resummarize(settings: settings(contextTokens: 16_384), detail: .detailed)
        try await waitUntilIdle(session)
        session.declineSplit()
        #expect(session.phase == .done)
        #expect(session.versions.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func dontAskAgainSplitsStraightAway() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LongLecturesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockModelServer.start()
        defer { MockModelServer.stop() }
        let session = try lecture(transcript(100), history: LectureHistory(root: root))

        session.resummarize(settings: settings(contextTokens: 16_384, splitWithoutAsking: true), detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        #expect(server.requests.count > 2)
    }

    @Test func aLectureThatFitsIsSentOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LongLecturesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MockModelServer.start()
        defer { MockModelServer.stop() }
        let session = try lecture(transcript(5), history: LectureHistory(root: root))

        session.resummarize(settings: settings(contextTokens: 16_384), detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        #expect(server.requests.count == 1)
        #expect(session.notes(for: .detailed) == "Reply 1")
        #expect(session.versions.first?.parts == nil)
    }
}
