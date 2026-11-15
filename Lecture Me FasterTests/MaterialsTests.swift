import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Supporting materials in the prompt and in the lecture pipeline.
@MainActor
struct MaterialsTests {
    /// Never saved, and Ollama with no model chosen: the notes step fails at once with a known message
    /// instead of calling a real model (the tests run inside the app, next to the user's keys).
    private func offlineSettings() -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .ollama
        stored.ollamaModel = ""
        return AppSettings(unsaved: stored)
    }

    private let noModel = "Open Settings and choose an Ollama model."

    private func waitUntilIdle(_ session: LectureSession) async throws {
        for _ in 0..<600 where session.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!session.isBusy, "The lecture did not finish within 30 seconds")
    }

    // MARK: Prompt

    @Test func materialsAreAddedToThePromptWithTheirNames() throws {
        let documents = [
            LectureDocument(name: "Week 3 slides.pdf", kind: .pdf, text: "[Page 1]\nCarnot cycle"),
            LectureDocument(name: "empty.png", kind: .image, text: ""),
            LectureDocument(name: "reading.docx", kind: .word, text: "Long reading", wasTrimmed: true),
        ]
        let parts = FileToAI.promptParts(
            title: "Week 3", transcript: [TranscriptSegment(seconds: 0, text: "Hello")], frames: [], documents: documents
        )
        let texts = parts.compactMap { part -> String? in if case .text(let t) = part { t } else { nil } }
        let materials = try #require(texts.first { $0.hasPrefix("Supporting materials") })
        #expect(materials.contains("=== Week 3 slides.pdf (PDF) ===\n[Page 1]\nCarnot cycle"))
        #expect(materials.contains("=== reading.docx (Word document) ===\n[Only the first"))
        #expect(!materials.contains("empty.png"), "Files with no text are left out")
        #expect(texts.last?.hasPrefix("Transcript:") == true, "The transcript still comes last")
    }

    @Test func aLectureWithoutARecordingSaysSo() {
        let parts = FileToAI.promptParts(
            title: "Reading", transcript: [], frames: [],
            documents: [LectureDocument(name: "a.txt", kind: .text, text: "Notes")]
        )
        guard case .text(let last) = parts.last else { Issue.record("Expected text"); return }
        #expect(last == "There is no recording transcript for this lecture. Write the notes from the materials above.")
    }

    @Test func aRecordingWithNoSpeechPointsTheModelAtTheSlides() {
        // A video whose audio had no recognizable speech: only the slides remain.
        let frames = [LectureFrame(seconds: 0, jpeg: Data([1]))]
        let parts = FileToAI.promptParts(title: "Silent", transcript: [], frames: frames)
        guard case .text(let last) = parts.last else { Issue.record("Expected text"); return }
        #expect(last == "There is no recording transcript for this lecture. No speech was recognized in the recording. Write the notes from the slides above.")
        #expect(FileToAI.noTranscriptText(hasSlides: true, hasMaterials: true).hasSuffix("from the slides and materials above."))
        #expect(FileToAI.noTranscriptText(hasSlides: false, hasMaterials: false) == "There is no recording transcript for this lecture.")
    }

    @MainActor
    @Test func slidesAloneAreEnoughToWriteNotes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MaterialsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LectureHistory(root: root)
        let silent = try history.save(title: "Silent", transcript: [], frames: [LectureFrame(seconds: 0, jpeg: Data([1]))], distinctFrameCount: 1)
        let empty = try history.save(title: "Empty", transcript: [], frames: [], distinctFrameCount: 0)
        let session = LectureSession(history: history)
        session.open(silent)
        #expect(session.hasSource, "Rewriting notes for a silent video with slides stays possible")
        session.open(empty)
        #expect(!session.hasSource)
    }

    @Test func theModelIsToldHowToUseMaterials() {
        for level in NoteDetail.allCases {
            let prompt = FileToAI.systemPrompt(detail: level)
            #expect(prompt.contains("supporting materials"))
            #expect(prompt.contains("From the materials"))
            #expect(prompt.contains("If there is no transcript (no speech was recognized in the recording), write the notes from the slides and materials you are given."))
        }
    }

    // MARK: Pipeline

    @Test func aLectureCanBeMadeFromMaterialsAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MaterialsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let docx = try TestDocuments.write(TestDocuments.docx, extension: "docx")
        defer { try? FileManager.default.removeItem(at: docx) }
        let history = LectureHistory(root: root)
        let session = LectureSession(history: history)

        session.start([], materials: [docx], title: "Reading", settings: offlineSettings())
        #expect(session.materialCount == 1)
        try await waitUntilIdle(session)

        #expect(session.documents.map(\.kind) == [.word])
        #expect(session.documents.first?.text.contains("isolated system") == true)
        #expect(session.phase == .failed(noModel), "Reached the notes step instead of failing for lack of audio")
        let saved = try #require(history.lectures.first)
        #expect(saved.title == "Reading")
        #expect(saved.documents == session.documents, "Materials are saved with the lecture")
        #expect(LectureHistory(root: root).lecture(saved.id)?.documents == session.documents, "…and survive a relaunch")
    }

    @Test func aSilentVideoIsFineWhenMaterialsSupplyText() async throws {
        let video = try await TestMedia.makeSlideVideo(slides: 2, secondsPerSlide: 2)
        let pptx = try TestDocuments.write(TestDocuments.pptx, extension: "pptx")
        defer { [video, pptx].forEach { try? FileManager.default.removeItem(at: $0) } }
        let session = LectureSession()

        session.start([video], materials: [pptx], title: "Slides only", settings: offlineSettings())
        try await waitUntilIdle(session)
        #expect(session.phase == .failed(noModel))
        #expect(session.frames.count == 2, "The video's slides are kept")
        #expect(session.transcript.isEmpty)
    }

    @Test func anUnreadableFileIsKeptWithItsErrorAndDoesNotStopTheLecture() async throws {
        let broken = try TestDocuments.write(Data("not really a docx".utf8), extension: "docx")
        let notes = try TestDocuments.write(Data("Usable notes".utf8), extension: "txt")
        defer { [broken, notes].forEach { try? FileManager.default.removeItem(at: $0) } }
        let session = LectureSession()

        session.start([], materials: [broken, notes], title: "Mixed", settings: offlineSettings())
        try await waitUntilIdle(session)
        #expect(session.phase == .failed(noModel))
        #expect(session.documents.count == 2)
        #expect(session.documents[0].readError != nil)
        #expect(session.documents[0].text.isEmpty)
        #expect(session.documents[1].text == "Usable notes")
    }

    @Test func materialsWithNoTextAndNoRecordingFail() async throws {
        let blank = try TestDocuments.write(Data("   \n".utf8), extension: "txt")
        defer { try? FileManager.default.removeItem(at: blank) }
        let session = LectureSession()

        session.start([], materials: [blank], title: "Blank", settings: offlineSettings())
        try await waitUntilIdle(session)
        #expect(session.phase == .failed(LectureSession.Failure.noText.localizedDescription))
    }

    @Test func unsavedSettingsNeverTouchTheRealOnes() {
        let before = UserDefaults.standard.data(forKey: "settings")
        let settings = offlineSettings()
        settings.stored.maxFrames = 77
        settings.claudeKey = "should-not-be-saved"
        #expect(UserDefaults.standard.data(forKey: "settings") == before)
    }
}
