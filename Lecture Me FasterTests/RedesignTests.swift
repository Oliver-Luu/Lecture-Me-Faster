import Foundation
import Testing
@testable import Lecture_Me_Faster

/// The parts of the redesigned screens that decide what is shown: the progress steps, the sidebar's date
/// headings, and the line saying where a lecture is sent.
@MainActor
struct RedesignTests {
    private func stages(
        readingMaterials: Bool = false, material: Int = 0, materials: Int = 0, recordings: Int = 1,
        frames: Double = 0, transcript: Double = 0
    ) -> [ProcessingView.Stage] {
        ProcessingView.stages(
            isReadingMaterials: readingMaterials, currentMaterial: material, materialCount: materials,
            materialName: "Handout.pdf", recordingCount: recordings, frameProgress: frames, transcriptProgress: transcript
        )
    }

    @Test func aRecordingAloneShowsThreeSteps() {
        let steps = stages(frames: 0.5, transcript: 0.25)
        #expect(steps.map(\.title) == ["Find the slides", "Transcribe the speech", "Write the notes"])
        #expect(steps.map(\.state) == [.running(0.5), .running(0.25), .waiting])
    }

    @Test func materialsAreReadFirstWhileTheRecordingWaits() {
        let steps = stages(readingMaterials: true, material: 1, materials: 4)
        #expect(steps.map(\.title) == ["Read the materials", "Find the slides", "Transcribe the speech", "Write the notes"])
        #expect(steps[0].state == .running(0.25))
        #expect(steps[0].detail == "File 2 of 4: Handout.pdf")
        #expect(steps[1].state == .waiting && steps[2].state == .waiting)
    }

    @Test func finishedStepsAreMarkedDone() {
        let steps = stages(materials: 1, frames: 1, transcript: 0.4)
        #expect(steps[0].state == .done)
        #expect(steps[0].detail == "1 file read")
        #expect(steps[1].state == .done, "An audio-only recording reports its slides as finished straight away")
        #expect(steps[2].state == .running(0.4))
        #expect(stages(materials: 3)[0].detail == "3 files read")
    }

    @Test func materialsAloneSkipTheRecordingSteps() {
        let steps = stages(readingMaterials: true, materials: 2, recordings: 0)
        #expect(steps.map(\.title) == ["Read the materials", "Write the notes"])
    }

    @Test func progressNeverGoesBelowZero() {
        #expect(stages(frames: -0.2)[0].state == .running(0))
    }

    private func lecture(_ title: String, daysAgo: Double, from now: Date) -> SavedLecture {
        SavedLecture(
            id: UUID(), title: title, createdAt: now.addingTimeInterval(-daysAgo * 86_400), transcript: [],
            frameSeconds: [], distinctFrameCount: 0, summary: "", deletedAt: nil
        )
    }

    @Test func sidebarGroupsLecturesByAge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // Noon, so "half a day ago" is still today and "one day ago" is yesterday.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)))
        let lectures = [
            lecture("This morning", daysAgo: 0.25, from: now),
            lecture("Yesterday", daysAgo: 1, from: now),
            lecture("A week ago", daysAgo: 7, from: now),
            lecture("Last month", daysAgo: 30, from: now),
        ]

        let groups = HistorySidebar.groups(lectures, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Previous 7 Days", "Earlier"])
        #expect(groups.map { $0.lectures.map(\.title) } == [["This morning"], ["Yesterday", "A week ago"], ["Last month"]])
        #expect(groups.flatMap(\.lectures) == lectures, "Every lecture appears once, in the history's order")
    }

    @Test func sidebarLeavesOutEmptyHeadings() {
        let now = Date()
        #expect(HistorySidebar.groups([], now: now).isEmpty)
        #expect(HistorySidebar.groups([lecture("Old", daysAgo: 90, from: now)], now: now).map(\.title) == ["Earlier"])
    }

    @Test func logoBarsFillTheMarkAndFallInTwoGroups() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 160)
        let bars = LogoMark.bars(in: rect)
        #expect(bars.count == 6)
        #expect(bars.allSatisfy { rect.insetBy(dx: -0.001, dy: -0.001).contains($0) }, "No bar leaves the mark")
        #expect(abs(bars[0].minX - rect.minX) < 0.001 && abs(bars[5].maxX - rect.maxX) < 0.001, "The bars span its width")
        #expect(bars[0].height == rect.height)
        #expect(bars.map(\.height) == Array(bars.prefix(3).map(\.height)) + Array(bars.prefix(3).map(\.height)), "Two alike groups")
        #expect(bars[0].height > bars[1].height && bars[1].height > bars[2].height, "Each group falls, like a fast-forward sign")
        #expect(bars.allSatisfy { abs($0.midY - rect.midY) < 0.001 })
    }

    @Test func shortNotesStayInOnePieceSoASelectionCanCrossThem() {
        let blocks = MarkdownView.blocks(from: "# Title\n\nA paragraph.\n\n## Part\n\n- one\n- two")
        #expect(MarkdownView.sections(of: blocks) == [blocks])
    }

    @Test func longNotesAreSplitAtHeadingsWithoutLosingAnything() {
        let part = "## Part\n\n" + String(repeating: "A sentence of the lecture. ", count: 40) + "\n\n- a point\n- another\n\n"
        let blocks = MarkdownView.blocks(from: String(repeating: part, count: 30))
        let sections = MarkdownView.sections(of: blocks, limit: 3_000)
        #expect(sections.count > 5)
        #expect(sections.flatMap { $0 } == blocks, "Every block is kept, in order")
        #expect(sections.allSatisfy { if case .heading = $0[0] { true } else { false } }, "Each piece starts at a heading")
    }

    @Test func longNotesWithNoHeadingsAreStillSplitButNeverInsideAList() {
        let text = String(repeating: String(repeating: "Plain words. ", count: 60) + "\n\n- first\n- second\n\n", count: 40)
        let blocks = MarkdownView.blocks(from: text)
        let sections = MarkdownView.sections(of: blocks, limit: 1_000)
        #expect(sections.count > 1)
        #expect(sections.flatMap { $0 } == blocks)
        #expect(sections.allSatisfy { if case .listItem = $0[0] { false } else { true } }, "A list is never cut in two")
    }

    @Test func parsedNotesAreTheSameWhenShownAgain() {
        let notes = "# Title\n\nA paragraph with **bold**."
        #expect(MarkdownView.sections(for: notes) == MarkdownView.sections(for: notes))
        #expect(MarkdownView.sections(for: notes).count == 1)
    }

    @Test func importScreenSaysWhereTheLectureGoes() {
        let onDevice = ImportView.privacyLine(provider: .apple, providerName: "Apple Intelligence")
        #expect(onDevice.contains("Nothing leaves this device"))
        let sent = ImportView.privacyLine(provider: .claude, providerName: "Claude")
        #expect(sent.contains("go to Claude"))
        #expect(!sent.contains("Nothing leaves"))
    }
}
