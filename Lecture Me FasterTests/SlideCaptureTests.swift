import CoreGraphics
import AVFoundation
import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Slide capture must never lose a slide. These run real generated videos through `VideoToFrames` and
/// check every slide is there, by reading its number back with text recognition.
@Suite(.serialized)
struct SlideCaptureTests {
    typealias S = TestMedia.Slide

    /// The slide numbers ("Slide 7 heading") found in the kept frames, in order.
    private func slideNumbers(_ output: VideoToFrames.Output) -> [Int] {
        output.analyses.compactMap { analysis in
            let words = FileToAI.words(in: analysis.text)
            guard let index = words.firstIndex(of: "Slide"), index + 1 < words.count else { return nil }
            return Int(words[index + 1])
        }
    }

    private func capture(_ slides: [S], _ realism: TestMedia.Realism = .init()) async throws -> VideoToFrames.Output {
        let video = try await TestMedia.makeDeckVideo(slides, realism: realism)
        defer { try? FileManager.default.removeItem(at: video) }
        return try await VideoToFrames.extract(from: video) { _ in }
    }

    private func deck(_ count: Int, seconds: Double = 6) -> [S] {
        (1...count).map { S(title: "Slide \($0) heading", bullets: ["Point \($0)a", "Point \($0)b"], seconds: seconds) }
    }

    // MARK: Whole videos

    /// Same template on every slide, only the text changes. The old 48×48 comparison kept 1 of these.
    @Test func keepsEverySlideOfASameTemplateDeck() async throws {
        let output = try await capture(deck(12))
        #expect(slideNumbers(output) == Array(1...12))
        #expect(output.frames.map(\.seconds) == stride(from: 0.0, to: 72, by: 6).map { $0 })
    }

    @Test func keepsASlideWhereOnlyOneFormulaChanges() async throws {
        let output = try await capture([
            S(title: "Complexity", bullets: ["Merge sort: O(n log n)", "Space: O(n)"], seconds: 8),
            S(title: "Complexity", bullets: ["Merge sort: O(n log n)", "Space: O(1)"], seconds: 8),
        ])
        #expect(output.frames.count == 2)
        #expect(output.analyses.last?.text.contains("O(1)") == true)
    }

    @Test func keepsASlideShownForThreeSeconds() async throws {
        let output = try await capture([
            S(title: "Slide 1 heading", seconds: 8), S(title: "Slide 2 heading", bullets: ["Exam on Dec 4"], seconds: 3),
            S(title: "Slide 3 heading", seconds: 8),
        ])
        #expect(slideNumbers(output) == [1, 2, 3])
    }

    @Test func keepsTheCompleteVersionOfABulletBuild() async throws {
        let output = try await capture([
            S(title: "Merge sort", bullets: ["Split in half"], seconds: 6),
            S(title: "Merge sort", bullets: ["Split in half", "Sort each half"], seconds: 6),
            S(title: "Merge sort", bullets: ["Split in half", "Sort each half", "Merge in linear time"], seconds: 6),
            S(title: "Quicksort", bullets: ["Pick a pivot"], seconds: 6),
        ])
        #expect(output.frames.count == 2)
        #expect(output.analyses.first?.text.contains("Merge in linear time") == true, "The last step, with every bullet")
        #expect(output.frames.first?.seconds == 0, "Timed from when the build began")
    }

    @Test func keepsEverySlideThroughFadesNoiseAndAWebcam() async throws {
        let output = try await capture(deck(12), .init(noise: 8, webcam: true, fadeFrames: 2))
        #expect(Set(slideNumbers(output)) == Set(1...12), "Nothing missing")
        #expect(output.frames.count <= 14, "Few duplicates: \(slideNumbers(output))")
    }

    @Test func keepsEverySlideThroughHeavyNoise() async throws {
        let output = try await capture(deck(10), .init(noise: 12))
        #expect(slideNumbers(output) == Array(1...10))
    }

    @Test func goingBackToASlideDoesNotRepeatIt() async throws {
        let slides = [S(title: "Slide 1 heading", seconds: 6), S(title: "Slide 2 heading", seconds: 6), S(title: "Slide 1 heading", seconds: 6)]
        #expect(slideNumbers(try await capture(slides)) == [1, 2])
    }

    /// A talking-head video: the picture changes all over every second and the captions change every 2
    /// seconds, but there are only three shots. One frame per shot, not one per second. (Modelled on a real
    /// 60-second team-intro video that gave 49 frames before live footage was handled, and 4 after.)
    @Test func liveFootageGivesOneFramePerShot() async throws {
        let video = try await TestMedia.makeCameraVideo([
            .init(name: "ALEX", brightness: 0.25, seconds: 15),
            .init(name: "BLAIR", brightness: 0.6, seconds: 15),
            .init(name: "CASEY", brightness: 0.85, seconds: 15),
        ])
        defer { try? FileManager.default.removeItem(at: video) }
        let output = try await VideoToFrames.extract(from: video) { _ in }
        let names = output.analyses.map { analysis in ["ALEX", "BLAIR", "CASEY"].first { analysis.text.contains($0) } ?? "?" }
        #expect(names == ["ALEX", "BLAIR", "CASEY"], "\(output.frames.map(\.seconds)) \(names)")
        // Each shot is found within the one-second sampling step of its cut.
        #expect(zip(output.frames.map(\.seconds), [0.0, 15, 30]).allSatisfy { abs($0 - $1) <= 1 })
    }

    @Test func slidesBetweenCameraShotsAreStillKept() async throws {
        // Camera, then a slide deck, then camera again: the slides keep the strict rule.
        let camera = try await TestMedia.makeCameraVideo([.init(name: "ALEX", brightness: 0.3, seconds: 15)])
        defer { try? FileManager.default.removeItem(at: camera) }
        let slides = try await capture(deck(4))
        let cameraFrames = try await VideoToFrames.extract(from: camera) { _ in }
        #expect(cameraFrames.frames.count == 1)
        #expect(slideNumbers(slides) == [1, 2, 3, 4])
    }

    @Test func liveFootageIsRecognisedOnlyWhenMostSecondsChangeWidely() {
        let camera = [0] + [Int](repeating: 40, count: 20)
        #expect(VideoToFrames.isLive(changedBlockCount: camera).dropFirst(2).dropLast(2).allSatisfy { $0 })
        // Slides with fades: a few busy seconds every 6 seconds.
        let deck = [0] + (1...30).map { $0 % 6 < 2 ? 40 : 0 }
        #expect(!VideoToFrames.isLive(changedBlockCount: deck).contains(true))
        #expect(VideoToFrames.isLive(changedBlockCount: []) == [])
        #expect(VideoToFrames.isLive(changedBlockCount: [0]) == [false])
    }

    @Test func blankFramesAndHistograms() {
        typealias Sig = VideoToFrames.Signature
        let count = Sig.width * Sig.height
        #expect(Sig.isBlank([UInt8](repeating: 3, count: count)))
        let text = (0..<count).map { $0 % 50 < 5 ? UInt8(0) : UInt8(240) }
        #expect(!Sig.isBlank(text))
        let dark = Sig.histogram([UInt8](repeating: 10, count: count)), light = Sig.histogram([UInt8](repeating: 200, count: count))
        #expect(Sig.distance(dark, dark) == 0)
        #expect(Sig.distance(dark, light) == 1)
    }

    // MARK: Pieces

    @Test func buildStepsNeedAllWordsOnTheNextSlide() {
        #expect(VideoToFrames.isEarlierStep("Merge sort\n• Split in half", of: "Merge sort\n• Split in half\n• Sort each half"))
        #expect(!VideoToFrames.isEarlierStep("Merge sort\n• Split in half", of: "Merge sort\n• Split in two"), "A word is gone")
        #expect(!VideoToFrames.isEarlierStep("Intro", of: "Intro\nMore words here"), "Too short to judge")
        #expect(!VideoToFrames.isEarlierStep("Same words here", of: "Same words here"), "Not a build: nothing added")

        // A code editor being typed into: one word misread between frames still counts as a build.
        let code = "const int MAXSIZE = 5; double da[MAXSIZE]; double is a number double& a reference to a double"
        #expect(VideoToFrames.isEarlierStep(code, of: code.replacingOccurrences(of: "reference", with: "refcrence") + " for (int k = 0; k < MAXSIZE; k++)"))
        // But a slide that lost much of its text is a different slide.
        #expect(!VideoToFrames.isEarlierStep(code, of: "const int MAXSIZE = 5; something else entirely new here"))
    }

    @Test func aBlockAverageCheckNeverCallsARepeatAChange() {
        // Where the cheap check says "changed", the full pixel count must agree.
        let motion = VideoToFrames.Motion(
            isDynamic: Array(repeating: false, count: VideoToFrames.Signature.blockCount),
            isBusy: Array(repeating: false, count: VideoToFrames.Signature.blockCount), isCamera: false
        )
        let count = VideoToFrames.Signature.width * VideoToFrames.Signature.height
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // Small noise everywhere, sometimes a few strong changes in one place.
            var b = a.map { UInt8(clamping: Int($0) + Int.random(in: -20...20, using: &generator)) }
            if Bool.random(using: &generator) {
                for index in (0..<Int.random(in: 1...800, using: &generator)) { b[index] = 255 &- b[index] }
            }
            let meansA = VideoToFrames.Signature.blockMeans(a), meansB = VideoToFrames.Signature.blockMeans(b)
            let full = motion.isChange(VideoToFrames.Signature.changedPixels(a, b))
            if motion.isSurelyChange(blockMeans: meansA, meansB) { #expect(full) }
            #expect(motion.isChange(a, b, blockMeans: meansA, meansB) == full, "The early-stopping check must agree exactly")
        }
        let blank = [UInt8](repeating: 0, count: count), white = [UInt8](repeating: 255, count: count)
        #expect(motion.isSurelyChange(blockMeans: VideoToFrames.Signature.blockMeans(blank), VideoToFrames.Signature.blockMeans(white)))
        #expect(!motion.isSurelyChange(blockMeans: VideoToFrames.Signature.blockMeans(blank), VideoToFrames.Signature.blockMeans(blank)))
    }

    @Test func fadeFramesAreBlendsOfTheirNeighbours() {
        let count = VideoToFrames.Signature.width * VideoToFrames.Signature.height
        let black = [UInt8](repeating: 0, count: count), white = [UInt8](repeating: 200, count: count)
        let grey = [UInt8](repeating: 100, count: count)
        let noMotion = [Bool](repeating: false, count: VideoToFrames.Signature.blockCount)
        #expect(VideoToFrames.isBetween(black, grey, white, ignoring: noMotion))
        #expect(!VideoToFrames.isBetween(black, black, white, ignoring: noMotion), "Equal to one end: a real slide")
        #expect(!VideoToFrames.isBetween(black, white, black, ignoring: noMotion), "Far from both: a real slide")
        #expect(!VideoToFrames.isBetween(grey, grey, grey, ignoring: noMotion), "Nothing changed: not a fade")
    }

    @Test func imagesGoToTheSlidesWithTheMostPictures() {
        #expect(VideoToFrames.imageChoice(visualScores: [0.1, 0.5, 0.2, 0.4], limit: 2) == [false, true, false, true])
        #expect(VideoToFrames.imageChoice(visualScores: [0.3, 0.3, 0.3], limit: 2) == [true, true, false], "Ties: earlier first")
        #expect(VideoToFrames.imageChoice(visualScores: [0.1, 0.2], limit: 5) == [true, true])
        #expect(VideoToFrames.imageChoice(visualScores: [0.1, 0.2], limit: 0) == [false, false])
    }

    @Test func decodingBlocksAtOnceGivesTheSameTimelineAsOneAtATime() async throws {
        // Over three minutes, so the scan has several one-minute blocks to decode at once.
        let video = try await TestMedia.makeDeckVideo((1...13).map {
            S(title: "Topic \($0)", bullets: ["Point \($0)a", "Point \($0)b"], seconds: 15)
        })
        defer { try? FileManager.default.removeItem(at: video) }
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let one = try await VideoToFrames.scanTimeline(asset, duration: duration, interval: 1, pieces: 1) { _ in }
        let four = try await VideoToFrames.scanTimeline(asset, duration: duration, interval: 1, pieces: 4) { _ in }
        #expect(one.seconds.count >= 190)
        #expect(four.seconds == one.seconds)
        #expect(four.actualSeconds == one.actualSeconds)
        #expect(four.isSlideStart == one.isSlideStart)
        #expect(four.changedBlockCount == one.changedBlockCount)
        #expect(four.blockChanges == one.blockChanges)
        #expect(VideoToFrames.scenes(in: four) == VideoToFrames.scenes(in: one))
        #expect(VideoToFrames.scenes(in: one).count == 13)
    }

    @Test func theSlideCapGrowsWithTheVideo() {
        #expect(VideoToFrames.storedFrameCap(duration: 60) == 1000, "Short videos keep the 1,000 floor")
        #expect(VideoToFrames.storedFrameCap(duration: 89 * 60) == 1068)
        #expect(VideoToFrames.storedFrameCap(duration: 12 * 3600) == 8640, "A 12-hour lecture keeps one slide per 5 s")
        #expect(VideoToFrames.storedFrameCap(duration: .nan) == 1000)
        #expect(VideoToFrames.storedFrameCap(duration: 0) == 1000)
    }

    @Test func joiningRecordingsThinsNothingByDefault() {
        // Thirteen recordings with 900 slides each: all 11,700 are kept, since each was capped on its own.
        let part = LectureSession.PartResult(
            name: "Class", duration: 4500,
            frames: (0..<900).map { LectureFrame(seconds: Double($0) * 5, jpeg: Data([1])) },
            distinctFrameCount: 900, transcript: [], hasAudio: true
        )
        #expect(LectureSession.combine(Array(repeating: part, count: 13)).frames.count == 11_700)
    }

    @Test func visualScoreSeesPicturesButNotTextOrTheTemplate() async throws {
        // Three text slides and one chart, all with the deck's blue header bar.
        var images = (1...3).map { TestMedia.slideImage(S(title: "Slide \($0)", bullets: ["Line one", "Line two", "Line three"], seconds: 1)) }
        let context = try #require(CGContext(
            data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(TestMedia.slideImage(S(title: "Results", seconds: 1)), in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        for bar in 0..<4 { context.fill(CGRect(x: 200 + bar * 220, y: 100, width: 150, height: 120 + bar * 100)) }
        images.append(try #require(context.makeImage()))

        var boxes: [[CGRect]] = []
        for image in images { boxes.append(try await DocumentToText.recognizeLines(in: image, languageCorrection: false).map(\.box)) }
        let scores = VideoToFrames.visualScores(thumbnails: images.map(VideoToFrames.Thumbnail.pixels), textBoxes: boxes)
        #expect(scores[0..<3].allSatisfy { $0 < 0.03 }, "Text slides: \(scores)")
        #expect(scores[3] > 0.1, "Chart: \(scores)")
        #expect(VideoToFrames.imageChoice(visualScores: scores, limit: 1) == [false, false, false, true])
    }
}
