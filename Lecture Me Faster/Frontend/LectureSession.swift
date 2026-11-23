import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// Runs one lecture through the pipeline: frames and transcript in parallel, then the AI summary.
/// Also shows a lecture reopened from the history.
///
/// A lecture can be made of several files (a class recorded in parts). The files are processed one after
/// another and joined into one timeline: each part's slides and transcript are shifted by the length of
/// the parts before it.
///
/// With a `history`, the lecture is saved as soon as its slides and transcript are ready, and its notes
/// are saved each time the model finishes writing them.
@Observable final class LectureSession {
    enum Phase: Equatable {
        case idle, processing, summarizing, done
        case failed(String)
        /// The lecture is too long for one request; waiting for the user to agree to write it in parts.
        case awaitingSplitApproval(SplitProposal)
    }

    /// What writing a long lecture in parts involves, shown before asking.
    struct SplitProposal: Equatable {
        var detail: NoteDetail
        var model: String
        var parts: Int
        /// Requests including the final combining step.
        var requests: Int
        /// The whole lecture as one request.
        var estimatedTokens: Int
        var contextTokens: Int

        /// After a change of model the lecture can fit in one request; the card then offers to write it.
        var fitsInOneRequest: Bool { parts <= 1 }
    }

    /// True while the split proposal is being worked out again for a changed model or setting.
    private(set) var isReplanning = false

    /// While a long lecture is written in parts: the step being done (1-based) and how many there are,
    /// the last being the combining step.
    struct PartProgress: Equatable {
        var step: Int
        var total: Int
        var isCombining: Bool { step == total }
    }


    let history: LectureHistory?

    init(history: LectureHistory? = nil) {
        self.history = history
    }

    private(set) var phase = Phase.idle
    /// The history entry for this lecture, once it has been saved.
    private(set) var savedID: UUID?
    private(set) var title = ""
    /// The files this lecture is made from, with where each starts. Empty for a single-file lecture.
    private(set) var parts: [LecturePart] = []
    /// While processing: how many files there are. Several are processed at once (`partConcurrency`).
    private(set) var partCount = 0
    /// Each file's progress (0...1) at finding slides and at transcribing.
    private(set) var partFrameProgress: [Double] = []
    private(set) var partTranscriptProgress: [Double] = []
    /// Which files are being processed right now, and how many are finished.
    private(set) var runningParts: [Int] = []
    private(set) var finishedPartCount = 0
    /// Overall progress across every file.
    var frameProgress: Double { Self.average(partFrameProgress) }
    var transcriptProgress: Double { Self.average(partTranscriptProgress) }

    nonisolated static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0) { $0 + min(max($1, 0), 1) } / Double(values.count)
    }
    private(set) var frames: [LectureFrame] = []
    private(set) var distinctFrameCount = 0
    private(set) var transcript: [TranscriptSegment] = []
    /// Supporting files and the text read from them.
    private(set) var documents: [LectureDocument] = []
    /// While processing: which supporting file (0-based) is being read, and how many there are.
    private(set) var currentMaterial = 0
    private(set) var materialCount = 0
    private(set) var isReadingMaterials = false
    /// Every set of notes written for this lecture, one per detail level.
    private(set) var versions: [NoteVersion] = []
    /// The level being written right now, while `phase` is `.summarizing`.
    private(set) var writingDetail: NoteDetail?
    /// The level whose notes failed most recently, so the error shows next to that level only.
    private(set) var failedDetail: NoteDetail?
    /// The notes streaming in for `writingDetail`.
    private(set) var liveNotes = ""
    private(set) var partProgress: PartProgress?
    /// The text and picture content of each frame: read while processing, or the first time notes are
    /// written for a lecture opened from the history, then reused.
    private var slideAnalyses: [FrameAnalysis]?
    /// Apple Intelligence's description of each frame, written only for models that can't see images.
    private var slideDescriptions: [String]?
    /// While slides are being described for a model that can't see images: which one, and how many.
    private(set) var slideDescriptionProgress: PartProgress?
    /// True while notes are being written with the slides sent as text, so the view can warn.
    private(set) var isSendingSlidesAsText = false
    /// Writes a short description of one slide's visuals, or nil when it can't. Uses Apple Intelligence
    /// (free, on device) when it's on; tests replace it so they never call a real model.
    @ObservationIgnored var describeSlide: @Sendable (Data) async -> String? = { jpeg in
        guard AppleIntelligence.isAvailable else { return nil }
        return try? await AppleIntelligence.describeSlide(jpeg)
    }

    /// True when there is anything to write notes from.
    var hasSource: Bool {
        !transcript.isEmpty || !frames.isEmpty || documents.contains { !$0.text.isEmpty }
    }

    /// The notes at one level: streaming if that level is being written, otherwise the saved version.
    func notes(for detail: NoteDetail?) -> String {
        if phase == .summarizing, writingDetail == detail { return liveNotes }
        return versions.first { $0.detail == detail }?.text ?? ""
    }

    func hasVersion(_ detail: NoteDetail?) -> Bool {
        versions.contains { $0.detail == detail }
    }

    private var task: Task<Void, Never>?
    /// Goes up each time the session is cleared, so progress reported late by a stopped lecture is ignored.
    private var generation = 0

    /// True while a lecture is being processed or its notes are being written.
    var isBusy: Bool { phase == .processing || phase == .summarizing }

    /// The names of the files being processed right now.
    var currentPartName: String {
        let names = runningParts.compactMap { $0 < partNames.count ? partNames[$0] : nil }
        return names.isEmpty ? title : names.formatted(.list(type: .and))
    }
    private var partNames: [String] = []

    /// The name of the supporting file being read right now.
    var currentMaterialName: String {
        currentMaterial < materialNames.count ? materialNames[currentMaterial] : ""
    }
    private var materialNames: [String] = []

    enum Failure: LocalizedError {
        case noText

        var errorDescription: String? {
            "No text could be read from these files, and there is no recording to transcribe."
        }
    }

    // MARK: Starting

    /// Processes a lecture called `title`: the recording files (video or audio) in the given order as
    /// one timeline, plus any supporting materials (PDF, Word, PowerPoint, text, images). Either list may
    /// be empty, but not both.
    func start(_ urls: [URL], materials: [URL] = [], title: String, settings: AppSettings) {
        guard !urls.isEmpty || !materials.isEmpty else { return }
        reset()
        self.title = title
        partNames = urls.map(Self.displayName)
        partCount = urls.count
        partFrameProgress = Array(repeating: 0, count: urls.count)
        partTranscriptProgress = Array(repeating: 0, count: urls.count)
        materialNames = materials.map(\.lastPathComponent)
        materialCount = materials.count
        phase = .processing
        // Every distinct slide is kept; the image limit is applied when the notes are written.
        let frameOptions = VideoToFrames.Options()
        let generation = generation

        run {
            let allFiles = urls + materials
            let scoped = allFiles.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, isScoped) in zip(allFiles, scoped) where isScoped { url.stopAccessingSecurityScopedResource() }
            }

            self.isReadingMaterials = true
            for (index, url) in materials.enumerated() {
                self.currentMaterial = index
                let document = await Self.readMaterial(url)
                // Stopped meanwhile (Cancel, or a new lecture started): leave the session alone.
                try Task.checkCancellation()
                self.documents.append(document)
            }
            self.isReadingMaterials = false
            let hasMaterialText = self.documents.contains { !$0.text.isEmpty }

            // Several files at once: transcription measured 3.2x faster with 4 recordings at a time.
            let concurrency = Self.partConcurrency(urls)
            let pieces = Self.transcriptionPieces(fileCount: urls.count, concurrency: concurrency)
            let audioPieces = settings.stored.transcribeInPieces ? pieces : 1
            let results = try await Self.inOrder(urls, concurrency: concurrency) { index, url in
                await MainActor.run {
                    if self.generation == generation { self.runningParts.append(index) }
                }
                defer {
                    Task { @MainActor in
                        guard self.generation == generation else { return }
                        self.runningParts.removeAll { $0 == index }
                        self.finishedPartCount += 1
                    }
                }
                return try await Self.process(
                    url, frameOptions: frameOptions, transcriptionPieces: audioPieces, scanPieces: pieces
                ) { kind, value in
                    Task { @MainActor in
                        guard self.generation == generation, index < self.partFrameProgress.count else { return }
                        if kind == .frames { self.partFrameProgress[index] = value } else { self.partTranscriptProgress[index] = value }
                    }
                }
            }
            // A stopped lecture must not be saved or sent to the model. (A cancelled transcription can
            // return the part it had finished instead of failing.)
            try Task.checkCancellation()
            // A silent recording is fine when anything else gives the notes something to say: another
            // recording's speech, the materials, or its own slides (a screen recording with no sound).
            guard results.contains(where: { $0.hasAudio || !$0.frames.isEmpty }) || hasMaterialText else {
                throw urls.isEmpty ? Failure.noText : AudioToTranscription.Failure.noAudio
            }

            // Each recording was already capped for its own length, so joining them thins nothing more:
            // a lecture of several recordings keeps every recording's slides.
            let combined = Self.combine(results)
            self.frames = combined.frames
            self.slideAnalyses = combined.analyses
            self.distinctFrameCount = combined.distinctFrameCount
            self.transcript = combined.transcript
            self.parts = urls.count > 1 ? combined.parts : []
            self.saveToHistory()
            try await self.summarize(settings, detail: settings.stored.noteDetail)
        }
    }

    /// Shows a lecture from the history without reprocessing it.
    func open(_ lecture: SavedLecture) {
        reset()
        savedID = lecture.id
        title = lecture.title
        parts = lecture.parts ?? []
        documents = lecture.documents ?? []
        transcript = lecture.transcript
        frames = history?.frames(for: lecture) ?? []
        distinctFrameCount = lecture.distinctFrameCount
        versions = lecture.noteVersions
        partFrameProgress = [1]
        partTranscriptProgress = [1]
        phase = .done
    }

    /// Follows a rename made in the history, so the window title and the next notes written use it.
    func rename(to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { self.title = title }
    }

    /// Writes (or rewrites) the notes at one detail level, reusing the slides, transcript, and materials.
    /// Other levels' notes are kept.
    func resummarize(settings: AppSettings, detail: NoteDetail, splitApproved: Bool = false) {
        task?.cancel()
        isReplanning = false
        // Mark the level as being written now, not when the task starts, so buttons disable at once.
        liveNotes = ""
        writingDetail = detail
        phase = .summarizing
        run { try await self.summarize(settings, detail: detail, splitApproved: splitApproved) }
    }

    /// The user agreed to write a long lecture in parts.
    func approveSplit(settings: AppSettings) {
        guard case .awaitingSplitApproval(let proposal) = phase else { return }
        resummarize(settings: settings, detail: proposal.detail, splitApproved: true)
    }

    /// Works the split proposal out again after the model or a setting that affects it changed, so the card
    /// shows the new model's limits. Nothing is written: if it now fits in one request, the card says so and
    /// waits to be told to write.
    func replan(settings: AppSettings) {
        guard case .awaitingSplitApproval(let proposal) = phase else { return }
        task?.cancel()
        isReplanning = true
        run {
            // A proposal stopped for a newer one leaves the flag to that one.
            defer { if !Task.isCancelled { self.isReplanning = false } }
            try await self.summarize(settings, detail: proposal.detail, planOnly: true)
        }
    }

    /// The user declined: nothing is written, and the lecture is left as it was.
    func declineSplit() {
        if case .awaitingSplitApproval = phase { phase = .done }
    }

    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        isReplanning = false
        partProgress = nil
        slideDescriptionProgress = nil
        isSendingSlidesAsText = false
        phase = .idle
        savedID = nil
        title = ""
        parts = []
        partNames = []
        partCount = 0
        runningParts = []
        finishedPartCount = 0
        documents = []
        materialNames = []
        currentMaterial = 0
        materialCount = 0
        isReadingMaterials = false
        partFrameProgress = []
        partTranscriptProgress = []
        frames = []
        slideAnalyses = nil
        slideDescriptions = nil
        distinctFrameCount = 0
        transcript = []
        versions = []
        writingDetail = nil
        failedDetail = nil
        liveNotes = ""
    }

    // MARK: Files

    /// Whether a file looks like a video or audio file the app can process.
    nonisolated static func isLectureFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }

    nonisolated static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Orders files the way Finder does, so "Part 2" comes before "Part 10". When every name contains a
    /// date ("september 28", "Oct 5", "october19", "2026-10-12"), they are put in date order instead, so a
    /// semester of classes runs from the first class to the last.
    nonisolated static func sortedByName(_ urls: [URL]) -> [URL] {
        let byName = urls.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        let dates = byName.map { nameDate(displayName($0)) }
        guard byName.count > 1, dates.allSatisfy({ $0 != nil }) else { return byName }
        // Sorting is stable, so files with the same date keep their name order.
        let keys = dates.enumerated().map { ($0.element!.0, $0.element!.1, $0.element!.2, $0.offset) }
        return keys.sorted { $0 < $1 }.map { byName[$0.3] }
    }

    private nonisolated static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    /// A sortable date read from a file name, as (year, month, day); the year is 0 when the name has none.
    /// Month names may be abbreviated or slightly misspelled ("novermber"), and may run into the day ("october19").
    nonisolated static func nameDate(_ name: String) -> (Int, Int, Int)? {
        let lower = name.lowercased()
        if let match = lower.firstMatch(of: /(\d{4})[-_. ](\d{1,2})[-_. ](\d{1,2})/),
           let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
           (1...12).contains(month), (1...31).contains(day) {
            return (year, month, day)
        }
        for match in lower.matches(of: /([a-z]{3,})[\s_\-.,]*(\d{1,2})(?!\d)/) {
            guard let month = month(named: String(match.1)), let day = Int(match.2), (1...31).contains(day) else { continue }
            let year = lower.firstMatch(of: /(?:^|\D)(20\d\d)(?!\d)/).flatMap { Int($0.1) } ?? 0
            return (year, month, day)
        }
        return nil
    }

    /// 1–12 for a month name, its three-letter abbreviation ("sept" too), or a near miss of the full name.
    private nonisolated static func month(named word: String) -> Int? {
        for (index, full) in monthNames.enumerated() {
            let short = String(full.prefix(3))
            if word == full || word == short || (full == "september" && word == "sept") { return index + 1 }
            if word.count >= 5, word.hasPrefix(short), editDistance(word, full) <= 2 { return index + 1 }
        }
        return nil
    }

    private nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// A lecture name for several files: what their names have in common, minus a trailing part number,
    /// e.g. "Lecture 5 - Part 1" and "Lecture 5 - Part 2" give "Lecture 5". Falls back to the first name.
    nonisolated static func suggestedTitle(for urls: [URL]) -> String {
        let names = urls.map(displayName)
        guard let first = names.first else { return "" }
        guard names.count > 1 else { return first }

        var prefix = names.dropFirst().reduce(first) { common, name in String(common.commonPrefix(with: name)) }
        let trailingJunk = CharacterSet.alphanumerics.inverted
        func trim() { prefix = prefix.trimmingCharacters(in: trailingJunk) }
        trim()
        for word in ["part", "pt", "section", "video", "recording"] where prefix.lowercased().hasSuffix(word) {
            prefix = String(prefix.dropLast(word.count))
            trim()
        }
        // A couple of shared letters ("Le") is a coincidence, not a name.
        return prefix.count >= 3 ? prefix : first
    }

    /// Reads one supporting file. A file that can't be read is kept with its error instead of stopping
    /// the whole lecture.
    nonisolated static func readMaterial(_ url: URL) async -> LectureDocument {
        do {
            return try await DocumentToText.read(url)
        } catch {
            return LectureDocument(
                name: url.lastPathComponent, kind: DocumentToText.kind(of: url) ?? .text, text: "",
                readError: error.localizedDescription
            )
        }
    }

    // MARK: Processing one file

    nonisolated enum ProgressKind: Sendable { case frames, transcript }

    /// How many recordings are processed at once. Audio only: 4 (4 real 75-minute recordings took 249 s
    /// one at a time, 134 s two at a time, 77 s four at a time, 2026-11-13). With any video: 2, because
    /// each video already reads several slides at once and holds full-size frames while it does.
    nonisolated static func partConcurrency(_ urls: [URL]) -> Int {
        let allAudio = urls.allSatisfy { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audio) && !type.conforms(to: .movie)
        }
        return allAudio ? 4 : 2
    }

    /// How many pieces each recording's audio is split into, so about `AudioToTranscription.maxPieces`
    /// transcriptions run at once in total: one recording gets 4 pieces, two get 2 each, four or more get 1.
    nonisolated static func transcriptionPieces(fileCount: Int, concurrency: Int) -> Int {
        max(1, AudioToTranscription.maxPieces / max(1, min(fileCount, concurrency)))
    }

    /// Runs `work` on every item, up to `concurrency` at once, and returns the results in the items'
    /// order whatever order they finish in. The first error cancels the rest and is thrown.
    nonisolated static func inOrder<Item: Sendable, Result: Sendable>(
        _ items: [Item], concurrency: Int,
        _ work: @escaping @Sendable (Int, Item) async throws -> Result
    ) async throws -> [Result] {
        var results = [Result?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next, item = items[next]
                next += 1
                group.addTask { (index, try await work(index, item)) }
            }
            for _ in 0..<max(concurrency, 1) { addNext() }
            while let (index, result) = try await group.next() {
                results[index] = result
                addNext()
            }
        }
        return results.compactMap { $0 }
    }

    /// What one file contributed, on its own timeline (starting at 0).
    nonisolated struct PartResult: Sendable {
        var name: String
        var duration: Double
        var frames: [LectureFrame]
        /// What was read from each frame, in the same order.
        var analyses: [FrameAnalysis] = []
        var distinctFrameCount: Int
        var transcript: [TranscriptSegment]
        var hasAudio: Bool
    }

    /// Extracts slides and transcript from one file. A file with no audio contributes only its slides.
    @concurrent
    nonisolated static func process(
        _ url: URL,
        frameOptions: VideoToFrames.Options,
        transcriptionPieces: Int = 1,
        scanPieces: Int? = nil,
        progress: @escaping @Sendable (ProgressKind, Double) -> Void
    ) async throws -> PartResult {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        // Long recordings are split into pieces worked on at once, for the slides and the audio alike.
        let options = {
            var options = frameOptions
            options.scanPieces = scanPieces ?? transcriptionPieces
            return options
        }()
        async let extraction = VideoToFrames.extract(from: url, options: options) { progress(.frames, $0) }
        async let transcription = AudioToTranscription.transcribe(url, pieces: transcriptionPieces) { progress(.transcript, $0) }

        let output = try await extraction
        var segments: [TranscriptSegment] = []
        var hasAudio = true
        do {
            segments = try await transcription
        } catch AudioToTranscription.Failure.noAudio {
            hasAudio = false
            progress(.transcript, 1)
        }
        try Task.checkCancellation()
        return PartResult(
            name: displayName(url), duration: duration.isFinite ? duration : 0, frames: output.frames,
            analyses: output.analyses, distinctFrameCount: output.distinctCount, transcript: segments, hasAudio: hasAudio
        )
    }

    nonisolated struct Combined: Sendable {
        var frames: [LectureFrame]
        var analyses: [FrameAnalysis] = []
        var distinctFrameCount: Int
        var transcript: [TranscriptSegment]
        var parts: [LecturePart]
    }

    /// Joins parts into one timeline, each shifted by the total length of the parts before it. Every
    /// part's slides are kept: each recording was already capped for its own length
    /// (`VideoToFrames.storedFrameCap`).
    nonisolated static func combine(_ results: [PartResult]) -> Combined {
        var combined = Combined(frames: [], distinctFrameCount: 0, transcript: [], parts: [])
        var offset = 0.0
        for result in results {
            combined.parts.append(LecturePart(name: result.name, startSeconds: offset))
            combined.frames += result.frames.map { LectureFrame(seconds: $0.seconds + offset, jpeg: $0.jpeg) }
            // Parts read without analyses (older callers) get empty ones, so the lists stay aligned.
            combined.analyses += result.analyses.count == result.frames.count
                ? result.analyses : result.frames.map { _ in FrameAnalysis(text: "", visualScore: 0) }
            combined.transcript += result.transcript.map { TranscriptSegment(seconds: $0.seconds + offset, text: $0.text) }
            combined.distinctFrameCount += result.distinctFrameCount
            offset += result.duration
        }
        return combined
    }

    // MARK: Running

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

    /// `planOnly`: work out the plan with the current model and settings and show it as a proposal (see
    /// `replan`), without writing anything.
    private func summarize(
        _ settings: AppSettings, detail: NoteDetail, splitApproved: Bool = false, planOnly: Bool = false
    ) async throws {
        failedDetail = nil
        if !planOnly { writingDetail = detail }
        partProgress = nil
        slideDescriptionProgress = nil
        isSendingSlidesAsText = false
        defer {
            // A stopped request has been replaced (by another request, or by a cleared session), so the
            // state now belongs to its replacement.
            if !Task.isCancelled {
                if !planOnly { writingDetail = nil }
                partProgress = nil
                slideDescriptionProgress = nil
                isSendingSlidesAsText = false
            }
        }
        do {
            // The level's own model if Settings sets one (e.g. a fast model for Key points).
            var configuration = try settings.configuration(for: detail)
            // One question to the provider about the model: its window, its reply limit, and whether it
            // sees images. A rejected key is reported here, before anything is planned.
            let model = try await ModelCatalog.check(configuration)
            try Task.checkCancellation()
            configuration.maxOutputTokens = model?.maxOutputTokens
            configuration.supportsEffort = model?.supportsEffort
            if !planOnly {
                liveNotes = ""
                phase = .summarizing
            }
            let sentFrames = settings.stored.includeFrames ? frames : []
            // Read even when the images themselves aren't sent: the words are cheap and fix misheard terms.
            let slideTerms = await currentSlideTerms()
            // A model that can't see images gets each slide as text instead. When the provider doesn't
            // say, the images are tried first and the request is sent again as text if they're rejected.
            // More slides than the image limit: the ones with the most pictures go as images and the rest
            // as their text, so no slide is left out.
            var slideTexts: [String?]?
            var allAsText = false
            if !sentFrames.isEmpty {
                if model?.acceptsImages == false {
                    slideTexts = await currentSlidesAsText(describe: settings.stored.describeSlides)
                    allAsText = true
                } else if sentFrames.count > settings.stored.maxFrames {
                    slideTexts = await mixedSlides(imageLimit: settings.stored.maxFrames)
                }
            }

            // How much one request can carry with this model, and whether the lecture fits.
            let context = LongLectures.contextWindow(
                provider: configuration.provider, reported: model?.contextTokens,
                openAICompatibleSetting: settings.contextSetting(for: detail),
                ollamaSetting: settings.stored.ollamaContextTokens
            )
            configuration.contextTokens = context
            var budget = LongLectures.inputBudget(provider: configuration.provider, contextTokens: context)

            // Apple Intelligence's window is small, so measure the instructions and a slide with its own
            // tokenizer instead of using the generous estimates.
            var overhead = LongLectures.overheadTokens
            var imageTokens = LongLectures.tokensPerImage
            var charactersPerToken = 3.0
            let isFree = configuration.provider == .apple
            if isFree {
                let sample = (transcript.map(\.text) + documents.map(\.text)).joined(separator: " ")
                if let measured = await AppleIntelligence.charactersPerToken(sample: sample) {
                    charactersPerToken = measured
                }
                if let instructions = try? await AppleIntelligence.tokens(in: FileToAI.systemPrompt(detail: detail)) {
                    overhead = instructions + 600  // the lecture header and part instructions
                }
                if let first = sentFrames.first, let image = try? await AppleIntelligence.tokens(forImage: first.jpeg) {
                    imageTokens = image + 16
                }
            }
            // The term list goes with every request, so it counts as overhead.
            if !slideTerms.isEmpty {
                overhead += LongLectures.tokens(in: FileToAI.slideTermsText(slideTerms))
            }

            var text = ""
            let imageLimit = settings.stored.maxFrames
            func makePlan() -> LongLectures.Plan {
                func planned() -> LongLectures.Plan {
                    LongLectures.plan(
                        transcript: transcript, frameTimes: sentFrames.map(\.seconds), documents: documents,
                        budget: budget, overhead: overhead, imageTokens: imageTokens,
                        frameTokens: Self.frameTokens(slideTexts, imageTokens: imageTokens, charactersPerToken: charactersPerToken),
                        charactersPerToken: charactersPerToken
                    )
                }
                // More slides than the image limit: the plan is made with the `imageLimit` most visual slides
                // of the whole lecture as images and the rest as text (`mixedSlides`), so images add a bounded
                // amount. Then each request with room left gets more images, up to the limit per request.
                // The requests are fixed before those are added, so they never add requests.
                var plan = planned()
                guard plan.needsSplitting, let current = slideTexts, !allAsText, sentFrames.count > imageLimit,
                      let analyses = slideAnalyses, analyses.count == sentFrames.count else { return plan }
                let tokens = Self.frameTokens(current, imageTokens: imageTokens, charactersPerToken: charactersPerToken) ?? []
                let choice = LongLectures.imagesThatFit(
                    plan: plan, transcript: transcript, frameTokens: tokens, isImage: current.map { $0 == nil },
                    imageTokens: imageTokens, visualScores: analyses.map(\.visualScore), limit: imageLimit,
                    charactersPerToken: charactersPerToken
                )
                slideTexts = zip(current, choice.asImage).map { text, isImage in isImage ? nil : text }
                plan.estimatedTokens += choice.addedTokens
                return plan
            }
            var plan = makePlan()
            // Reading the slides can take a while; a request stopped meanwhile goes no further.
            try Task.checkCancellation()
            // Ask before several requests to a paid or rate-limited service. Apple Intelligence is free
            // and on the device, so it just goes ahead.
            if planOnly {
                phase = .awaitingSplitApproval(SplitProposal(
                    detail: detail, model: configuration.model, parts: plan.sections.count,
                    requests: plan.needsSplitting ? plan.sections.count + 1 : 1,
                    estimatedTokens: plan.estimatedTokens, contextTokens: context
                ))
                return
            }
            if plan.needsSplitting, !isFree, !splitApproved, !settings.stored.splitWithoutAsking {
                phase = .awaitingSplitApproval(SplitProposal(
                    detail: detail, model: configuration.model, parts: plan.sections.count,
                    requests: plan.sections.count + 1, estimatedTokens: plan.estimatedTokens, contextTokens: context
                ))
                return
            }

            // The size estimates can still be off for a model's own tokenizer. If a request overflows
            // the window, split the lecture into smaller parts and start again.
            var shrinks = 0
            while true {
                isSendingSlidesAsText = allAsText
                let slides = SlideInput(frames: sentFrames, terms: slideTerms, texts: slideTexts)
                do {
                    text = try await write(plan, slides: slides, detail: detail, configuration: configuration)
                    break
                } catch AppleIntelligence.Failure.tooLong where shrinks < 3 {
                    shrinks += 1
                    budget = max(plan.overhead + 500, budget * 2 / 3)
                } catch where !allAsText && !sentFrames.isEmpty && FileToAI.isImageRejection(error) {
                    // The provider didn't say whether the model sees images, and it doesn't.
                    slideTexts = await currentSlidesAsText(describe: settings.stored.describeSlides)
                    allAsText = true
                }
                if !allAsText, sentFrames.count > imageLimit {
                    // Start again from the lecture-wide choice; makePlan spreads the images over the new sections.
                    slideTexts = await mixedSlides(imageLimit: imageLimit)
                }
                try Task.checkCancellation()
                plan = makePlan()
                liveNotes = ""
            }
            // A stream that is stopped ends quietly, without an error, so check: notes cut short by a
            // stop must never be saved as finished.
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileToAI.Failure.empty }
            // A lecture without materials never gets a "From the materials" section (small models add one anyway).
            if !documents.contains(where: { !$0.text.isEmpty }) {
                text = FileToAI.removingEmptyMaterialsSection(from: text)
            }
            var version = NoteVersion(detail: detail, text: text, model: configuration.model, writtenAt: Date())
            version.parts = plan.needsSplitting ? plan.sections.count : nil
            version.slidesAsText = allAsText ? true : nil
            versions = NoteVersion.ordered(versions.filter { $0.detail != detail } + [version])
            phase = .done
            if let history, let savedID {
                history.attempt { try history.saveNotes(version, for: savedID) }
            }
        } catch {
            if !Task.isCancelled { failedDetail = detail }
            throw error
        }
    }

    /// What goes into the prompt about the slides.
    private struct SlideInput {
        var frames: [LectureFrame]
        var terms: [String]
        /// Per frame: text to send in place of the image, or `nil` to send the image. `nil` for the whole
        /// list sends every slide as an image.
        var texts: [String?]?

        func texts(for range: Range<Int>) -> [String?]? { texts.map { Array($0[range]) } }
    }

    /// Each frame's size for planning: its text when sent as text, otherwise an image.
    nonisolated static func frameTokens(_ texts: [String?]?, imageTokens: Int, charactersPerToken: Double) -> [Int]? {
        texts?.map { text in
            text.map { LongLectures.tokens(in: $0, charactersPerToken: charactersPerToken) + 16 } ?? imageTokens
        }
    }

    /// Reads every frame once (text and picture content) and keeps it for the rest of the session.
    private func analyzeSlidesIfNeeded() async {
        guard slideAnalyses?.count != frames.count, !frames.isEmpty else { return }
        let read = await VideoToFrames.analyze(frames)
        // A cancelled read is incomplete; read again next time.
        if !Task.isCancelled { slideAnalyses = read }
    }

    /// Words on the slides that the transcript never contains (see `FileToAI.slideTerms`).
    private func currentSlideTerms() async -> [String] {
        guard !frames.isEmpty, !transcript.isEmpty else { return [] }
        await analyzeSlidesIfNeeded()
        return FileToAI.slideTerms(slideText: slideAnalyses?.map(\.text) ?? [], transcript: transcript)
    }

    /// For a model that sees images but can't take them all: the slides with the most pictures as images
    /// (nil), the rest as their text.
    private func mixedSlides(imageLimit: Int) async -> [String?] {
        await analyzeSlidesIfNeeded()
        let analyses = slideAnalyses ?? frames.map { _ in FrameAnalysis(text: "", visualScore: 0) }
        let asImage = VideoToFrames.imageChoice(visualScores: analyses.map(\.visualScore), limit: imageLimit)
        return zip(analyses, asImage).map { analysis, isImage in
            isImage ? nil : FileToAI.slideAsText(recognized: analysis.text, description: nil)
        }
    }

    /// Every frame as text, for a model that can't see images: the words read from it, plus a short
    /// description of its visuals when Apple Intelligence is available to write one (free, on device).
    private func currentSlidesAsText(describe: Bool = true) async -> [String?] {
        await analyzeSlidesIfNeeded()
        if describe, slideDescriptions == nil {
            var descriptions: [String] = []
            for (index, frame) in frames.enumerated() {
                if Task.isCancelled { break }
                slideDescriptionProgress = PartProgress(step: index + 1, total: frames.count)
                // A slide the model declines or fails on still has its text.
                descriptions.append(await describeSlide(frame.jpeg) ?? "")
            }
            slideDescriptionProgress = nil
            if !Task.isCancelled { slideDescriptions = descriptions }
        }
        let recognized = slideAnalyses?.map(\.text) ?? Array(repeating: "", count: frames.count)
        return frames.indices.map { index in
            FileToAI.slideAsText(
                recognized: index < recognized.count ? recognized[index] : "",
                description: describe ? slideDescriptions.flatMap { index < $0.count ? $0[index] : nil } : nil
            )
        }
    }

    /// One request if the lecture fits, otherwise the parts and the combining.
    private func write(
        _ plan: LongLectures.Plan, slides: SlideInput, detail: NoteDetail, configuration: AIConfiguration
    ) async throws -> String {
        if plan.needsSplitting {
            return try await writeInParts(plan, slides: slides, detail: detail, configuration: configuration)
        }
        let stream = FileToAI.summarize(
            title: title,
            transcript: transcript,
            frames: slides.frames,
            lectureParts: parts,
            documents: documents,
            slideTerms: slides.terms,
            slideTexts: slides.texts,
            detail: detail,
            with: configuration
        )
        liveNotes = ""
        for try await chunk in stream {
            liveNotes += chunk
        }
        return liveNotes
    }

    /// Writes notes for each section of a long lecture, then combines them (see `LongLectures`).
    private func writeInParts(
        _ plan: LongLectures.Plan, slides: SlideInput, detail: NoteDetail, configuration: AIConfiguration
    ) async throws -> String {
        let system = FileToAI.systemPrompt(detail: detail)
        let total = plan.sections.count + 1
        var partNotes: [String] = []

        // Brief levels have a length for the whole lecture; each part gets its share, so N parts don't
        // add up to N summaries.
        let lectureMinutes = (transcript.last?.seconds ?? slides.frames.last?.seconds ?? 0) / 60
        let target = LongLectures.targetWords(detail, lectureMinutes: lectureMinutes)
        let partCount = plan.sections.count
        for (index, section) in plan.sections.enumerated() {
            partProgress = PartProgress(step: index + 1, total: total)
            let instructions = LongLectures.sectionInstructions(
                index: index, count: plan.sections.count, section: section,
                transcript: transcript, frameTimes: slides.frames.map(\.seconds),
                wordLimit: target.map { LongLectures.shareOfWords($0, parts: 1, of: partCount) }
            )
            let prompt = [FileToAI.Part.text(instructions)] + FileToAI.promptParts(
                title: title,
                transcript: Array(transcript[section.transcript]),
                frames: Array(slides.frames[section.frames]),
                lectureParts: parts,
                documents: section.documents,
                slideTerms: slides.terms,
                slideTexts: slides.texts(for: section.frames),
                isSection: true
            )
            var notes = ""
            // The finished parts are joined once per part, not again for every chunk that arrives.
            let finished = partNotes.isEmpty ? "" : LongLectures.joined(partNotes: partNotes, takeaways: nil) + "\n\n---\n\n"
            for try await chunk in FileToAI.stream(prompt, system: system, with: configuration) {
                notes += chunk
                liveNotes = finished + notes
            }
            try Task.checkCancellation()
            partNotes.append(notes)
        }

        // Combine. Brief levels are rewritten into one set of notes; detailed levels keep the parts as
        // written and get a Key takeaways section. Notes too long to send back at once are first merged a
        // few parts at a time, in rounds, until they fit.
        partProgress = PartProgress(step: total, total: total)
        let rewrite = LongLectures.combinesByRewriting(detail)
        var notes = partNotes
        // How many of the original parts each note covers, for its share of the length.
        var spans = partNotes.map { _ in 1 }
        // Detailed and Complete notes are kept as written; rounds only shrink a copy for the takeaways.
        let condenseLevel: NoteDetail = rewrite ? detail : .keyPoints
        let roundTarget = LongLectures.targetWords(condenseLevel, lectureMinutes: lectureMinutes)
        func finalRequest(_ notes: [String]) -> String {
            rewrite ? LongLectures.combineRequest(partNotes: notes, detail: detail, wordLimit: target)
                    : LongLectures.takeawaysRequest(partNotes: notes)
        }
        func ask(_ request: String, level: NoteDetail) async throws -> String {
            var result = ""
            for try await chunk in FileToAI.stream([.text(request)], system: FileToAI.systemPrompt(detail: level), with: configuration) {
                result += chunk
            }
            try Task.checkCancellation()
            return result
        }

        // Merge a few at a time until everything fits one final request. When nothing can be merged (each
        // note is too long to share a request), shorten each note to its share instead. The number of rounds
        // is bounded; brief notes are never pasted together whole.
        var rounds = 0
        while notes.count > 1, rounds < 8,
              !LongLectures.fits(finalRequest(notes), budget: plan.budget, overhead: plan.overhead) {
            rounds += 1
            let groups = LongLectures.batches(notes, budget: plan.budget, overhead: plan.overhead)
            var merged: [String] = [], mergedSpans: [Int] = []
            var start = 0
            if groups.contains(where: { $0.count > 1 }) {
                for group in groups {
                    let span = spans[start..<(start + group.count)].reduce(0, +)
                    start += group.count
                    if group.count == 1 { merged.append(group[0]); mergedSpans.append(span); continue }
                    let limit = roundTarget.map { LongLectures.shareOfWords($0, parts: span, of: partCount) }
                    let request = LongLectures.combineRequest(partNotes: group, detail: condenseLevel, isFinal: false, wordLimit: limit)
                    merged.append(try await ask(request, level: condenseLevel))
                    mergedSpans.append(span)
                }
            } else {
                guard let roundTarget else { break }
                for (note, span) in zip(notes, spans) {
                    let limit = LongLectures.shareOfWords(roundTarget, parts: span, of: partCount)
                    merged.append(try await ask(LongLectures.shortenRequest(note, wordLimit: limit), level: condenseLevel))
                    mergedSpans.append(span)
                }
            }
            notes = merged
            spans = mergedSpans
        }

        let request = finalRequest(notes)
        guard LongLectures.fits(request, budget: plan.budget, overhead: plan.overhead) else {
            // Still too long after every round: brief levels give the shortened notes in order (each already
            // cut to its share), Detailed and Complete their parts as written without takeaways.
            return rewrite ? LongLectures.joined(partNotes: notes, takeaways: nil)
                           : LongLectures.joined(partNotes: partNotes, takeaways: nil)
        }
        var combined = ""
        for try await chunk in FileToAI.stream([.text(request)], system: system, with: configuration) {
            combined += chunk
            liveNotes = rewrite ? combined : LongLectures.joined(partNotes: partNotes, takeaways: combined)
        }
        return rewrite ? combined : LongLectures.joined(partNotes: partNotes, takeaways: combined)
    }

    private func saveToHistory() {
        guard let history, savedID == nil else { return }
        history.attempt {
            savedID = try history.save(
                title: title, transcript: transcript, frames: frames,
                distinctFrameCount: distinctFrameCount, parts: parts, documents: documents
            ).id
        }
    }
}
