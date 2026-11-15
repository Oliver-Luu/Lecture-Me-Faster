import AVFoundation
import Foundation
import Testing
@testable import Lecture_Me_Faster

/// One recording transcribed in pieces at once (`AudioToTranscription.plan` and `merge`).
struct TranscriptionPiecesTests {
    typealias A = AudioToTranscription

    @Test func longRecordingsSplitIntoUpToFourPiecesWithLeadInAndOverhang() {
        let pieces = A.plan(duration: 4000, pieces: 4)
        #expect(pieces.count == 4)
        #expect(pieces[0] == A.Piece(start: 0, end: 1020, keepFrom: -.infinity, keepUntil: 1000))
        #expect(pieces[1] == A.Piece(start: 970, end: 2020, keepFrom: 1000, keepUntil: 2000), "Starts 30 s early, ends 20 s late")
        #expect(pieces[3] == A.Piece(start: 2970, end: 4000, keepFrom: 3000, keepUntil: .infinity))
    }

    @Test func shortRecordingsAreNotSplitIntoTinyPieces() {
        #expect(A.plan(duration: 200, pieces: 4).count == 1, "Under 5 minutes: one piece")
        #expect(A.plan(duration: 700, pieces: 4).count == 2, "Pieces of at least 5 minutes")
        #expect(A.plan(duration: 99_000, pieces: 16).count == 4, "Never more than 4")
        #expect(A.plan(duration: .nan, pieces: 4).count == 1)
    }

    /// A sentence with one word per second from `start`.
    private func sentence(_ start: Double, _ text: String) -> A.TimedSegment {
        let parts = text.split(separator: " ").enumerated().map { index, word in
            A.TimedSegment.Word(start: start + Double(index), text: (index == 0 ? "" : " ") + word)
        }
        return A.TimedSegment(start: start, end: start + Double(parts.count), text: text, words: parts)
    }

    @Test func piecesAreJoinedWordByWordAtTheCut() {
        let pieces = A.plan(duration: 1000, cuts: [500])
        // Piece A heard a long sentence running across the cut (thanks to its overhang); piece B heard it
        // from its lead-in, plus a long sentence that starts just before A's sentence ends. The old
        // sentence-level rule dropped that whole second sentence.
        let first = [
            sentence(480, "Before the cut."),
            sentence(495, "one two three four five six seven eight"),  // 495...502
        ]
        let second = [
            sentence(470, "Lead-in words dropped."),
            sentence(495, "one two three four five six seven eight"),
            sentence(501.5, "a long sentence that B heard starting before A ended"),
        ]
        let merged = A.merge(pieces, [first, second])
        #expect(merged.map(\.text) == [
            "Before the cut.", "one two three four five", "six seven eight", "a long sentence that B heard starting before A ended",
        ])
        #expect(merged.map(\.seconds) == [480, 495, 500, 501.5])
        let allWords = merged.map(\.text).joined(separator: " ").split(separator: " ")
        #expect(allWords.filter { $0 == "six" }.count == 1, "No word twice")
    }

    @Test func sentencesWithoutWordTimesFallBackToTheirStart() {
        let pieces = A.plan(duration: 1000, cuts: [500])
        let plain = [A.TimedSegment(start: 490, end: 498, text: "Mine."), A.TimedSegment(start: 505, end: 510, text: "Not mine.")]
        #expect(A.merge(pieces, [plain, [A.TimedSegment(start: 505, end: 510, text: "Not mine.")]]).map(\.text) == ["Mine.", "Not mine."])
    }

    @Test func cutsMoveToTheNearestPause() throws {
        // 120 s of tone with one half-second of silence at 47 s: a cut planned at 60 s moves there.
        let rate = 16_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let url = FileManager.default.temporaryDirectory.appending(path: "pause-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(rate * 120)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try #require(buffer.floatChannelData)[0]
            for index in 0..<Int(frames) {
                let time = Double(index) / rate
                samples[index] = (47...47.5).contains(time) ? 0 : Float(0.3 * sin(2 * .pi * 220 * time))
            }
            try file.write(from: buffer)
        }
        let cut = A.quietestMoment(in: url, near: 60)
        #expect(abs(cut - 47.25) < 0.1, "Moved to the silence: \(cut)")
        #expect(A.quietestMoment(in: URL(filePath: "/nonexistent.wav"), near: 60) == 60)
    }

    @Test func aboutFourTranscriptionsRunInTotal() {
        #expect(LectureSession.transcriptionPieces(fileCount: 1, concurrency: 4) == 4)
        #expect(LectureSession.transcriptionPieces(fileCount: 2, concurrency: 4) == 2)
        #expect(LectureSession.transcriptionPieces(fileCount: 13, concurrency: 4) == 1)
        #expect(LectureSession.transcriptionPieces(fileCount: 3, concurrency: 2) == 2, "Video lectures: 2 files at once")
    }
}
