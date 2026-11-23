import Foundation

/// Writing notes for lectures too long for the model's context window: finding the window, estimating
/// a lecture's size, splitting it into sections that fit, and combining the sections' notes.
nonisolated enum LongLectures {
    // MARK: Sizes

    /// Rough token counts, deliberately on the high side so a plan never overflows the window.
    /// English is about 4 characters per token; counting 3 leaves room for code, symbols, and names.
    static func tokens(in text: String, charactersPerToken: Double = 3) -> Int {
        Int(Double(text.count) / charactersPerToken) + 1
    }

    /// A slide frame (at most 1280 px on the long side). Claude counts about one token per 28×28 pixels,
    /// so 1280×720 is about 1,200; 1,600 leaves margin for other providers' encoders.
    static let tokensPerImage = 1_600

    /// The system prompt, lecture header, and instructions around the content.
    static let overheadTokens = 3_000

    /// Claude's window when the Models API can't be reached. A rejected key never gets here
    /// (`ModelCatalog.check` stops first).
    static let claudeFallbackContextTokens = 200_000

    /// Window size assumed when it can't be found out.
    static let fallbackContextTokens = 32_768

    /// The largest window the app uses on its own for an Ollama model, whatever the model reports. Every
    /// token of window can cost memory on this device, but `num_ctx` is only sized to what a lecture needs,
    /// so a big window costs memory only for a lecture that fills it. Raised from 131,072 on 2026-11-12
    /// for Nemotron 3 (256K native). A value in the Context window setting is used as is.
    static let maxLocalContextTokens = 262_144

    /// Tokens kept free in the window for the notes themselves.
    static func outputReserve(provider: AIProvider, contextTokens: Int) -> Int {
        // Claude requests set max_tokens to 64,000; local and OpenAI-compatible models share one window
        // between input and output.
        // Never more than a quarter of the window: with a 32K window (the fallback when it couldn't be
        // looked up) a 64K reserve left 4,000 tokens per request, and a lecture that fits Claude in one
        // request was planned as 931 parts.
        provider == .claude ? min(FileToAI.claudeMaxTokens, contextTokens / 4) : min(16_384, contextTokens / 4)
    }

    /// How many input tokens one request can carry.
    static func inputBudget(provider: AIProvider, contextTokens: Int) -> Int {
        max(4_000, contextTokens - outputReserve(provider: provider, contextTokens: contextTokens))
    }

    // MARK: Finding the context window

    /// The context window to plan for, from what the provider reported about the model (`ModelCatalog.check`;
    /// nil when it couldn't be asked or didn't say) and the user's settings.
    /// - Claude: the reported `max_input_tokens`, else `claudeFallbackContextTokens`.
    /// - Ollama: `ollamaSetting` when it isn't 0; else the reported length capped at
    ///   `maxLocalContextTokens`; else `fallbackContextTokens`.
    /// - OpenAI-compatible: the window the server's model list gives (OpenRouter, Gemini), else the user's
    ///   setting, since most such servers have no way to say.
    static func contextWindow(
        provider: AIProvider, reported: Int?, openAICompatibleSetting: Int, ollamaSetting: Int = 0
    ) -> Int {
        let reported = reported.flatMap { $0 > 0 ? $0 : nil }
        switch provider {
        case .apple:
            return AppleIntelligence.contextSize
        case .openAICompatible:
            return reported ?? openAICompatibleSetting
        case .claude:
            return reported ?? claudeFallbackContextTokens
        case .ollama:
            if ollamaSetting > 0 { return ollamaSetting }
            return reported.map { min($0, maxLocalContextTokens) } ?? fallbackContextTokens
        }
    }

    /// The context length from an Ollama /api/show response. The key is prefixed with the model's
    /// architecture (`llama.context_length`, `gemma3.context_length`, ...), named by `general.architecture`.
    static func ollamaContextLength(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any]
        else { return nil }
        if let architecture = info["general.architecture"] as? String,
           let length = info["\(architecture).context_length"] as? Int {
            return length
        }
        return info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
    }

    // MARK: Images that fit

    /// More images where a plan has room: within each section, slides still sent as text become images,
    /// most visual first, while the section stays within the budget and has fewer than `limit` images.
    /// The sections never change, so this can't add requests. (An earlier version chose up to `limit`
    /// images per section first and planned after; each new section brought more images and more
    /// sections, so 653 slides with a 32K window were planned as 931 requests.)
    /// `frameTokens` and `isImage` describe the plan as made; returns the new flags and the added tokens.
    static func imagesThatFit(
        plan: Plan, transcript: [TranscriptSegment], frameTokens: [Int], isImage: [Bool], imageTokens: Int,
        visualScores: [Double], limit: Int, charactersPerToken: Double = 3
    ) -> (asImage: [Bool], addedTokens: Int) {
        var asImage = isImage
        var added = 0
        guard frameTokens.count == visualScores.count, isImage.count == frameTokens.count else { return (asImage, 0) }
        for section in plan.sections {
            let frames = section.frames.clamped(to: 0..<frameTokens.count)
            var used = plan.overhead
            used += section.transcript.clamped(to: 0..<transcript.count).reduce(0) {
                $0 + tokens(in: transcript[$1].text, charactersPerToken: charactersPerToken) + 4
            }
            used += frames.reduce(0) { $0 + frameTokens[$1] }
            used += section.documents.reduce(0) { $0 + tokens(in: $1.text, charactersPerToken: charactersPerToken) + 20 }
            var spare = plan.budget - used
            var count = frames.count { isImage[$0] }
            // Most visual first; on a tie, the earlier slide.
            let ranked = frames.filter { !isImage[$0] }
                .sorted { visualScores[$0] != visualScores[$1] ? visualScores[$0] > visualScores[$1] : $0 < $1 }
            for index in ranked where count < limit {
                let extra = imageTokens - frameTokens[index]
                guard extra <= spare else { continue }
                asImage[index] = true
                spare -= extra
                added += extra
                count += 1
            }
        }
        return (asImage, added)
    }

    // MARK: Planning

    /// How a lecture's notes will be written: one section means one ordinary request.
    struct Plan: Equatable, Sendable {
        struct Section: Equatable, Sendable {
            /// Indices into the lecture's transcript and frames, which are both in time order.
            var transcript: Range<Int>
            var frames: Range<Int>
            var documents: [LectureDocument]

            var isMaterialsOnly: Bool { transcript.isEmpty && frames.isEmpty }
        }

        var sections: [Section]
        /// The whole lecture as one request.
        var estimatedTokens: Int
        /// What one request can carry with this model.
        var budget: Int
        /// Tokens set aside in each request for the instructions around the content.
        var overhead: Int = LongLectures.overheadTokens

        var needsSplitting: Bool { sections.count > 1 }
    }

    /// Splits a lecture into sections that each fit `budget` input tokens. The transcript and slides are
    /// split by time. Materials are added to every section when they're small (a quarter of the budget
    /// or less); otherwise they become sections of their own, split by paragraph where needed.
    /// `overhead` and `imageTokens` default to generous estimates; Apple Intelligence passes amounts
    /// measured with its own tokenizer, because its window is too small to waste.
    static func plan(
        transcript: [TranscriptSegment],
        frameTimes: [Double],
        documents: [LectureDocument],
        budget: Int,
        overhead: Int = overheadTokens,
        imageTokens: Int = tokensPerImage,
        frameTokens: [Int]? = nil,
        charactersPerToken: Double = 3
    ) -> Plan {
        // Each frame's size: an image, or (for slides sent as text) its own text.
        let frameTokens = frameTokens.flatMap { $0.count == frameTimes.count ? $0 : nil }
            ?? frameTimes.map { _ in imageTokens }
        let documents = documents.filter { !$0.text.isEmpty }
        let segmentTokens = transcript.map { tokens(in: $0.text, charactersPerToken: charactersPerToken) + 4 }
        let documentTokens = documents.reduce(0) { $0 + tokens(in: $1.text, charactersPerToken: charactersPerToken) + 20 }
        let timelineTokens = segmentTokens.reduce(0, +) + frameTokens.reduce(0, +)
        let total = overhead + timelineTokens + documentTokens
        let everything = Plan.Section(transcript: 0..<transcript.count, frames: 0..<frameTimes.count, documents: documents)

        if total <= budget {
            return Plan(sections: [everything], estimatedTokens: total, budget: budget, overhead: overhead)
        }

        let hasTimeline = !transcript.isEmpty || !frameTimes.isEmpty
        let materialsRideAlong = hasTimeline && documentTokens <= budget / 4
        let timelineBudget = budget - overhead - (materialsRideAlong ? documentTokens : 0)

        var sections: [Plan.Section] = []
        if hasTimeline {
            sections = timelineSections(
                segmentTokens: segmentTokens, segmentTimes: transcript.map(\.seconds),
                frameTimes: frameTimes, frameTokens: frameTokens, budget: timelineBudget
            )
            if materialsRideAlong {
                for index in sections.indices { sections[index].documents = documents }
            }
        }
        if !materialsRideAlong {
            sections += materialSections(documents, budget: budget - overhead, charactersPerToken: charactersPerToken)
        }
        return Plan(sections: sections, estimatedTokens: total, budget: budget, overhead: overhead)
    }

    /// Walks the transcript and frames in time order, starting a new section when the next item wouldn't fit.
    private static func timelineSections(
        segmentTokens: [Int], segmentTimes: [Double], frameTimes: [Double], frameTokens: [Int], budget: Int
    ) -> [Plan.Section] {
        var sections: [Plan.Section] = []
        var segmentStart = 0, frameStart = 0
        var nextSegment = 0, nextFrame = 0
        var used = 0

        func close() {
            if nextSegment > segmentStart || nextFrame > frameStart {
                sections.append(Plan.Section(transcript: segmentStart..<nextSegment, frames: frameStart..<nextFrame, documents: []))
            }
            segmentStart = nextSegment
            frameStart = nextFrame
            used = 0
        }

        while nextSegment < segmentTimes.count || nextFrame < frameTimes.count {
            // Take whichever comes first in the lecture; a frame shown at the same moment goes first.
            let takeFrame = nextFrame < frameTimes.count
                && (nextSegment >= segmentTimes.count || frameTimes[nextFrame] <= segmentTimes[nextSegment])
            let cost = takeFrame ? frameTokens[nextFrame] : segmentTokens[nextSegment]
            if used > 0, used + cost > budget { close() }
            if takeFrame { nextFrame += 1 } else { nextSegment += 1 }
            used += cost
        }
        close()
        return sections
    }

    /// One or more sections per document, splitting long documents at paragraph breaks.
    private static func materialSections(
        _ documents: [LectureDocument], budget: Int, charactersPerToken: Double
    ) -> [Plan.Section] {
        var sections: [Plan.Section] = []
        var batch: [LectureDocument] = []
        var used = 0

        func flush() {
            if !batch.isEmpty { sections.append(Plan.Section(transcript: 0..<0, frames: 0..<0, documents: batch)) }
            batch = []
            used = 0
        }

        for document in documents {
            let pieces = split(document.text, maxTokens: budget - 20, charactersPerToken: charactersPerToken)
            for (index, piece) in pieces.enumerated() {
                var part = document
                part.text = piece
                if pieces.count > 1 { part.name = "\(document.name) (part \(index + 1) of \(pieces.count))" }
                let cost = tokens(in: piece, charactersPerToken: charactersPerToken) + 20
                if used > 0, used + cost > budget { flush() }
                batch.append(part)
                used += cost
            }
        }
        flush()
        return sections
    }

    /// Splits text into pieces of at most `maxTokens`, at paragraph breaks where possible.
    static func split(_ text: String, maxTokens: Int, charactersPerToken: Double = 3) -> [String] {
        guard tokens(in: text, charactersPerToken: charactersPerToken) > maxTokens else { return [text] }
        let maxCharacters = max(1, Int(Double(maxTokens - 1) * charactersPerToken))
        var pieces: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            var paragraph = paragraph
            // A paragraph longer than a whole piece is cut where it must be.
            while paragraph.count > maxCharacters {
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(String(paragraph.prefix(maxCharacters)))
                paragraph = String(paragraph.dropFirst(maxCharacters))
            }
            let joined = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if joined.count > maxCharacters {
                pieces.append(current)
                current = paragraph
            } else {
                current = joined
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: Length at brief levels

    /// About how many words the whole lecture's notes should come to at a brief level; nil for Detailed and
    /// Complete, whose length follows the lecture. Key points reads in two or three minutes; Concise grows
    /// with the lecture (about 15 words a minute) within limits. Without a target, a lecture written in N
    /// parts got N full summaries, and small-window models (Apple Intelligence) produced Key points longer
    /// than Detailed.
    static func targetWords(_ detail: NoteDetail, lectureMinutes: Double) -> Int? {
        switch detail {
        case .keyPoints: 500
        case .concise: min(3_000, max(800, Int(lectureMinutes * 15)))
        case .detailed, .complete: nil
        }
    }

    /// One part's share of `total` words when the lecture is in `parts` parts; never under 60, so a part
    /// can still name its main ideas.
    static func shareOfWords(_ total: Int, parts: Int, of allParts: Int) -> Int {
        max(60, total * parts / max(allParts, 1))
    }

    // MARK: Prompts

    /// Added before a section's content.
    static func sectionInstructions(
        index: Int, count: Int, section: Plan.Section, transcript: [TranscriptSegment], frameTimes: [Double],
        wordLimit: Int? = nil
    ) -> String {
        let span: String
        if section.isMaterialsOnly {
            span = "This part contains only some of the supporting materials attached to the lecture."
        } else {
            let times = section.transcript.map { transcript[$0].seconds } + section.frames.map { frameTimes[$0] }
            let start = times.min() ?? 0, end = times.max() ?? 0
            span = "This part covers the lecture from [\(timestamp(start))] to about [\(timestamp(end))]."
        }
        return """
            This lecture is too long to send at once, so it is being sent in \(count) parts. This is part \
            \(index + 1) of \(count). \(span) Write notes for this part only, at the level of detail requested. \
            Don't write an introduction or a key takeaways list: the parts will be put together afterwards and \
            those are added then.\(wordLimit.map { " Keep this part's notes to at most about \($0) words: it is only one of \(count) parts of a short summary." } ?? "")
            """
    }

    /// How the parts' notes become one set of notes. Brief levels are rewritten into one; detailed levels
    /// are kept as written and joined, because rewriting them would run into the model's output limit,
    /// and only a closing summary is asked for.
    static func combinesByRewriting(_ detail: NoteDetail) -> Bool {
        detail == .keyPoints || detail == .concise
    }

    /// The request that merges parts' notes. `isFinal` is false for an in-between round, when the
    /// notes are too long to merge all at once and are merged a few parts at a time first.
    static func combineRequest(
        partNotes: [String], detail: NoteDetail, isFinal: Bool = true, wordLimit: Int? = nil
    ) -> String {
        let limit = wordLimit.map { " Use at most about \($0) words in total, keeping the most important ideas." } ?? ""
        if isFinal {
            return """
                Below are notes written separately for the \(partNotes.count) parts of one lecture, in order. Combine \
                them into one set of notes at the level of detail requested: follow the lecture's order, merge topics \
                that were split across parts, remove repetition, and end with a short list of key takeaways. Use only \
                what is in these notes.\(limit)

                \(numbered(partNotes))
                """
        }
        return """
            Below are notes for \(partNotes.count) consecutive parts of a longer lecture, in order. Merge them into \
            one shorter set of notes for these parts at the level of detail requested: keep their order, merge \
            topics split across parts, and remove repetition. Don't add an introduction or key takeaways; other \
            parts of the lecture come before or after these. Use only what is in these notes.\(limit)

            \(numbered(partNotes))
            """
    }

    /// Groups consecutive notes so each group's merge request fits `budget`. A note too long to share a
    /// request goes in a group of its own.
    static func batches(_ notes: [String], budget: Int, overhead: Int) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var used = 0
        for note in notes {
            let cost = tokens(in: note) + 30
            if !current.isEmpty, overhead + used + cost > budget {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(note)
            used += cost
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Whether a request with this text fits.
    static func fits(_ request: String, budget: Int, overhead: Int) -> Bool {
        tokens(in: request) + overhead <= budget
    }

    /// Shortens one set of notes that is too long to merge with any other.
    static func shortenRequest(_ notes: String, wordLimit: Int) -> String {
        """
        Below are notes for part of a longer lecture. Shorten them to at most about \(wordLimit) words, keeping \
        the most important ideas, definitions and formulas in the same order. Don't add anything that isn't in \
        them, and don't add an introduction or key takeaways.

        \(notes)
        """
    }

    static func takeawaysRequest(partNotes: [String]) -> String {
        """
        Below are the notes for a long lecture, written in \(partNotes.count) parts. Write only a section headed \
        "## Key takeaways" for the whole lecture: 5 to 10 bullet points covering the most important ideas. \
        Don't repeat the notes.

        \(numbered(partNotes))
        """
    }

    /// Detailed and Complete notes: the parts in order, then the takeaways if there are any.
    static func joined(partNotes: [String], takeaways: String?) -> String {
        let parts = partNotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = parts.joined(separator: "\n\n---\n\n")
        if let takeaways = takeaways?.trimmingCharacters(in: .whitespacesAndNewlines), !takeaways.isEmpty {
            text += "\n\n" + takeaways
        }
        return text
    }

    private static func numbered(_ partNotes: [String]) -> String {
        partNotes.enumerated()
            .map { "=== Part \($0.offset + 1) ===\n\($0.element)" }
            .joined(separator: "\n\n")
    }
}
