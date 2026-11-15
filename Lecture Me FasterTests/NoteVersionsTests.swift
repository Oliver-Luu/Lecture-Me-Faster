import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Several versions of a lecture's notes, one per detail level.
@MainActor
struct NoteVersionsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "NoteVersionsTests-\(UUID().uuidString)")

    /// Never saved, and Ollama with no model chosen, so writing notes fails at once without calling a
    /// real model (tests run inside the app, next to the user's keys).
    private func offlineSettings(detail: NoteDetail = .detailed) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .ollama
        stored.ollamaModel = ""
        stored.noteDetail = detail
        return AppSettings(unsaved: stored)
    }

    private func waitUntilIdle(_ session: LectureSession) async throws {
        for _ in 0..<600 where session.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func lectureWithTwoVersions() throws -> (LectureHistory, SavedLecture) {
        let history = LectureHistory(root: root)
        let saved = try history.save(
            title: "Week 4", transcript: [TranscriptSegment(seconds: 0, text: "Heat engines")], frames: [],
            distinctFrameCount: 0
        )
        try history.saveNotes(NoteVersion(detail: .keyPoints, text: "Short", model: "m", writtenAt: .now), for: saved.id)
        try history.saveNotes(NoteVersion(detail: .complete, text: "Long", model: "m", writtenAt: .now), for: saved.id)
        return (history, try #require(history.lecture(saved.id)))
    }

    @Test func aFailedLevelDoesNotTouchTheOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (history, saved) = try lectureWithTwoVersions()
        let session = LectureSession(history: history)
        session.open(saved)

        session.resummarize(settings: offlineSettings(), detail: .concise)
        try await waitUntilIdle(session)

        #expect(session.phase == .failed("Open Settings and choose an Ollama model."))
        #expect(session.failedDetail == .concise, "The error belongs to the level being written")
        #expect(session.writingDetail == nil)
        #expect(session.notes(for: .keyPoints) == "Short")
        #expect(session.notes(for: .complete) == "Long")
        #expect(LectureHistory(root: root).lecture(saved.id)?.noteVersions.map(\.detail) == [.keyPoints, .complete])
    }

    @Test func aNewLectureWritesTheLevelChosenWhenItWasAdded() async throws {
        let notes = try TestDocuments.write(Data("Reading about entropy".utf8), extension: "txt")
        defer { try? FileManager.default.removeItem(at: notes) }
        let session = LectureSession()

        session.start([], materials: [notes], title: "Reading", settings: offlineSettings(detail: .keyPoints))
        try await waitUntilIdle(session)
        #expect(session.failedDetail == .keyPoints)
    }

    @Test func lecturesWithOnlyMaterialsCanBeRewritten() async throws {
        let notes = try TestDocuments.write(Data("Reading about entropy".utf8), extension: "txt")
        defer { try? FileManager.default.removeItem(at: notes) }
        let session = LectureSession()
        session.start([], materials: [notes], title: "Reading", settings: offlineSettings())
        try await waitUntilIdle(session)

        #expect(session.transcript.isEmpty)
        #expect(session.hasSource, "Material text is enough to write notes from")
    }

    @Test func versionsAreOrderedBriefToThorough() {
        let date = Date.now
        let shuffled = [NoteDetail.complete, .keyPoints, nil, .detailed, .concise].map {
            NoteVersion(detail: $0, text: "", model: "", writtenAt: date)
        }
        #expect(NoteVersion.ordered(shuffled).map(\.detail) == [nil, .keyPoints, .concise, .detailed, .complete])
    }
}
