import Foundation

nonisolated enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple, ollama, claude, openAICompatible

    var id: Self { self }

    var label: String {
        switch self {
        case .apple: "Apple Intelligence (free)"
        case .ollama: "Ollama (local, free)"
        case .claude: "Claude"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

/// How much the notes should say. Each level swaps the part of the system prompt that sets length and depth.
nonisolated enum NoteDetail: Int, CaseIterable, Identifiable, Codable, Sendable {
    case keyPoints, concise, detailed, complete

    var id: Self { self }

    var label: String {
        switch self {
        case .keyPoints: "Key points"
        case .concise: "Concise"
        case .detailed: "Detailed"
        case .complete: "Complete"
        }
    }

    /// Shown under the slider in Settings.
    var summary: String {
        switch self {
        case .keyPoints: "A short summary of the main ideas. No derivations or worked examples."
        case .concise: "Every topic as short bullet points. Examples are cut to a line or two."
        case .detailed: "Clear explanations of every topic, with the key steps and examples, minus repetition and tangents."
        case .complete: "Everything the lecture covers, every step and example. Long and dense."
        }
    }

    /// The instructions that set how much the model writes.
    var instructions: String {
        switch self {
        case .keyPoints:
            """
            Write a short summary of the lecture that can be read in two or three minutes: the main ideas as \
            bullet points under a few headings, each in one or two sentences. Include only the definitions and \
            formulas that are central to the lecture. Leave out derivations, worked examples, and side remarks. \
            If the professor gives logistics (deadlines, exam hints), mention them.
            """
        case .concise:
            """
            Write concise study notes that cover every topic in the lecture's order, under headings by topic. \
            For each topic give the essential idea, the key definitions, and the important formulas as short \
            bullet points rather than paragraphs. Summarize derivations and worked examples in a line or two \
            instead of repeating every step. If the professor mentions logistics (deadlines, exam hints, \
            what they stress as important), include them. End with a short list of key takeaways.
            """
        case .detailed:
            """
            Write clear study notes that cover every topic in the lecture's order, under headings by topic. \
            Explain each concept in plain language with its definitions and formulas, include the important \
            steps of derivations, and keep one worked example per idea where the lecture gives one. Leave out \
            repetition, tangents, and filler. Keep it easy to read: short paragraphs and bullet points, not \
            every sentence packed with detail. If the professor mentions logistics (deadlines, exam hints, \
            what they stress as important), include them. End with a short list of key takeaways.
            """
        case .complete:
            """
            Write complete study notes covering everything taught: every concept, definition, formula, derivation \
            step, and worked example, plus any logistics the professor mentions (deadlines, exam hints, what they \
            stress as important). Follow the lecture's order, organized under headings by topic. Explain each idea \
            fully enough that the student could learn the material from the notes alone; thoroughness matters more \
            than brevity. End with a short list of key takeaways.
            """
        }
    }
}

/// A service that accepts requests in OpenAI's format (`POST /chat/completions`, `GET /models`), so
/// one implementation covers them all. Each keeps its own API key and model. "Other" is any server not
/// listed, at an address the user enters; adding a service here adds it to the Provider menu.
nonisolated struct OpenAIService: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Nil for "Other", whose address is the user's `openAIURL` setting.
    let baseURL: String?
    /// Hosted services need a key; local servers usually don't.
    let needsKey: Bool
    /// The variable read from the Debug-only Secrets.env when no key is typed into Settings.
    let devKeyName: String
    /// Always in the Provider menu. The others are added from "Add Provider…" (a judgment call about
    /// what most people use, not usage data; change it here).
    let isFeatured: Bool
    /// One line for the Add Provider list.
    let blurb: String

    // Addresses checked against each service's own documentation on 2026-11-11:
    // OpenAI developers.openai.com (models/list); Gemini ai.google.dev/gemini-api/docs/openai;
    // DeepSeek api-docs.deepseek.com/api/list-models; OpenRouter its API reference; LM Studio
    // lmstudio.ai/docs/developer/openai-compat/models.
    static let openAI = OpenAIService(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true, devKeyName: "OPENAI_API_KEY", isFeatured: true, blurb: "OpenAI's models. Needs an API key.")
    static let gemini = OpenAIService(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", needsKey: true, devKeyName: "GEMINI_API_KEY", isFeatured: true, blurb: "Google's Gemini models. Needs an API key.")
    static let deepSeek = OpenAIService(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", needsKey: true, devKeyName: "DEEPSEEK_API_KEY", isFeatured: false, blurb: "DeepSeek's models. Needs an API key.")
    static let openRouter = OpenAIService(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true, devKeyName: "OPENROUTER_API_KEY", isFeatured: false, blurb: "Models from many companies with one OpenRouter key.")
    static let lmStudio = OpenAIService(id: "lmstudio", name: "LM Studio (local)", baseURL: "http://localhost:1234/v1", needsKey: false, devKeyName: "LMSTUDIO_API_KEY", isFeatured: false, blurb: "Models running in the LM Studio app on this computer. Free.")
    static let custom = OpenAIService(id: "custom", name: "Other (OpenAI-compatible)", baseURL: nil, needsKey: false, devKeyName: "OPENAI_COMPATIBLE_API_KEY", isFeatured: false, blurb: "Any other service or server that accepts OpenAI-style requests, at an address you enter.")

    static let all: [OpenAIService] = [.openAI, .gemini, .deepSeek, .openRouter, .lmStudio, .custom]

    /// The services shown in the Provider menu: the featured ones, any the user added, and the current
    /// one even if it was neither (so the menu always shows what's chosen).
    static func menuServices(added: [String], current: String?) -> [OpenAIService] {
        all.filter { $0.isFeatured || added.contains($0.id) || $0.id == current }
    }

    /// The services that can be added from "Add Provider…".
    static var addable: [OpenAIService] { all.filter { !$0.isFeatured } }

    static func with(id: String) -> OpenAIService {
        all.first { $0.id == id } ?? .custom
    }

    /// Where the key is kept in the Keychain. "Other" keeps the account used before services existed,
    /// so a key saved by an older version is still found.
    var keychainAccount: String { self == .custom ? "openai-compatible" : "service.\(id)" }
}

/// One file of a lecture that was recorded as several files. `startSeconds` is where the file begins on
/// the lecture's combined timeline.
nonisolated struct LecturePart: Codable, Sendable, Equatable {
    var name: String
    var startSeconds: Double
}

nonisolated struct AIConfiguration: Sendable {
    var provider: AIProvider
    var baseURL: URL
    var model: String
    var apiKey: String
    /// The model's context window in tokens, once known (see `LongLectures.contextWindow`). Ollama's
    /// `num_ctx` is never set above it.
    var contextTokens: Int?
}

nonisolated func timestamp(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

/// Sends the transcript and frames to a model and streams back the lecture notes.
nonisolated enum FileToAI {
    enum Failure: LocalizedError, Equatable {
        case api(String)
        case refused
        /// HTTP 401 or 403: the key is wrong, expired, or revoked.
        case keyRejected(String)
        /// HTTP 402: the account has no credit left.
        case noCredit(String)
        /// HTTP 429: too many requests, or a usage limit reached.
        case rateLimited(String)

        var errorDescription: String? {
            switch self {
            case .api(let message): message
            case .refused: "The model declined to summarize this lecture."
            case .keyRejected(let detail):
                "The API key was rejected\(Self.quoted(detail)). It may have expired, been revoked, or been mistyped. Create a new key in your provider's console and paste it in Settings. The slides and transcript are saved, so you can write the notes again afterwards."
            case .noCredit(let detail):
                "The provider says the account is out of credit\(Self.quoted(detail)). Add credit in your provider's console, or switch to Apple Intelligence or Ollama, which are free, in Settings."
            case .rateLimited(let detail):
                "The provider is limiting requests right now\(Self.quoted(detail)). Wait a minute and try again. A long lecture written in many parts can hit this; a model with a larger context window needs fewer requests."
            }
        }

        private static func quoted(_ detail: String) -> String {
            detail.isEmpty ? "" : " (\"\(detail.prefix(200))\")"
        }

        /// The failure for an HTTP error status, with the provider's own message.
        static func forStatus(_ status: Int, detail: String) -> Failure {
            switch status {
            case 401, 403: .keyRejected(detail)
            case 402: .noCredit(detail)
            case 429: .rateLimited(detail)
            default: .api("The model server returned an error (HTTP \(status))\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }
    }

    /// Checks the API key before any planning, so a rejected key is reported as such. Without this check, a
    /// failed context-window lookup fell back to a small window and the lecture was planned as hundreds of
    /// parts. Only an explicit rejection (HTTP 401/403) throws; a network problem or a server without a
    /// model list is left to the request itself.
    static func verifyKey(_ config: AIConfiguration) async throws {
        var request: URLRequest
        switch config.provider {
        case .claude:
            request = URLRequest(url: config.baseURL.appending(path: "v1/models/\(config.model)"))
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible where !config.apiKey.isEmpty:
            request = URLRequest(url: config.baseURL.appending(path: "models"))
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization")
        default:
            return
        }
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 402, 403].contains(status) { throw Failure.forStatus(status, detail: errorDetail(in: data)) }
    }

    /// The provider's own error message from an error body (`{"error": {"message": ...}}` or `{"error": "..."}`).
    static func errorDetail(in data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String
            ?? String(decoding: data.prefix(300), as: UTF8.self)
    }

    static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]

    static func summarize(
        title: String,
        transcript: [TranscriptSegment],
        frames: [LectureFrame],
        lectureParts: [LecturePart] = [],
        documents: [LectureDocument] = [],
        slideTerms: [String] = [],
        slideTexts: [String?]? = nil,
        detail: NoteDetail,
        with config: AIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        let parts = promptParts(
            title: title, transcript: transcript, frames: frames, lectureParts: lectureParts, documents: documents,
            slideTerms: slideTerms, slideTexts: slideTexts
        )
        return stream(parts, system: systemPrompt(detail: detail), with: config)
    }

    /// Sends one request and streams back the model's text.
    static func stream(_ parts: [Part], system: String, with config: AIConfiguration) -> AsyncThrowingStream<String, Error> {
        // Apple Intelligence runs on the device through Apple's framework, not over HTTP.
        if config.provider == .apple {
            let window = config.contextTokens ?? AppleIntelligence.contextSize
            return AppleIntelligence.stream(
                parts, system: system,
                maximumTokens: LongLectures.outputReserve(provider: .apple, contextTokens: window)
            )
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try request(for: parts, config: config, system: system)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw try await failure(from: bytes, status: status)
                    }
                    for try await line in bytes.lines {
                        if let text = try parse(line, provider: config.provider) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    // MARK: Prompt

    static func systemPrompt(detail: NoteDetail) -> String {
        """
        You are helping a university student who has not watched this lecture and will study from your notes \
        instead of watching it. You are given a speech-to-text transcript with [timestamps] and, for video \
        lectures, still frames captured whenever the slide or board changed, each with its timestamp.

        \(detail.instructions)

        \(sharedInstructions)\(includesSpokenCodeGuidance ? "\n\n" + spokenCodeGuidance : "")
        """
    }

    /// Whether the prompt tells the model to turn spoken code and math into symbols. Off: on a real
    /// 89-minute lecture with Apple Intelligence (2026-11-13) two runs with it differed more than with it
    /// and without it (about 11 of 16 key facts, then a worse, 1,382-word set), and "copy the code from the
    /// slide" made it copy garbled handwriting recognition word for word. Kept as a switch for measuring.
    nonisolated(unsafe) static var includesSpokenCodeGuidance = false

    /// Removes a "From the materials" section when the lecture has no materials. The prompt says to leave it
    /// out, but Apple Intelligence wrote one ("There was nothing to write notes from") in 4 of 6 runs.
    static func removingEmptyMaterialsSection(from notes: String) -> String {
        var kept: [Substring] = []
        var skippingLevel: Int?
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let level = trimmed.prefix { $0 == "#" }.count
            let isHeading = level > 0 && trimmed.dropFirst(level).first == " "
            if let skipping = skippingLevel {
                if isHeading, level <= skipping { skippingLevel = nil } else { continue }
            }
            if isHeading, trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces).lowercased() == "from the materials" {
                skippingLevel = level
                // A rule just before the section belongs to it.
                while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.trimmingCharacters(in: .whitespaces) == "---" {
                    kept.removeLast()
                }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small models copied spoken code word for word ("B sub K", "star B plus K", "sturcher" for strchr).
    static let spokenCodeGuidance = """
        Code and math in the transcript are spoken aloud, so write them the way they are written, not the way \
        they were said: "star p" is *p, "b sub k" is b[k], "ampersand x" is &x, "p plus plus" is p++, \
        "x squared" is x², "not equals" is !=. When a slide shows the code or formula, copy it exactly from the \
        slide. Write names exactly as the slides spell them (variables, functions, keywords), including their \
        capitalization: if a slide has da and strchr, never write DA or "sturcher". State a fact about code only \
        when the transcript or slides say it; don't infer rules from a single example.
        """

    private static let sharedInstructions = """
        Use only what is in the transcript, slides, and materials you are given. Never invent deadlines, exam \
        details, slides, quotes, examples, or anything else that isn't there. Leave out any section, such as \
        logistics or "From the materials", that would have nothing real in it.

        The transcript is machine-generated, so technical terms, names, and symbols are often misheard. Use the \
        slides, the list of terms read from the slides (when given), and the surrounding context to recover \
        what was actually said, and use the correct spelling in the notes. Use the slides for content \
        the professor shows but does not read aloud. If something is unclear or missing from the source, say \
        so rather than guessing.

        The student may also attach supporting materials: slides, handouts, readings, or photos of the \
        board, given as text read from those files. Use them to get terms, names, formulas, and details \
        right and to fill in what the professor shows but doesn't say. Keep the notes centred on what the \
        lecture taught: bring in material from the files where it relates to the lecture, and put anything \
        important that the lecture didn't cover in a short final section titled "From the materials" (only \
        when materials were attached). \
        If there is no transcript (no speech was recognized in the recording), write the notes from the \
        slides and materials you are given. Only if those have no lecture content either, say briefly that \
        there was nothing to write notes from.

        Formatting: the notes are shown in a simple Markdown renderer that supports headings (#, ##, ###), \
        bullet and numbered lists, **bold**, *italic*, `inline code`, and fenced code blocks. It cannot render \
        tables or LaTeX, so write math in plain text with Unicode symbols (x² + y² = r², ∑, ∫, →).
        """

    enum Part {
        case text(String)
        case image(Data)
    }

    static func promptParts(
        title: String,
        transcript: [TranscriptSegment],
        frames: [LectureFrame],
        lectureParts: [LecturePart] = [],
        documents: [LectureDocument] = [],
        slideTerms: [String] = [],
        slideTexts: [String?]? = nil,
        isSection: Bool = false
    ) -> [Part] {
        var parts: [Part]
        if lectureParts.count > 1 {
            let list = lectureParts.enumerated()
                .map { "Part \($0.offset + 1), \"\($0.element.name)\", starts at [\(timestamp($0.element.startSeconds))]" }
                .joined(separator: "\n")
            parts = [.text("""
                Lecture: \(title)
                This lecture was recorded as \(lectureParts.count) files, joined in order into one timeline. \
                They may be parts of one class or several classes of a course (their names often say which, \
                such as a date). Write one set of notes covering all of them; when they are separate classes, \
                say which class (by its file name) each topic comes from.
                \(list)
                """)]
        } else {
            parts = [.text("Lecture file: \(title)")]
        }
        if !frames.isEmpty, let slideTexts, slideTexts.count == frames.count, slideTexts.contains(where: { $0 != nil }) {
            let textCount = slideTexts.count { $0 != nil }
            if textCount == frames.count {
                // The model can't see images, so each slide goes in as text instead.
                parts.append(.text("""
                    \(frames.count) slide and board captures from the video follow in chronological order, each \
                    with its timestamp in brackets. You cannot see them: each is given as the text read from it \
                    by text recognition and, when available, a short description of its visuals written by \
                    another model. Both can be incomplete or wrong, and diagrams and handwriting are often \
                    missed, so trust the transcript where they disagree.
                    """))
            } else {
                // More slides than images allowed: the ones with pictures are images, the rest text.
                parts.append(.text("""
                    \(frames.count) slide and board captures from the video follow in chronological order, each \
                    with its timestamp in brackets. The \(frames.count - textCount) with the most diagrams and \
                    pictures are images. The other \(textCount) are mostly text, so they are given as the text \
                    read from them by text recognition, which can contain small mistakes. Every slide counts \
                    equally, whichever way it is given.
                    """))
            }
            for (frame, text) in zip(frames, slideTexts) {
                if let text {
                    parts.append(.text("[\(timestamp(frame.seconds))]\n\(text)"))
                } else {
                    parts.append(.text("[\(timestamp(frame.seconds))]"))
                    parts.append(.image(frame.jpeg))
                }
            }
        } else if !frames.isEmpty {
            parts.append(.text("""
                \(frames.count) slide and board captures from the video follow in chronological order. \
                Each image's timestamp is given in brackets.
                """))
            for frame in frames {
                parts.append(.text("[\(timestamp(frame.seconds))]"))
                parts.append(.image(frame.jpeg))
            }
        }
        let readable = documents.filter { !$0.text.isEmpty }
        // Saying so outright stops smaller models from describing slides or materials that don't exist.
        if frames.isEmpty { parts.append(.text("No slides are included.")) }
        if readable.isEmpty { parts.append(.text("No supporting materials are included.")) }
        if !readable.isEmpty {
            let materials = readable.map { document in
                var header = "=== \(document.name) (\(document.kind.label)) ==="
                if document.wasTrimmed {
                    header += "\n[Only the first \(DocumentToText.maxCharacters) characters of this file are included.]"
                }
                return header + "\n" + document.text
            }
            parts.append(.text("Supporting materials attached by the student:\n\n" + materials.joined(separator: "\n\n")))
        }
        if !slideTerms.isEmpty, !transcript.isEmpty {
            parts.append(.text(slideTermsText(slideTerms)))
        }
        if transcript.isEmpty {
            // A section of a long lecture may just be materials; that isn't the same as having no recording.
            if !isSection { parts.append(.text(noTranscriptText(hasSlides: !frames.isEmpty, hasMaterials: !readable.isEmpty))) }
        } else {
            parts.append(.text("Transcript:\n\n" + paragraphs(from: transcript)))
        }
        return parts
    }

    /// Said in place of the transcript when there is none, pointing the model at what it does have.
    static func noTranscriptText(hasSlides: Bool, hasMaterials: Bool) -> String {
        let base = "There is no recording transcript for this lecture."
        let sources = [hasSlides ? "slides" : nil, hasMaterials ? "materials" : nil].compactMap(\.self)
        guard !sources.isEmpty else { return base }
        // Slides come from a video, so there was a recording; it just had no recognizable speech.
        let reason = hasSlides ? " No speech was recognized in the recording." : ""
        return base + reason + " Write the notes from the \(sources.joined(separator: " and ")) above."
    }

    // MARK: Slides as text

    /// One slide for a model that can't see images: the words read from it, then the description.
    static func slideAsText(recognized: String, description: String?) -> String {
        let words = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [words.isEmpty ? "Text on the slide: (none found)" : "Text on the slide:\n\(words)"]
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines.append("What the slide shows: \(description)")
        }
        return lines.joined(separator: "\n")
    }

    /// True when a provider's error says the model can't take images, so the request is worth sending
    /// again with the slides as text. Providers word this differently ("image_url is only supported by
    /// certain models", "does not support image input", "unknown variant `image_url`"), so this looks for
    /// the words they share rather than one exact message.
    static func isImageRejection(_ error: Error) -> Bool {
        guard case Failure.api(let message) = error else { return false }
        let lowered = message.lowercased()
        return ["image", "vision", "multimodal", "modalit"].contains { lowered.contains($0) }
    }

    // MARK: Slide terms

    /// The most terms sent with one lecture. About 3 tokens each, so the list stays a few hundred tokens.
    static let maxSlideTerms = 150

    /// The prompt text that introduces the slide terms.
    static func slideTermsText(_ terms: [String]) -> String {
        """
        Words read from the slides that never appear in the transcript, spelled as on the slides. Some may be \
        terms the transcript misheard; where a transcript word sounds like one of these, use this spelling. \
        Others may simply not have been said. Text recognition can make mistakes too, so ignore anything \
        that looks garbled.
        \(terms.joined(separator: ", "))
        """
    }

    /// Picks the words on the slides that the transcript never contains. Speech recognition mishears
    /// rare terms and names ("Kol Megorov" for "Kolmogorov"), and those are exactly the words that show up
    /// on a slide but nowhere in the transcript. Common words appear in both, so they drop out without a
    /// dictionary. Keeps the slide's spelling and order of first appearance.
    static func slideTerms(
        slideText: [String], transcript: [TranscriptSegment], limit: Int = maxSlideTerms
    ) -> [String] {
        let spoken = Set(transcript.flatMap { words(in: $0.text) }.flatMap(wordParts).map { $0.lowercased() })
        var seen: Set<String> = []
        var terms: [String] = []
        for word in slideText.flatMap(words) {
            guard terms.count < limit else { break }
            let parts = wordParts(word)
            let lettersOnly = word.filter(\.isLetter)
            // Short words, numbers, and page furniture are noise, not terms.
            guard lettersOnly.count >= 4 else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }
            // "Bellman-Ford" counts as spoken when the transcript has "Bellman Ford".
            if parts.allSatisfy({ spoken.contains($0.lowercased()) }) { continue }
            terms.append(word)
        }
        return terms
    }

    /// Words made of letters and digits, keeping inner hyphens and apostrophes ("Bellman-Ford", "Bézout's").
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let joiners: Set<Character> = ["-", "'", "’"]
        for character in text + " " {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if joiners.contains(character), !current.isEmpty {
                current.append(character)
            } else if !current.isEmpty {
                while let last = current.last, joiners.contains(last) { current.removeLast() }
                if !current.isEmpty { words.append(current) }
                current = ""
            }
        }
        return words
    }

    /// The pieces of a hyphenated word, and a possessive's base ("Bézout's" -> "Bézout").
    private static func wordParts(_ word: String) -> [String] {
        word.split(separator: "-").map { part in
            var piece = String(part)
            for suffix in ["'s", "’s"] where piece.lowercased().hasSuffix(suffix) {
                piece.removeLast(2)
            }
            return piece
        }.filter { !$0.isEmpty }
    }

    /// Groups segments into roughly 30-second paragraphs, each starting with its timestamp.
    static func paragraphs(from transcript: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var paragraphStart = -Double.infinity
        for segment in transcript {
            if segment.seconds - paragraphStart >= 30 {
                paragraphStart = segment.seconds
                lines.append("[\(timestamp(segment.seconds))] \(segment.text)")
            } else {
                lines[lines.count - 1] += " " + segment.text
            }
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Requests

    static func request(for parts: [Part], config: AIConfiguration, detail: NoteDetail = .detailed) throws -> URLRequest {
        try request(for: parts, config: config, system: systemPrompt(detail: detail))
    }

    static func request(for parts: [Part], config: AIConfiguration, system systemPrompt: String) throws -> URLRequest {
        let path: String
        var headers = ["content-type": "application/json"]
        let body: [String: Any]

        switch config.provider {
        case .apple:
            throw Failure.api("Apple Intelligence runs on this device and isn't sent over the network.")
        case .claude:
            path = "v1/messages"
            headers["x-api-key"] = config.apiKey
            headers["anthropic-version"] = "2026-10-21"
            var claudeBody: [String: Any] = [
                "model": config.model,
                "max_tokens": 64000,
                "stream": true,
                "output_config": ["effort": "medium"],
                "system": systemPrompt,
                "messages": [["role": "user", "content": parts.map(claudeBlock)]],
            ]
            // Haiku has no server-side refusal fallback; the other models reroute a declined request automatically.
            if !config.model.contains("haiku") {
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
                claudeBody["fallbacks"] = "default"
            }
            body = claudeBody

        case .ollama:
            path = "api/chat"
            var text: [String] = []
            var images: [String] = []
            for part in parts {
                switch part {
                case .text(let string): text.append(string)
                case .image(let data): images.append(data.base64EncodedString())
                }
            }
            let prompt = text.joined(separator: "\n")
            // Ollama silently truncates input beyond num_ctx, so size the window to fit the whole lecture.
            let estimatedTokens = prompt.count / 3 + images.count * 1000 + 6000
            body = [
                "model": config.model,
                "stream": true,
                "options": ["num_ctx": min(max(estimatedTokens, 8192), config.contextTokens ?? LongLectures.maxLocalContextTokens)],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt, "images": images],
                ],
            ]

        case .openAICompatible:
            path = "chat/completions"
            if !config.apiKey.isEmpty {
                headers["authorization"] = "Bearer \(config.apiKey)"
            }
            body = [
                "model": config.model,
                "stream": true,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": parts.map(openAIBlock)],
                ],
            ]
        }

        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.httpMethod = "POST"
        // Local models can take minutes to read a long lecture before the first token arrives.
        request.timeoutInterval = 1800
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func claudeBlock(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let string):
            ["type": "text", "text": string]
        case .image(let data):
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
        }
    }

    private static func openAIBlock(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let string):
            ["type": "text", "text": string]
        case .image(let data):
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
        }
    }

    // MARK: Responses

    private struct ClaudeEvent: Decodable {
        struct Delta: Decodable {
            let text: String?
            let stop_reason: String?
        }
        struct APIError: Decodable { let message: String }
        let type: String
        let delta: Delta?
        let error: APIError?
    }

    private struct OllamaChunk: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let error: String?
    }

    private struct OpenAIChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    /// Returns the text carried by one line of the response stream, if any.
    static func parse(_ line: String, provider: AIProvider) throws -> String? {
        let decoder = JSONDecoder()
        if provider == .ollama {
            let chunk = try decoder.decode(OllamaChunk.self, from: Data(line.utf8))
            if let error = chunk.error { throw Failure.api(error) }
            return chunk.message?.content
        }

        guard line.hasPrefix("data:") else { return nil }
        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)

        if provider == .openAICompatible {
            return (try? decoder.decode(OpenAIChunk.self, from: payload))?.choices?.first?.delta?.content
        }

        guard let event = try? decoder.decode(ClaudeEvent.self, from: payload) else { return nil }
        if let error = event.error { throw Failure.api(error.message) }
        switch event.delta?.stop_reason {
        case "refusal": throw Failure.refused
        case "max_tokens": return "\n\n*The notes were cut off because the model reached its output limit.*"
        default: return event.delta?.text
        }
    }

    private static func failure(from bytes: URLSession.AsyncBytes, status: Int) async throws -> Failure {
        var body = ""
        for try await line in bytes.lines { body += line }
        return Failure.forStatus(status, detail: errorDetail(in: Data(body.utf8)))
    }
}

/// A model a provider offers, as listed by the provider itself.
nonisolated struct AvailableModel: Identifiable, Equatable, Sendable {
    var id: String
    /// A friendly name, when the provider gives one ("Claude Opus 5.5").
    var displayName: String?
    /// The context window, when the provider says.
    var contextTokens: Int?
    /// The longest reply one request can produce, when the provider says.
    var maxOutputTokens: Int? = nil
    /// Whether the model can see images (the slides), when the provider says.
    var acceptsImages: Bool? = nil
    /// A short description from the provider (OpenRouter), or the model's size (Ollama).
    var summary: String? = nil

    var label: String { displayName ?? id }
}

/// Asks each provider which models it offers:
/// - Claude: `GET /v1/models`, every page (`after_id`, `has_more`, `last_id`), newest first as returned.
/// - Ollama: `GET /api/tags`, the models pulled on that machine.
/// - OpenAI-compatible: `GET {base URL}/models`, the de facto standard list (`data[].id`). Most servers
///   (LM Studio, OpenRouter, vLLM, ...) offer it, but not all.
nonisolated enum ModelCatalog {
    enum Failure: LocalizedError {
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .status(401, _), .status(403, _): "The server didn't accept the API key. It may have expired, been revoked, or been mistyped; check it in Settings."
            case .status(let code, let detail): "The server answered HTTP \(code)\(detail.isEmpty ? "" : ": \(detail)")."
            }
        }
    }

    static func models(for config: AIConfiguration) async throws -> [AvailableModel] {
        switch config.provider {
        case .apple:
            return [AppleIntelligence.model]
        case .claude:
            var models: [AvailableModel] = []
            var after: String?
            repeat {
                var url = config.baseURL.appending(path: "v1/models")
                url.append(queryItems: [URLQueryItem(name: "limit", value: "100")]
                    + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? []))
                var request = URLRequest(url: url)
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                let page = try parseClaudePage(try await fetch(request))
                models += page.models
                after = page.hasMore ? page.lastID : nil
            } while after != nil
            return models

        case .ollama:
            return try parseOllamaTags(try await fetch(URLRequest(url: config.baseURL.appending(path: "api/tags"))))

        case .openAICompatible:
            var request = URLRequest(url: config.baseURL.appending(path: "models"))
            if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization") }
            return try parseOpenAIModels(try await fetch(request))
        }
    }

    /// More about one model than its list entry gives: Ollama's /api/show (window, vision, size), or
    /// Claude's `GET /v1/models/{id}` for a model the list didn't include. Nil when there is nothing more
    /// to ask (OpenAI-compatible servers).
    static func details(of model: String, for config: AIConfiguration) async throws -> AvailableModel? {
        guard !model.isEmpty else { return nil }
        switch config.provider {
        case .apple:
            return AppleIntelligence.model
        case .ollama:
            var request = URLRequest(url: config.baseURL.appending(path: "api/show"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
            return try parseOllamaShow(try await fetch(request), name: model)
        case .claude:
            var request = URLRequest(url: config.baseURL.appending(path: "v1/models/\(model)"))
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            return try parseClaudeModel(try await fetch(request))
        case .openAICompatible:
            return nil
        }
    }

    /// Whether the chosen model can see images: `true`/`false` when the provider says, `nil` when it
    /// doesn't say or can't be reached (then the slides are sent as images and the request is retried as
    /// text if the provider rejects them).
    static func acceptsImages(_ config: AIConfiguration) async -> Bool? {
        switch config.provider {
        case .apple:
            return true
        case .claude, .ollama:
            return (try? await details(of: config.model, for: config))?.acceptsImages
        case .openAICompatible:
            // Only some services (OpenRouter) say, and only in the model list.
            return (try? await models(for: config))?.first { $0.id == config.model }?.acceptsImages
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String ?? ""
            throw Failure.status(status, detail)
        }
        return data
    }

    // MARK: Parsing

    struct ClaudePage: Equatable {
        var models: [AvailableModel]
        var hasMore: Bool
        var lastID: String?
    }

    /// One model in Claude's Models API (both the list and `GET /v1/models/{id}`).
    private struct ClaudeModel: Decodable {
        struct Capabilities: Decodable {
            struct Supported: Decodable { let supported: Bool? }
            let image_input: Supported?
        }
        let id: String
        let display_name: String?
        let max_input_tokens: Int?
        let max_tokens: Int?
        let capabilities: Capabilities?

        var model: AvailableModel {
            AvailableModel(
                id: id, displayName: display_name, contextTokens: max_input_tokens,
                maxOutputTokens: max_tokens, acceptsImages: capabilities?.image_input?.supported
            )
        }
    }

    static func parseClaudePage(_ data: Data) throws -> ClaudePage {
        struct Page: Decodable {
            let data: [ClaudeModel]
            let has_more: Bool?
            let last_id: String?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return ClaudePage(models: page.data.map(\.model), hasMore: page.has_more ?? false, lastID: page.last_id)
    }

    static func parseClaudeModel(_ data: Data) throws -> AvailableModel {
        try JSONDecoder().decode(ClaudeModel.self, from: data).model
    }

    /// One Ollama model's details from /api/show: its window, whether it has "vision" among its
    /// capabilities, and its size ("8.0B parameters · Q4_K_M").
    static func parseOllamaShow(_ data: Data, name: String) throws -> AvailableModel {
        struct Show: Decodable {
            struct Details: Decodable {
                let parameter_size: String?
                let quantization_level: String?
            }
            let capabilities: [String]?
            let details: Details?
        }
        let show = try JSONDecoder().decode(Show.self, from: data)
        let size = [show.details?.parameter_size.map { "\($0) parameters" }, show.details?.quantization_level]
            .compactMap { $0 }
            .joined(separator: " · ")
        return AvailableModel(
            id: name, contextTokens: LongLectures.ollamaContextLength(from: data),
            acceptsImages: show.capabilities.map { $0.contains("vision") },
            summary: size.isEmpty ? nil : size
        )
    }

    static func parseOllamaTags(_ data: Data) throws -> [AvailableModel] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        return try JSONDecoder().decode(Tags.self, from: data).models
            .map { AvailableModel(id: $0.name) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func parseOpenAIModels(_ data: Data) throws -> [AvailableModel] {
        // OpenRouter adds a name, description, window, input types, and its top provider's reply limit.
        struct List: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable { let input_modalities: [String]? }
                struct TopProvider: Decodable { let max_completion_tokens: Int? }
                let id: String
                let name: String?
                let description: String?
                let context_length: Int?
                let architecture: Architecture?
                let top_provider: TopProvider?
            }
            let data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: data).data
            .map {
                AvailableModel(
                    id: $0.id, displayName: $0.name, contextTokens: $0.context_length,
                    maxOutputTokens: $0.top_provider?.max_completion_tokens,
                    acceptsImages: $0.architecture?.input_modalities.map { $0.contains("image") },
                    summary: $0.description
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
