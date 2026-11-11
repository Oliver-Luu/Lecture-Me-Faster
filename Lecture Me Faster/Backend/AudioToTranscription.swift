import AVFoundation
import Speech

nonisolated struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let seconds: Double
    let text: String
}

/// Transcribes a lecture's audio entirely on device with Apple's SpeechAnalyzer.
nonisolated enum AudioToTranscription {
    enum Failure: LocalizedError {
        case noAudio

        var errorDescription: String? { "This file has no audio track to transcribe." }
    }

    @concurrent
    static func transcribe(
        _ url: URL,
        locale: Locale = .current,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noAudio }
        let duration = try await asset.load(.duration).seconds

        let isVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let audioURL = isVideo ? try await separateAudio(from: asset) : url
        defer { if isVideo { try? FileManager.default.removeItem(at: audioURL) } }

        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let transcriber = SpeechTranscriber(locale: supported ?? Locale(identifier: "en-US"), preset: .transcription)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let segments = collect(transcriber.results, duration: duration, progress: progress)

        let file = try AVAudioFile(forReading: audioURL)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await segments
    }

    private static func collect(
        _ results: some AsyncSequence<SpeechTranscriber.Result, any Error> & Sendable,
        duration: Double,
        progress: @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(seconds: result.range.start.seconds, text: text))
            }
            progress(result.range.end.seconds / duration)
        }
        progress(1)
        return segments
    }

    /// Splits the audio track out of a video into a temporary .m4a file.
    private static func separateAudio(from asset: AVURLAsset) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.noAudio
        }
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try await export.export(to: output, as: .m4a)
        return output
    }
}
