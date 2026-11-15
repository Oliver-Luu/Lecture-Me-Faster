import AVFoundation
import Speech

nonisolated struct TranscriptSegment: Identifiable, Sendable, Codable, Equatable {
    var id = UUID()
    let seconds: Double
    let text: String
}

/// Transcribes a lecture's audio entirely on device with Apple's SpeechAnalyzer.
nonisolated enum AudioToTranscription {
    enum Failure: LocalizedError {
        case noAudio

        var errorDescription: String? { "This file has no audio track to transcribe." }
    }

    /// Transcribes `url`, in `pieces` time ranges at once when more than 1 (see `plan`).
    @concurrent
    static func transcribe(
        _ url: URL,
        locale: Locale = .current,
        pieces: Int = 1,
        tuning: PieceTuning = PieceTuning(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noAudio }
        let duration = try await asset.load(.duration).seconds

        let isVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let audioURL = isVideo ? try await separateAudio(from: asset) : url
        defer { if isVideo { try? FileManager.default.removeItem(at: audioURL) } }

        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let speechLocale = supported ?? Locale(identifier: "en-US")
        // Each cut moves to the nearest pause, so no word is split between two pieces.
        let even = evenCuts(duration: duration, pieces: pieces)
        let cuts = tuning.alignToPauses ? even.map { quietestMoment(in: audioURL, near: $0) } : even
        let ranges = plan(duration: duration, cuts: cuts)
        if ranges.count > 1 {
            return try await transcribeInPieces(
                audioURL, ranges: ranges, locale: speechLocale, atOnce: tuning.atOnce, progress: progress
            )
        }

        let transcriber = SpeechTranscriber(locale: speechLocale, preset: .transcription)
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

    // MARK: One recording in pieces

    /// The most pieces one recording is split into, and the shortest a piece may be. Measured on 13
    /// minutes of speech with a known script (2026-11-13), word error rate: 1 piece 4.53%; 4 pieces with
    /// a 30 s lead-in 4.76% (no lead-in 5.26%); 8 pieces varied from 4.7% to 5.9%. On a real 73-minute
    /// lecture: 1 piece 58 s, 2 pieces 32 s, 4 pieces 19 s.
    static let maxPieces = 4

    /// Choices for how pieces are made, for measuring their effect; the app uses the defaults.
    struct PieceTuning: Sendable {
        /// Move each cut to the nearest pause.
        var alignToPauses = true
        /// Transcribe the pieces at the same time (otherwise one after another).
        var atOnce = true
    }
    static let minimumPieceSeconds = 300.0
    /// Each piece starts this long before its own range, so the recognizer has context at the cut; the
    /// text from the lead-in is dropped.
    static let leadIn = 30.0
    /// Each piece runs this long past its range, so a sentence across the cut is finished.
    static let overhang = 20.0

    struct Piece: Equatable, Sendable {
        /// The audio this piece transcribes.
        var start: Double
        var end: Double
        /// The part of the timeline this piece is responsible for.
        var keepFrom: Double
        var keepUntil: Double
    }

    /// Where pieces meet: evenly spaced, before any move to a pause. Up to `pieces` equal ranges, none
    /// shorter than `minimumPieceSeconds`.
    static func evenCuts(duration: Double, pieces: Int) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = max(1, min(pieces, maxPieces, Int(duration / minimumPieceSeconds)))
        return (1..<count).map { duration * Double($0) / Double(count) }
    }

    /// The pieces for the given cuts (in order, inside the recording).
    static func plan(duration: Double, cuts: [Double]) -> [Piece] {
        guard duration.isFinite, duration > 0 else { return [Piece(start: 0, end: 0, keepFrom: 0, keepUntil: .infinity)] }
        let edges = [0.0] + cuts + [duration]
        return (0..<(edges.count - 1)).map { index in
            let from = edges[index], until = edges[index + 1]
            let isLast = index == edges.count - 2
            return Piece(
                start: index == 0 ? 0 : max(0, from - leadIn),
                end: isLast ? duration : min(duration, until + overhang),
                keepFrom: index == 0 ? -.infinity : from,
                keepUntil: isLast ? .infinity : until
            )
        }
    }

    static func plan(duration: Double, pieces: Int) -> [Piece] {
        plan(duration: duration, cuts: evenCuts(duration: duration, pieces: pieces))
    }

    /// How far a cut may move to reach a pause, and how long the quiet stretch it looks for is.
    static let pauseSearchSeconds = 30.0
    static let pauseLength = 0.5

    /// The middle of the quietest `pauseLength` within `pauseSearchSeconds` of `time`: a gap between
    /// words or sentences, so no word is cut in two. Returns `time` when the audio can't be read.
    static func quietestMoment(in url: URL, near time: Double) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return time }
        let format = file.processingFormat
        let rate = format.sampleRate
        let from = max(0, AVAudioFramePosition((time - pauseSearchSeconds) * rate))
        let until = min(file.length, AVAudioFramePosition((time + pauseSearchSeconds) * rate))
        guard until > from, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(until - from)) else { return time }
        file.framePosition = from
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(until - from))) != nil,
              let channels = buffer.floatChannelData else { return time }
        // Loudness of each 50 ms step (mean square over every channel).
        let step = max(1, Int(rate * 0.05))
        let frames = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var energy: [Double] = []
        var position = 0
        while position + step <= frames {
            var sum = 0.0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for index in position..<(position + step) { sum += Double(samples[index] * samples[index]) }
            }
            energy.append(sum)
            position += step
        }
        let window = max(1, Int(pauseLength / 0.05))
        guard energy.count >= window else { return time }
        // The quietest run of `window` steps; on a tie, the one nearest the planned cut.
        var running = energy[0..<window].reduce(0, +)
        var best = (sum: running, start: 0)
        func distance(_ start: Int) -> Double {
            abs(Double(from) / rate + (Double(start) + Double(window) / 2) * 0.05 - time)
        }
        for start in 1...(energy.count - window) {
            running += energy[start + window - 1] - energy[start - 1]
            if running < best.sum - 1e-12 || (abs(running - best.sum) <= 1e-12 && distance(start) < distance(best.start)) {
                best = (running, start)
            }
        }
        return Double(from) / rate + (Double(best.start) + Double(window) / 2) * 0.05
    }

    /// A recognized sentence, with the timing of each of its words, needed to join pieces exactly.
    struct TimedSegment: Sendable, Equatable {
        struct Word: Sendable, Equatable {
            var start: Double
            /// The word as written in the sentence, with the space before it.
            var text: String
        }
        var start: Double
        var end: Double
        var text: String
        /// Empty when the recognizer gave no word timings; then the sentence's start decides.
        var words: [Word] = []
    }

    /// Joins the pieces word by word: each piece contributes exactly the words that start inside its own
    /// range, so every word near a cut comes from one piece only, never twice and never missing. A
    /// sentence across a cut becomes two lines, its start from one piece and its end from the next.
    static func merge(_ pieces: [Piece], _ results: [[TimedSegment]]) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for (piece, segments) in zip(pieces, results) {
            func isInside(_ time: Double) -> Bool { time >= piece.keepFrom && time < piece.keepUntil }
            for segment in segments {
                if segment.words.isEmpty {
                    if isInside(segment.start) { merged.append(TranscriptSegment(seconds: segment.start, text: segment.text)) }
                    continue
                }
                let kept = segment.words.filter { isInside($0.start) }
                guard let first = kept.first else { continue }
                let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { merged.append(TranscriptSegment(seconds: first.start, text: text)) }
            }
        }
        return merged
    }

    private static func transcribeInPieces(
        _ url: URL, ranges: [Piece], locale: Locale, atOnce: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let installer = SpeechTranscriber(locale: locale, preset: .transcription)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [installer]) {
            try await download.downloadAndInstall()
        }
        let tracker = ProgressTracker(count: ranges.count, report: progress)
        if !atOnce {
            var results: [[TimedSegment]] = []
            for (index, piece) in ranges.enumerated() {
                results.append(try await transcribe(url, from: piece.start, to: piece.end, locale: locale) { tracker.update(index, $0) })
            }
            progress(1)
            return merge(ranges, results)
        }
        let results = try await withThrowingTaskGroup(of: (Int, [TimedSegment]).self) { group in
            for (index, piece) in ranges.enumerated() {
                group.addTask {
                    let segments = try await transcribe(url, from: piece.start, to: piece.end, locale: locale) {
                        tracker.update(index, $0)
                    }
                    return (index, segments)
                }
            }
            var out = [[TimedSegment]](repeating: [], count: ranges.count)
            for try await (index, segments) in group { out[index] = segments }
            return out
        }
        progress(1)
        return merge(ranges, results)
    }

    /// Transcribes one time range of an audio file, feeding it to the recognizer directly (no temporary
    /// file). Times in the results are on the whole file's timeline.
    static func transcribe(
        _ url: URL, from start: Double, to end: Double, locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedSegment] {
        // The same recognition as the `.transcription` preset, plus each word's time, for joining pieces.
        let preset = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions, attributeOptions: preset.attributeOptions.union([.audioTimeRange])
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return [] }
        let length = max(end - start, 1)
        let collector = Task {
            var out: [TimedSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var words: [TimedSegment.Word] = []
                    for run in result.text.runs {
                        let piece = String(result.text[run.range].characters)
                        if let range = run.audioTimeRange {
                            words.append(TimedSegment.Word(start: range.start.seconds, text: piece))
                        } else if !words.isEmpty {
                            words[words.count - 1].text += piece  // punctuation or a space after a word
                        } else {
                            words.append(TimedSegment.Word(start: result.range.start.seconds, text: piece))
                        }
                    }
                    out.append(TimedSegment(
                        start: result.range.start.seconds, end: result.range.end.seconds, text: text, words: words
                    ))
                }
                progress(min(1, (result.range.end.seconds - start) / length))
            }
            return out
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let rate = source.sampleRate
        let endFrame = min(AVAudioFramePosition(end * rate), file.length)
        file.framePosition = min(AVAudioFramePosition(start * rate), file.length)
        guard let converter = AVAudioConverter(from: source, to: target) else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return []
        }
        var isFirst = true
        do {
            while file.framePosition < endFrame {
                try Task.checkCancellation()
                // One second at a time.
                let count = AVAudioFrameCount(min(Int64(rate), endFrame - file.framePosition))
                guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count) else { break }
                try file.read(into: input, frameCount: count)
                let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / rate) + 1024
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
                var fed = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return input
                }
                if let conversionError { throw conversionError }
                // The first buffer says where on the timeline this piece starts; the rest follow on.
                let time: CMTime? = isFirst ? CMTime(seconds: start, preferredTimescale: 1000) : nil
                isFirst = false
                continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
            }
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// Combines the progress of pieces running at once into one value.
    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        private let report: @Sendable (Double) -> Void
        init(count: Int, report: @escaping @Sendable (Double) -> Void) {
            values = Array(repeating: 0, count: count)
            self.report = report
        }
        func update(_ index: Int, _ value: Double) {
            let total = lock.withLock {
                values[index] = max(values[index], value)
                return values.reduce(0, +) / Double(values.count)
            }
            report(total)
        }
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
