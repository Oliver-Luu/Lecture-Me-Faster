import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Lecture_Me_Faster

/// Frames that only add to the previous one (a build, typing, a pen drawing) keep only the fullest
/// (`VideoToFrames.mergingAdditions`); anything removed keeps both.
struct AdditionMergeTests {
    typealias Sig = VideoToFrames.Signature
    private let width = Sig.width, height = Sig.height

    private func blank(_ value: UInt8 = 235) -> [UInt8] { [UInt8](repeating: value, count: Sig.width * Sig.height) }

    /// Dark strokes ("ink") in a rectangle.
    private func drawing(_ pixels: [UInt8], x: Range<Int>, y: Range<Int>, value: UInt8 = 30) -> [UInt8] {
        var pixels = pixels
        for row in y { for column in x where column % 3 != 0 { pixels[row * width + column] = value } }
        return pixels
    }

    private var still: VideoToFrames.Motion {
        .init(isDynamic: Array(repeating: false, count: Sig.blockCount), isBusy: Array(repeating: false, count: Sig.blockCount), isCamera: false)
    }

    @Test func addingInkIsABuild() {
        let first = drawing(blank(), x: 20..<120, y: 20..<30)
        let second = drawing(first, x: 20..<160, y: 40..<50)  // a new line below
        #expect(VideoToFrames.isAddition(first, to: second, ignoring: still))
        #expect(!VideoToFrames.isAddition(second, to: first, ignoring: still), "Going back loses the new line")
        #expect(VideoToFrames.isAddition(first, to: first, ignoring: still), "The same picture")
    }

    @Test func removingInkIsNotABuild() {
        let full = drawing(drawing(blank(), x: 20..<120, y: 20..<30), x: 20..<160, y: 40..<50)
        var erased = full
        for row in 40..<50 { for column in 20..<160 { erased[row * width + column] = 235 } }  // a line wiped off
        #expect(!VideoToFrames.isAddition(full, to: erased, ignoring: still))
        // A scroll: the same lines moved up by 10 rows.
        let scrolled = drawing(drawing(blank(), x: 20..<120, y: 10..<20), x: 20..<160, y: 30..<40)
        #expect(!VideoToFrames.isAddition(full, to: scrolled, ignoring: still))
    }

    @Test func aPersonInFrontOfTheBoardKeepsBothFrames() {
        let board = drawing(blank(), x: 100..<300, y: 40..<140)
        // Someone stands in front, hiding most of the writing (and adding their own "ink").
        let blocked = drawing(board, x: 120..<260, y: 30..<180, value: 160)
        var hidden = blocked
        for row in 30..<180 { for column in 120..<260 { hidden[row * width + column] = 160 } }
        #expect(!VideoToFrames.isAddition(board, to: hidden, ignoring: still))
        // Even where people walk a lot (busy, not constant), the hidden writing still counts.
        var busy = still
        busy.isBusy = Array(repeating: true, count: Sig.blockCount)
        #expect(!VideoToFrames.isAddition(board, to: hidden, ignoring: busy))
    }

    @Test func aWebcamInsetIsIgnoredAndANewSlideIsNot() {
        let slide = drawing(blank(), x: 20..<120, y: 20..<30)
        var withCamera = drawing(slide, x: 20..<200, y: 60..<70)
        // The bottom-right corner (a webcam) is completely different in the later frame.
        for row in 140..<180 { for column in 260..<320 { withCamera[row * width + column] = UInt8((row * 7 + column * 13) % 256) } }
        var camera = still
        for row in 7..<9 { for column in 13..<16 { camera.isDynamic[row * Sig.columns + column] = true } }
        var slideWithCamera = slide
        for row in 140..<180 { for column in 260..<320 { slideWithCamera[row * width + column] = UInt8((row * 3 + column) % 256) } }
        #expect(VideoToFrames.isAddition(slideWithCamera, to: withCamera, ignoring: camera))
        // A slide on a dark background is a new slide, whatever its ink.
        #expect(!VideoToFrames.isAddition(slide, to: drawing(blank(40), x: 20..<120, y: 20..<30, value: 230), ignoring: still))
        // Live camera footage never merges this way.
        var live = still
        live.isCamera = true
        #expect(!VideoToFrames.isAddition(slide, to: slide, ignoring: live))
    }

    private func jpeg(_ slide: TestMedia.Slide) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, TestMedia.slideImage(slide), [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aBuildKeepsTheFullestFrameAtTheFirstStepsTime() throws {
        typealias S = TestMedia.Slide
        let bullets = ["Split the array in half", "Sort each half", "Merge the two halves"]
        let steps = try (1...3).map { try jpeg(S(title: "Merge sort", bullets: Array(bullets.prefix($0)), seconds: 1)) }
        // The next slide, same template, one bullet different: a new slide, not a build.
        let next = try jpeg(S(title: "Merge sort", bullets: ["Split the array in half", "Sort each half", "Merge the two lists"], seconds: 1))
        let jpegs = steps + [next]
        let frames = zip([10.0, 14, 19, 30], jpegs).map { LectureFrame(seconds: $0, jpeg: $1) }
        let analyses = frames.map { _ in FrameAnalysis(text: "", visualScore: 0) }
        let (kept, _, pixels) = VideoToFrames.mergingAdditions(frames, analyses, pixels: frames.map { _ in nil }, motion: still)
        #expect(kept.map(\.seconds) == [10, 30], "One frame for the build, one for the changed slide")
        #expect(kept.first?.jpeg == steps[2], "The build's last, fullest picture")
        #expect(pixels.count == 2)
    }

    @Test func aChangedNumberIsANewSlideEvenWhenItsShapeOverlaps() throws {
        typealias S = TestMedia.Slide
        // A 6 covers almost all of a 5; with one pixel of slack nothing looked missing.
        for (a, b) in [(5, 6), (8, 9), (1, 7)] {
            let first = try #require(VideoToFrames.detailPixels(try jpeg(S(title: "Slide \(a) heading", bullets: ["Point \(a)a"], seconds: 1))))
            let second = try #require(VideoToFrames.detailPixels(try jpeg(S(title: "Slide \(b) heading", bullets: ["Point \(b)a"], seconds: 1))))
            #expect(!VideoToFrames.isAddition(first, to: second, width: 640, height: 360, ignoring: still), "\(a) → \(b)")
        }
    }

    @Test func aMovedPointerOverTheSameTextIsADuplicate() {
        let text = drawing(blank(), x: 20..<200, y: 20..<30)
        var withPointer = text
        for row in 40..<52 { withPointer[row * width + 100] = 20 }  // an I-beam pointer below the text
        var moved = text
        for row in 60..<72 { moved[row * width + 150] = 20 }  // the pointer somewhere else
        // Its 12 pixels are missing later: too many for noise, but the words are unchanged.
        #expect(!VideoToFrames.isAddition(withPointer, to: moved, ignoring: still), "Without the words, not merged")
        #expect(VideoToFrames.isAddition(withPointer, to: moved, ignoring: still, earlierText: "int main() return 0", laterText: "int main() return 0"))
        #expect(!VideoToFrames.isAddition(withPointer, to: moved, ignoring: still, earlierText: "int x = 5 return", laterText: "int x = 6 return"), "A changed word is kept")
    }

    @Test func writingHiddenByTheLecturerCountsWhenALaterFrameShowsIt() {
        let board = drawing(drawing(blank(), x: 20..<140, y: 30..<40), x: 180..<300, y: 30..<40)
        // The lecturer stands in front of the left half, then the right half.
        var leftHidden = board, rightHidden = board
        // (About a quarter of the picture each, like a person; the board stays the main colour.)
        for row in 20..<120 { for column in 10..<150 { leftHidden[row * width + column] = 150 } }
        for row in 20..<120 { for column in 170..<310 { rightHidden[row * width + column] = 150 } }
        // Every stroke of the full board is in one of the two later frames.
        #expect(VideoToFrames.isCovered(board, by: [leftHidden, rightHidden], ignoring: still))
        #expect(!VideoToFrames.isCovered(board, by: [leftHidden], ignoring: still), "One of them alone isn't enough")
        // Erased while hidden: the left half is gone in every later frame, so the full board is kept.
        var erased = rightHidden
        for row in 30..<40 { for column in 20..<140 { erased[row * width + column] = 235 } }
        #expect(!VideoToFrames.isCovered(board, by: [leftHidden, erased].map { frame in
            var copy = frame
            for row in 30..<40 { for column in 20..<140 { copy[row * width + column] = 235 } }
            return copy
        }, ignoring: still))
    }
}

