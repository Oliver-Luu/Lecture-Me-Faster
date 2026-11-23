import Foundation
import Testing
@testable import Lecture_Me_Faster

/// One lecture made from several files.
@MainActor
struct MultiFileLectureTests {
    private func url(_ name: String) -> URL { URL(filePath: "/tmp/\(name)") }

    // MARK: Choosing files

    @Test func dateNamedRecordingsAreSortedByDate() {
        // A semester of classes named by date, with the typos and spacing of real recordings.
        let names = [
            "november 2.WAV", "november 4.WAV", "novermber 9.WAV", "october 12.wav", "october 14_.wav",
            "october 21.WAV", "october 26.WAV", "october 28.WAV", "october 5.wav", "october 7.wav",
            "october19.WAV", "september 28.wav", "september 30_.wav",
        ]
        #expect(LectureSession.sortedByName(names.map(url)).map(LectureSession.displayName) == [
            "september 28", "september 30_", "october 5", "october 7", "october 12", "october 14_",
            "october19", "october 21", "october 26", "october 28", "november 2", "november 4", "novermber 9",
        ])
    }

    @Test func readsDatesFromFileNames() {
        #expect(LectureSession.nameDate("Lecture Oct 5") ?? (0, 0, 0) == (0, 10, 5))
        #expect(LectureSession.nameDate("sept 30 2025") ?? (0, 0, 0) == (2025, 9, 30))
        #expect(LectureSession.nameDate("class 2026-01-14") ?? (0, 0, 0) == (2026, 1, 14))
        #expect(LectureSession.nameDate("Lecture 5 - Part 2") == nil)
        #expect(LectureSession.nameDate("marketing 3") == nil, "Not a month, even though it starts with mar")
        #expect(LectureSession.nameDate("may 40") == nil)
    }

    @Test func namesWithoutDatesInEveryFileKeepNameOrder() {
        let files = ["Part 2.m4a", "October 1 intro.m4a", "Part 1.m4a"].map(url)
        #expect(LectureSession.sortedByName(files).map(LectureSession.displayName) == ["October 1 intro", "Part 1", "Part 2"])
    }

    @Test func filesAddedLaterJoinTheFilesAlreadyChosen() {
        // A drop delivered one file at a time, or a second drop or Add Files…, must keep every file.
        let files = NewLectureFiles([url("Lecture 5 - Part 3.m4a")])
        files.add([url("Lecture 5 - Part 1.m4a")])
        files.add([url("Lecture 5 - Part 2.m4a"), url("Slides.pdf")])
        #expect(files.recordings.map(LectureSession.displayName) == ["Lecture 5 - Part 1", "Lecture 5 - Part 2", "Lecture 5 - Part 3"])
        #expect(files.materials.map(\.lastPathComponent) == ["Slides.pdf"])
        #expect(files.title == "Lecture 5")
    }

    @Test func addingTheSameFileTwiceKeepsOneCopy() {
        let files = NewLectureFiles([url("A.m4a"), url("A.m4a")])
        files.add([url("A.m4a"), url("B.m4a")])
        #expect(files.recordings.map(\.lastPathComponent) == ["A.m4a", "B.m4a"])
    }

    @Test func partsAddedAfterReorderingGoAtTheEnd() {
        let files = NewLectureFiles([url("Part 1.m4a"), url("Part 2.m4a")])
        files.swapRecordings(0, 1)
        files.add([url("Part 0.m4a")])
        #expect(files.recordings.map(LectureSession.displayName) == ["Part 2", "Part 1", "Part 0"])
    }

    @Test func aTypedTitleIsKeptWhenFilesAreAddedOrRemoved() {
        let files = NewLectureFiles([url("Week 1 - Part 1.m4a")])
        files.title = "Biology"
        files.add([url("Week 1 - Part 2.m4a")])
        files.remove(url("Week 1 - Part 1.m4a"))
        #expect(files.title == "Biology")
        #expect(files.recordings.map(LectureSession.displayName) == ["Week 1 - Part 2"])
    }

    @Test func recognizesVideoAndAudioFilesOnly() {
        for name in ["a.mov", "a.mp4", "a.m4v", "a.m4a", "a.mp3", "a.wav", "A.MOV"] {
            #expect(LectureSession.isLectureFile(url(name)), "\(name) should be accepted")
        }
        for name in ["a.pdf", "a.txt", "a.jpg", "folder"] {
            #expect(!LectureSession.isLectureFile(url(name)), "\(name) should be rejected")
        }
    }

    @Test func partsAreSortedLikeFinder() {
        let files = ["Part 10.mp4", "Part 2.mp4", "Part 1.mp4"].map(url)
        #expect(LectureSession.sortedByName(files).map(LectureSession.displayName) == ["Part 1", "Part 2", "Part 10"])
    }

    @Test func suggestedTitleIsTheSharedNameWithoutThePartNumber() {
        func title(_ names: String...) -> String { LectureSession.suggestedTitle(for: names.map(url)) }
        #expect(title("Lecture 5 - Part 1.mp4", "Lecture 5 - Part 2.mp4") == "Lecture 5")
        #expect(title("CS31 Week3 pt1.mov", "CS31 Week3 pt2.mov") == "CS31 Week3")
        #expect(title("Thermo_Lec7_a.m4a", "Thermo_Lec7_b.m4a") == "Thermo_Lec7")
        #expect(title("intro.mp4", "outro.mp4") == "intro", "Nothing meaningful in common: use the first name")
        #expect(title("Only One.mp4") == "Only One")
        #expect(title() == "")
    }

    // MARK: Processing several parts at once

    @Test func partsProcessedAtOnceComeBackInPlayingOrder() async throws {
        // Later parts finish first; the results must still be in the parts' order.
        let running = Gauge(), peak = Gauge()
        let results = try await LectureSession.inOrder(Array(0..<9), concurrency: 3) { index, item in
            let now = running.add(1)
            peak.raise(to: now)
            try await Task.sleep(for: .milliseconds(10 * (9 - item)))
            running.add(-1)
            return "part \(index)"
        }
        #expect(results == (0..<9).map { "part \($0)" })
        #expect(peak.value <= 3, "Never more than the limit at once")
        #expect(peak.value >= 2, "Really in parallel")
    }

    @Test func aFailingPartStopsTheLecture() async {
        struct Broken: Error {}
        await #expect(throws: Broken.self) {
            _ = try await LectureSession.inOrder(Array(0..<6), concurrency: 2) { _, item in
                if item == 3 { throw Broken() }
                return item
            }
        }
    }

    @Test func audioOnlyLecturesRunMorePartsAtOnce() {
        #expect(LectureSession.partConcurrency(["a.wav", "b.m4a", "c.mp3"].map(url)) == 4)
        #expect(LectureSession.partConcurrency(["a.wav", "b.mp4"].map(url)) == 2, "Any video: fewer at once")
        #expect(LectureSession.average([0, 0.5, 1, 2]) == 0.625, "Values over 1 count as 1")
        #expect(LectureSession.average([]) == 0)
    }

    // MARK: Joining parts

    @Test func partsAreJoinedIntoOneTimeline() {
        let first = LectureSession.PartResult(
            name: "Part 1", duration: 600,
            frames: [LectureFrame(seconds: 0, jpeg: Data([1])), LectureFrame(seconds: 300, jpeg: Data([2]))],
            distinctFrameCount: 2,
            transcript: [TranscriptSegment(seconds: 0, text: "Welcome"), TranscriptSegment(seconds: 590, text: "Break")],
            hasAudio: true
        )
        let second = LectureSession.PartResult(
            name: "Part 2", duration: 900,
            frames: [LectureFrame(seconds: 10, jpeg: Data([3]))],
            distinctFrameCount: 1,
            transcript: [TranscriptSegment(seconds: 5, text: "We're back")],
            hasAudio: true
        )

        let combined = LectureSession.combine([first, second])
        #expect(combined.parts == [LecturePart(name: "Part 1", startSeconds: 0), LecturePart(name: "Part 2", startSeconds: 600)])
        #expect(combined.frames.map(\.seconds) == [0, 300, 610])
        #expect(combined.frames.map(\.jpeg) == [Data([1]), Data([2]), Data([3])])
        #expect(combined.transcript.map(\.seconds) == [0, 590, 605])
        #expect(combined.transcript.map(\.text) == ["Welcome", "Break", "We're back"])
        #expect(combined.distinctFrameCount == 3)
    }

    @Test func aSilentFileAddsItsSlides() async throws {
        let video = try await TestMedia.makeSlideVideo(slides: 2, secondsPerSlide: 4)
        defer { try? FileManager.default.removeItem(at: video) }

        let part = try await LectureSession.process(video, frameOptions: .init()) { _, _ in }
        #expect(!part.hasAudio)
        #expect(part.transcript.isEmpty)
        #expect(part.frames.count == 2)
        #expect(abs(part.duration - 8) < 0.5)
    }

    /// Before 2026-11-16 a lecture with no audio track at all failed ("no audio track"), even though its
    /// slides were found. A screen recording without sound now gets notes from its slides.
    @Test func aLectureWithSlidesButNoSoundIsWrittenFromItsSlides() async throws {
        let host = "silent.lecture-me-faster.test"
        let log = MockModelServer.start(host: host)
        defer { MockModelServer.stop(host: host) }
        let videos = [
            try await TestMedia.makeSlideVideo(slides: 2, secondsPerSlide: 4),
            try await TestMedia.makeSlideVideo(slides: 1, secondsPerSlide: 2),
        ]
        defer { videos.forEach { try? FileManager.default.removeItem(at: $0) } }
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(host)/v1"
        stored.openAIModel = "m"
        let session = LectureSession()

        session.start(videos, title: "Week 3", settings: AppSettings(unsaved: stored))
        #expect(session.title == "Week 3")
        #expect(session.partCount == 2)
        #expect(session.phase == .processing)

        for _ in 0..<400 where session.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.phase == .done)
        #expect(session.transcript.isEmpty)
        #expect(session.frames.count == 3)
        #expect(session.notes(for: .detailed) == "Reply \(log.requests.count)")
        #expect(log.requests.last?.contains("No speech was recognized in the recording") == true)
    }

    @Test func aRecordingWithNoSoundAndNoSlidesStillFails() async throws {
        // One flat grey picture: no speech, and nothing on screen to keep.
        let blank = try await TestMedia.makeSlideVideo(slides: 1, secondsPerSlide: 3, blank: true)
        defer { try? FileManager.default.removeItem(at: blank) }
        let session = LectureSession()
        session.start([blank], title: "Nothing", settings: AppSettings(unsaved: AppSettings.Stored()))
        for _ in 0..<400 where session.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.phase == .failed(AudioToTranscription.Failure.noAudio.localizedDescription))
        #expect(session.savedID == nil)
    }
}

/// A number several tasks can change safely, for counting how many run at once.
private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int { lock.withLock { current } }
    @discardableResult func add(_ amount: Int) -> Int { lock.withLock { current += amount; return current } }
    func raise(to candidate: Int) { lock.withLock { current = max(current, candidate) } }
}
