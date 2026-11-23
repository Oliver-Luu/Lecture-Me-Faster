import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Folders in the sidebar: making, renaming and deleting them, filing lectures, and what is saved.
@MainActor
struct FoldersTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "FoldersTests-\(UUID().uuidString)")

    private func makeHistory() -> LectureHistory { LectureHistory(root: root) }

    private func save(_ title: String, in history: LectureHistory) throws -> SavedLecture {
        try history.save(title: title, transcript: [TranscriptSegment(seconds: 0, text: "Hello")], frames: [], distinctFrameCount: 0)
    }

    @Test func foldersAndTheirLecturesSurviveARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let physics = try history.createFolder(named: "  Physics 1A ")
        let filed = try save("Week 1", in: history)
        let loose = try save("Seminar", in: history)
        try history.move([filed.id], toFolder: physics.id)

        let reopened = makeHistory()
        #expect(reopened.folders == [LectureFolder(id: physics.id, name: "Physics 1A")], "The name is trimmed")
        #expect(reopened.lectures(in: physics).map(\.id) == [filed.id])
        #expect(reopened.unfiledLectures.map(\.id) == [loose.id])
        #expect(reopened.lectures.count == 2, "A filed lecture is still in the history")
    }

    @Test func foldersAreListedByNameAndNamesAreKeptApart() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        try history.createFolder(named: "Math 32A")
        try history.createFolder(named: "CS 31")
        try history.createFolder(named: "math 32a")
        try history.createFolder(named: "   ")
        #expect(history.folders.map(\.name) == ["CS 31", "Math 32A", "math 32a 2", "New Folder"])
    }

    @Test func renamingAFolderKeepsItsLectures() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let folder = try history.createFolder(named: "Draft")
        let other = try history.createFolder(named: "Chemistry")
        let lecture = try save("Week 1", in: history)
        try history.move([lecture.id], toFolder: folder.id)

        try history.renameFolder(folder.id, to: "Biology")
        #expect(history.folders.map(\.name) == ["Biology", "Chemistry"])
        #expect(history.lectures(in: history.folders[0]).map(\.id) == [lecture.id])

        try history.renameFolder(folder.id, to: "   ")
        #expect(history.folders.map(\.name) == ["Biology", "Chemistry"], "An empty name is ignored")
        try history.renameFolder(other.id, to: "biology")
        #expect(history.folders.map(\.name) == ["Biology", "biology 2"], "A taken name gets a number")
        #expect(makeHistory().folders == history.folders)
    }

    @Test func deletingAFolderKeepsItsLectures() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let folder = try history.createFolder(named: "Physics")
        let kept = try save("Week 1", in: history)
        let binned = try save("Week 2", in: history)
        try history.move([kept.id, binned.id], toFolder: folder.id)
        try history.moveToRecentlyDeleted(binned.id)

        try history.deleteFolder(folder.id)
        #expect(history.folders.isEmpty)
        #expect(history.unfiledLectures.map(\.id) == [kept.id])
        #expect(history.lecture(binned.id)?.folderID == nil, "A deleted lecture doesn't keep pointing at a folder that is gone")
        let reopened = makeHistory()
        #expect(reopened.folders.isEmpty)
        #expect(reopened.lectures.map(\.id) == [kept.id])
    }

    @Test func movingLecturesBetweenFoldersAndOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let first = try history.createFolder(named: "A")
        let second = try history.createFolder(named: "B")
        let one = try save("One", in: history)
        let two = try save("Two", in: history)

        try history.move([one.id, two.id], toFolder: first.id)
        #expect(Set(history.lectures(in: first).map(\.id)) == [one.id, two.id])
        #expect(history.unfiledLectures.isEmpty)

        try history.move([two.id], toFolder: second.id)
        #expect(history.lectures(in: first).map(\.id) == [one.id])
        #expect(history.lectures(in: second).map(\.id) == [two.id])

        try history.move([one.id], toFolder: nil)
        #expect(history.unfiledLectures.map(\.id) == [one.id])

        try history.move([one.id], toFolder: UUID())
        #expect(history.lecture(one.id)?.folderID == nil, "A folder that doesn't exist is ignored")
    }

    @Test func aDeletedLectureComesBackToItsFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let folder = try history.createFolder(named: "Physics")
        let lecture = try save("Week 1", in: history)
        try history.move([lecture.id], toFolder: folder.id)

        try history.moveToRecentlyDeleted(lecture.id)
        #expect(history.lectures(in: folder).isEmpty)
        try history.restore(lecture.id)
        #expect(history.lectures(in: folder).map(\.id) == [lecture.id])
    }

    @Test func recordsFromBeforeFoldersStillLoad() throws {
        let old = #"{"id":"6F0C2B5E-5C0B-4E0E-9A39-0C2E1B7C9A11","title":"Old","createdAt":0,"transcript":[],"frameSeconds":[],"distinctFrameCount":0,"summary":"","notes":[]}"#
        let lecture = try JSONDecoder().decode(SavedLecture.self, from: Data(old.utf8))
        #expect(lecture.folderID == nil)
        #expect(lecture.title == "Old")
    }

    @Test func aLectureWhoseFolderIsMissingCountsAsUnfiled() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = makeHistory()
        let folder = try history.createFolder(named: "Physics")
        let lecture = try save("Week 1", in: history)
        try history.move([lecture.id], toFolder: folder.id)
        // The folder list is lost (deleted by hand, or not synced), but the lecture's record still names it.
        try FileManager.default.removeItem(at: root.appending(path: "folders.json"))

        let reopened = makeHistory()
        #expect(reopened.folders.isEmpty)
        #expect(reopened.unfiledLectures.map(\.id) == [lecture.id], "It is still reachable in the sidebar")
    }
}
