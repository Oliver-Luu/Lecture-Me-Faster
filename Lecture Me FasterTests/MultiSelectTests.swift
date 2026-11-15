import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Acting on several selected lectures or transcript lines at once.
@MainActor
struct MultiSelectTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "MultiSelectTests-\(UUID().uuidString)")

    private func historyWith(_ titles: [String]) throws -> (LectureHistory, [UUID]) {
        let history = LectureHistory(root: root)
        let ids = try titles.map {
            try history.save(title: $0, transcript: [], frames: [], distinctFrameCount: 0).id
        }
        return (history, ids)
    }

    @Test func severalLecturesMoveToRecentlyDeletedAndBackTogether() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (history, ids) = try historyWith(["A", "B", "C", "D"])

        try history.moveToRecentlyDeleted([ids[0], ids[2], ids[3]])
        #expect(history.lectures.map(\.title) == ["B"])
        #expect(Set(history.recentlyDeleted.map(\.title)) == ["A", "C", "D"])
        #expect(LectureHistory(root: root).recentlyDeleted.count == 3, "Saved to disk")

        try history.restore([ids[0], ids[3]])
        #expect(Set(history.lectures.map(\.title)) == ["A", "B", "D"])
        #expect(history.recentlyDeleted.map(\.title) == ["C"])
    }

    @Test func severalLecturesAreDeletedForGoodTogether() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (history, ids) = try historyWith(["A", "B", "C"])
        try history.moveToRecentlyDeleted(ids)

        try history.deletePermanently([ids[0], ids[1]])
        #expect(history.recentlyDeleted.map(\.title) == ["C"])
        #expect(LectureHistory(root: root).recentlyDeleted.map(\.title) == ["C"])
        for id in ids.prefix(2) {
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: id.uuidString).path(percentEncoded: false)))
        }
    }

    @Test func batchDeletingSkipsLecturesStillInTheHistory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (history, ids) = try historyWith(["Kept", "Trashed"])
        try history.moveToRecentlyDeleted([ids[1]])

        try history.deletePermanently(ids)  // includes a lecture that isn't in Recently Deleted
        #expect(history.lectures.map(\.title) == ["Kept"], "Only Recently Deleted lectures can be deleted for good")
        #expect(history.recentlyDeleted.isEmpty)
    }

    @Test func selectedSidebarLecturesKeepHistoryOrderAndIgnoreOtherRows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (history, ids) = try historyWith(["Oldest", "Middle", "Newest"])
        let selection: Set<ContentView.SidebarItem> = [.lecture(ids[0]), .current, .lecture(ids[2]), .recentlyDeleted]

        // The history lists newest first.
        #expect(HistorySidebar.lectureIDs(in: selection, order: history.lectures) == [ids[2], ids[0]])
        #expect(HistorySidebar.lectureIDs(in: [.current, .recentlyDeleted], order: history.lectures).isEmpty)
    }

    @Test func copiedTranscriptLinesAreInLectureOrderWithTimestamps() {
        let transcript = [
            TranscriptSegment(seconds: 0, text: "Welcome."),
            TranscriptSegment(seconds: 65, text: "First law."),
            TranscriptSegment(seconds: 3725, text: "Second law."),
        ]
        let selected: Set = [transcript[2].id, transcript[0].id]
        #expect(LectureResultView.copyText(for: selected, in: transcript) == "[0:00] Welcome.\n[1:02:05] Second law.")
        #expect(LectureResultView.copyText(for: [], in: transcript) == "")
    }
}
