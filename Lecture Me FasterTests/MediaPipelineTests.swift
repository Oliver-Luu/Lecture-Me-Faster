import AVFoundation
import Testing
@testable import Lecture_Me_Faster

struct MediaPipelineTests {
    @Test func thinningKeepsEvenlySpacedFramesUpToTheLimit() {
        let frames = (0..<10).map { LectureFrame(seconds: Double($0), jpeg: Data()) }
        #expect(VideoToFrames.thinned(frames, to: 5).map(\.seconds) == [0, 2, 4, 6, 8])
        #expect(VideoToFrames.thinned(frames, to: 10).count == 10)
        #expect(VideoToFrames.thinned(frames, to: 50).count == 10)
    }

    @Test func blockDifferencesLocateAChange() {
        typealias S = VideoToFrames.Signature
        let base = [UInt8](repeating: 100, count: S.width * S.height)
        var changed = base
        // Brighten the top-left block only.
        for y in 0..<S.block { for x in 0..<S.block { changed[y * S.width + x] = 200 } }
        let differences = S.blockDifferences(base, changed)
        #expect(differences.count == S.blockCount)
        #expect(differences[0] == 100)
        #expect(differences.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test func findsOneFramePerSlideInAVideo() async throws {
        let video = try await TestMedia.makeSlideVideo(slides: 3, secondsPerSlide: 8)
        defer { try? FileManager.default.removeItem(at: video) }

        let output = try await VideoToFrames.extract(from: video) { _ in }
        #expect(output.distinctCount == 3)
        #expect(output.frames.map(\.seconds) == [0, 8, 16])
        #expect(output.frames.allSatisfy { $0.jpeg.starts(with: [0xFF, 0xD8]) })

        let capped = try await VideoToFrames.extract(from: video, options: .init(maxFrames: 2)) { _ in }
        #expect(capped.frames.count == 2)
        #expect(capped.distinctCount == 3)
    }

    @Test func transcriptionRejectsFilesWithoutAudio() async throws {
        let video = try await TestMedia.makeSlideVideo(slides: 1, secondsPerSlide: 2)
        defer { try? FileManager.default.removeItem(at: video) }

        await #expect(throws: AudioToTranscription.Failure.self) {
            try await AudioToTranscription.transcribe(video) { _ in }
        }
    }
}
