import Foundation
import Observation

/// Runs one lecture through the pipeline: frames and transcript in parallel, then the AI summary.
@Observable final class LectureSession {
    enum Phase: Equatable {
        case idle, processing, summarizing, done
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var title = ""
    private(set) var frameProgress = 0.0
    private(set) var transcriptProgress = 0.0
    private(set) var frames: [LectureFrame] = []
    private(set) var distinctFrameCount = 0
    private(set) var transcript: [TranscriptSegment] = []
    private(set) var summary = ""

    private var task: Task<Void, Never>?

    func start(_ url: URL, settings: AppSettings) {
        reset()
        title = url.deletingPathExtension().lastPathComponent
        phase = .processing
        let frameOptions = VideoToFrames.Options(maxFrames: settings.stored.maxFrames)

        run {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            async let extraction = VideoToFrames.extract(from: url, options: frameOptions) { value in
                Task { @MainActor in self.frameProgress = value }
            }
            async let transcription = AudioToTranscription.transcribe(url) { value in
                Task { @MainActor in self.transcriptProgress = value }
            }
            let (output, segments) = try await (extraction, transcription)
            self.frames = output.frames
            self.distinctFrameCount = output.distinctCount
            self.transcript = segments
            try await self.summarize(settings)
        }
    }

    /// Re-runs only the AI step, e.g. after switching models.
    func resummarize(settings: AppSettings) {
        task?.cancel()
        run { try await self.summarize(settings) }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        title = ""
        frameProgress = 0
        transcriptProgress = 0
        frames = []
        distinctFrameCount = 0
        transcript = []
        summary = ""
    }

    private func run(_ work: @escaping () async throws -> Void) {
        task = Task {
            do {
                try await work()
            } catch {
                if !Task.isCancelled {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func summarize(_ settings: AppSettings) async throws {
        let configuration = try settings.configuration()
        summary = ""
        phase = .summarizing
        let stream = FileToAI.summarize(
            title: title,
            transcript: transcript,
            frames: settings.stored.includeFrames ? frames : [],
            with: configuration
        )
        for try await text in stream {
            summary += text
        }
        phase = .done
    }
}
