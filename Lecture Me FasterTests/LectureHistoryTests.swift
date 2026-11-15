import Foundation
import Testing
@testable import Lecture_Me_Faster

/// A clock the tests can move forward.
final class TestClock {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(days: Double) { date += days * 86_400 }
}

@MainActor
struct LectureHistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureHistoryTests-\(UUID().uuidString)")
    let clock = TestClock()

    private func makeHistory() -> LectureHistory {
        let clock = clock
        return LectureHistory(root: root) { clock.date }
    }

    private func saveSample(in history: LectureHistory, title: String = "Week 1") throws -> SavedLecture {
        try history.save(
            title: title,
            transcript: [TranscriptSegment(seconds: 0, text: "Hello"), TranscriptSegment(seconds: 5, text: "World")],
            frames: [LectureFrame(seconds: 0, jpeg: Data([0xFF, 0xD8, 1])), LectureFrame(seconds: 8, jpeg: Data([0xFF, 0xD8, 2]))],
            distinctFrameCount: 3
        )
    }

    @Test func savedLecturesSurviveARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveSample(in: makeHistory())

        let reopened = makeHistory()
        #expect(reopened.lectures == [saved])
        let frames = reopened.frames(for: saved)
        #expect(frames.map(\.seconds) == [0, 8])
        #expect(frames.map(\.jpeg) == [Data([0xFF, 0xD8, 1]), Data([0xFF, 0xD8, 2])])
    }

    @Test func historyIsNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        _ = try saveSample(in: history, title: "Old")
        clock.advance(days: 1)
        _ = try saveSample(in: history, title: "New")
        #expect(history.lectures.map(\.title) == ["New", "Old"])
        #expect(makeHistory().lectures.map(\.title) == ["New", "Old"])
    }

    private func version(_ detail: NoteDetail?, _ text: String, model: String = "m") -> NoteVersion {
        NoteVersion(detail: detail, text: text, model: model, writtenAt: clock.date)
    }

    @Test func notesAreSavedAfterTheLecture() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)
        #expect(!saved.hasNotes)

        try history.saveNotes(version(.detailed, "# Notes"), for: saved.id)
        #expect(history.lecture(saved.id)?.noteVersions == [version(.detailed, "# Notes")])
        #expect(makeHistory().lecture(saved.id)?.noteVersions == [version(.detailed, "# Notes")])
        #expect(makeHistory().lecture(saved.id)?.hasNotes == true)
    }

    @Test func eachDetailLevelKeepsItsOwnVersion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        try history.saveNotes(version(.complete, "Long"), for: saved.id)
        try history.saveNotes(version(.keyPoints, "Short"), for: saved.id)
        try history.saveNotes(version(.detailed, "Medium"), for: saved.id)
        #expect(makeHistory().lecture(saved.id)?.noteVersions.map(\.detail) == [.keyPoints, .detailed, .complete],
                "Kept in slider order")

        try history.saveNotes(version(.keyPoints, "Shorter", model: "other"), for: saved.id)
        let versions = try #require(makeHistory().lecture(saved.id)?.noteVersions)
        #expect(versions.count == 3, "Rewriting a level replaces it instead of adding another")
        #expect(versions.first { $0.detail == .keyPoints }?.text == "Shorter")
        #expect(versions.first { $0.detail == .keyPoints }?.model == "other")
        #expect(versions.first { $0.detail == .complete }?.text == "Long", "Other levels are untouched")
    }

    @Test func notesFromBeforeVersionsAreKeptAsEarlierNotes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The record format from before versions: one "summary" string, no "notes".
        try Data("""
            {"id":"\(id.uuidString)","title":"Old","createdAt":800000000,"transcript":[],
             "frameSeconds":[],"distinctFrameCount":0,"summary":"# Old notes"}
            """.utf8).write(to: folder.appending(path: "lecture.json"))

        let history = makeHistory()
        let old = try #require(history.lecture(id))
        #expect(old.noteVersions.count == 1)
        #expect(old.noteVersions.first?.detail == nil)
        #expect(old.noteVersions.first?.text == "# Old notes")

        try history.saveNotes(version(.concise, "New"), for: id)
        let updated = try #require(makeHistory().lecture(id))
        #expect(updated.noteVersions.map(\.detail) == [nil, .concise], "The old notes survive the first new version")
        #expect(updated.noteVersions.first?.text == "# Old notes")
        #expect(updated.summary.isEmpty, "…and are stored only once")
    }

    @Test func deleteAndRestoreMoveBetweenLists() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        try history.moveToRecentlyDeleted(saved.id)
        #expect(history.lectures.isEmpty)
        #expect(history.recentlyDeleted.map(\.id) == [saved.id])
        #expect(makeHistory().recentlyDeleted.map(\.id) == [saved.id])

        try history.restore(saved.id)
        #expect(history.lectures.map(\.id) == [saved.id])
        #expect(history.recentlyDeleted.isEmpty)
        #expect(makeHistory().lectures.first?.deletedAt == nil)
    }

    @Test func onlyRecentlyDeletedLecturesCanBeDeletedForGood() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        try history.deletePermanently(saved.id)
        #expect(history.lectures.count == 1, "A lecture still in the history must not be deleted")

        try history.moveToRecentlyDeleted(saved.id)
        try history.deletePermanently(saved.id)
        #expect(history.recentlyDeleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: saved.id.uuidString).path(percentEncoded: false)))
        #expect(makeHistory().lecture(saved.id) == nil)
    }

    @Test func emptyingRecentlyDeletedLeavesTheHistoryAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let kept = try saveSample(in: history, title: "Kept")
        let first = try saveSample(in: history, title: "Gone 1")
        let second = try saveSample(in: history, title: "Gone 2")
        try history.moveToRecentlyDeleted(first.id)
        try history.moveToRecentlyDeleted(second.id)

        try history.emptyRecentlyDeleted()
        #expect(history.recentlyDeleted.isEmpty)
        #expect(makeHistory().lectures.map(\.id) == [kept.id])
    }

    @Test func recentlyDeletedExpiresAfterThirtyDays() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)
        try history.moveToRecentlyDeleted(saved.id)
        #expect(history.daysRemaining(for: history.recentlyDeleted[0]) == 30)

        clock.advance(days: 29.5)
        #expect(history.daysRemaining(for: history.recentlyDeleted[0]) == 1)
        #expect(makeHistory().recentlyDeleted.count == 1, "Not expired yet")

        clock.advance(days: 0.5)
        #expect(history.daysRemaining(for: history.recentlyDeleted[0]) == 0)
        #expect(makeHistory().recentlyDeleted.isEmpty, "Purged on launch after 30 days")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: saved.id.uuidString).path(percentEncoded: false)))
    }

    @Test func renamingIsSavedAndTrimmed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        try history.rename(saved.id, to: "  Thermodynamics, Week 1 \n")
        #expect(history.lecture(saved.id)?.title == "Thermodynamics, Week 1")
        #expect(makeHistory().lecture(saved.id)?.title == "Thermodynamics, Week 1", "Survives a relaunch")
        #expect(makeHistory().lecture(saved.id)?.createdAt == saved.createdAt, "Renaming doesn't reorder history")
    }

    @Test func emptyNamesAreIgnored() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        try history.rename(saved.id, to: "   ")
        #expect(history.lecture(saved.id)?.title == "Week 1")
        try history.rename(UUID(), to: "Nothing")  // unknown lecture: no error, no change
        #expect(history.lectures.map(\.title) == ["Week 1"])
    }

    @Test func aRenamedLectureUsesItsNewNameWhenSummarizedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)
        let session = LectureSession(history: history)
        session.open(saved)

        try history.rename(saved.id, to: "Entropy")
        session.rename(to: "Entropy")
        #expect(session.title == "Entropy")
        session.rename(to: "  ")
        #expect(session.title == "Entropy", "An empty name never replaces the title")
    }

    @Test func editingTheToolbarTitleRenamesOnlyWhenSomethingChanged() {
        #expect(RenamableTitle.newName(from: "Entropy", replacing: "attachment", cancelled: false) == "Entropy")
        #expect(RenamableTitle.newName(from: "  Entropy \n", replacing: "attachment", cancelled: false) == "Entropy")
        #expect(RenamableTitle.newName(from: "Entropy", replacing: "attachment", cancelled: true) == nil, "Esc")
        #expect(RenamableTitle.newName(from: "   ", replacing: "attachment", cancelled: false) == nil, "Empty")
        #expect(RenamableTitle.newName(from: "attachment", replacing: "attachment", cancelled: false) == nil, "Unchanged")
    }

    @Test func multiFileLecturesKeepTheirParts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parts = [LecturePart(name: "pt1", startSeconds: 0), LecturePart(name: "pt2", startSeconds: 1800)]
        let saved = try makeHistory().save(title: "Week 3", transcript: [], frames: [], distinctFrameCount: 0, parts: parts)
        #expect(makeHistory().lecture(saved.id)?.parts == parts)

        let session = LectureSession(history: makeHistory())
        session.open(try #require(makeHistory().lecture(saved.id)))
        #expect(session.parts == parts, "Summarize Again needs the parts too")

        let single = try makeHistory().save(
            title: "One", transcript: [], frames: [], distinctFrameCount: 0, parts: [parts[0]]
        )
        #expect(single.parts == nil, "A one-file lecture stores no part list")
    }

    @Test func lecturesSavedBeforePartsExistedStillLoad() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The record format from before multi-file lectures: no "parts" key.
        let oldJSON = """
            {"id":"\(id.uuidString)","title":"Old","createdAt":800000000,"transcript":[],
             "frameSeconds":[],"distinctFrameCount":0,"summary":"# Notes"}
            """
        try Data(oldJSON.utf8).write(to: folder.appending(path: "lecture.json"))

        let lecture = try #require(makeHistory().lecture(id))
        #expect(lecture.title == "Old")
        #expect(lecture.parts == nil)
    }

    @Test func unreadableFoldersAreIgnored() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appending(path: "not-a-lecture")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: broken.appending(path: "lecture.json"))

        #expect(makeHistory().lectures.isEmpty)
    }

    @Test func openingASavedLectureRestoresTheSession() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let saved = try saveSample(in: history)

        let session = LectureSession(history: history)
        session.open(saved)
        #expect(session.savedID == saved.id)
        #expect(session.title == "Week 1")
        #expect(session.transcript.map(\.text) == ["Hello", "World"])
        #expect(session.frames.count == 2)
        #expect(session.distinctFrameCount == 3)
        #expect(session.versions.isEmpty, "No notes yet")
        #expect(session.notes(for: .detailed).isEmpty)
        #expect(session.hasSource)

        try history.saveNotes(version(.keyPoints, "# Short"), for: saved.id)
        try history.saveNotes(version(.complete, "# Long"), for: saved.id)
        session.open(try #require(history.lecture(saved.id)))
        #expect(session.phase == .done)
        #expect(session.notes(for: .keyPoints) == "# Short")
        #expect(session.notes(for: .complete) == "# Long")
        #expect(session.notes(for: .concise).isEmpty)
        #expect(session.hasVersion(.complete) && !session.hasVersion(.concise))

        session.reset()
        #expect(session.savedID == nil)
    }
}
