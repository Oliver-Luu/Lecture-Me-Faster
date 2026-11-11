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

    @Test func changedFractionCountsOnlyClearlyDifferentPixels() {
        let base = [UInt8](repeating: 100, count: 100)
        var noisy = base
        noisy[0] = 110
        var changed = base
        for index in 0..<25 { changed[index] = 200 }
        #expect(VideoToFrames.changedFraction(base, base) == 0)
        #expect(VideoToFrames.changedFraction(base, noisy) == 0)
        #expect(VideoToFrames.changedFraction(base, changed) == 0.25)
    }

    @Test func findsOneFramePerSlideInAVideo() async throws {
        let video = try await makeSlideVideo(slides: 3, secondsPerSlide: 8)
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
        let video = try await makeSlideVideo(slides: 1, secondsPerSlide: 2)
        defer { try? FileManager.default.removeItem(at: video) }

        await #expect(throws: AudioToTranscription.Failure.self) {
            try await AudioToTranscription.transcribe(video) { _ in }
        }
    }

    /// Writes a silent video where each "slide" is a white frame with a dark band in a different place.
    private func makeSlideVideo(slides: Int, secondsPerSlide: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let width = 640, height = 360, framesPerSecond = 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<(slides * secondsPerSlide * framesPerSecond) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let slide = frame / (secondsPerSlide * framesPerSecond)
            memset(base, 255, bytesPerRow * height)
            memset(base + bytesPerRow * (40 + slide * 100), 20, bytesPerRow * 60)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(framesPerSecond)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
