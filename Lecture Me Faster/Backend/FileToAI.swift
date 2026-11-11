import Foundation

nonisolated enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama, claude, openAICompatible

    var id: Self { self }

    var label: String {
        switch self {
        case .ollama: "Ollama (local, free)"
        case .claude: "Claude"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

nonisolated struct AIConfiguration: Sendable {
    var provider: AIProvider
    var baseURL: URL
    var model: String
    var apiKey: String
}

nonisolated func timestamp(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

/// Sends the transcript and frames to a model and streams back the lecture notes.
nonisolated enum FileToAI {
    enum Failure: LocalizedError {
        case api(String)
        case refused

        var errorDescription: String? {
            switch self {
            case .api(let message): message
            case .refused: "The model declined to summarize this lecture."
            }
        }
    }

    static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    static func summarize(
        title: String,
        transcript: [TranscriptSegment],
        frames: [LectureFrame],
        with config: AIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let parts = promptParts(title: title, transcript: transcript, frames: frames)
                    let request = try request(for: parts, config: config)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw Failure.api(try await errorMessage(from: bytes, status: status))
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

    static func ollamaModels(baseURL: URL) async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let (data, _) = try await URLSession.shared.data(from: baseURL.appending(path: "api/tags"))
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
    }

    // MARK: Prompt

    private static let systemPrompt = """
        You are helping a university student who has not watched this lecture and will study from your notes \
        instead of watching it. You are given a speech-to-text transcript with [timestamps] and, for video \
        lectures, still frames captured whenever the slide or board changed, each with its timestamp.

        Write complete study notes covering everything taught: every concept, definition, formula, derivation \
        step, and worked example, plus any logistics the professor mentions (deadlines, exam hints, what they \
        stress as important). Follow the lecture's order, organized under headings by topic. Explain each idea \
        fully enough that the student could learn the material from the notes alone; thoroughness matters more \
        than brevity. End with a short list of key takeaways.

        The transcript is machine-generated, so technical terms, names, and symbols are often misheard. Use the \
        slides and the surrounding context to recover what was actually said, and use the slides for content \
        the professor shows but does not read aloud. If something is unclear or missing from the source, say \
        so rather than guessing.

        Formatting: the notes are shown in a simple Markdown renderer that supports headings (#, ##, ###), \
        bullet and numbered lists, **bold**, *italic*, `inline code`, and fenced code blocks. It cannot render \
        tables or LaTeX, so write math in plain text with Unicode symbols (x² + y² = r², ∑, ∫, →).
        """

    enum Part {
        case text(String)
        case image(Data)
    }

    static func promptParts(title: String, transcript: [TranscriptSegment], frames: [LectureFrame]) -> [Part] {
        var parts: [Part] = [.text("Lecture file: \(title)")]
        if !frames.isEmpty {
            parts.append(.text("""
                \(frames.count) slide and board captures from the video follow in chronological order. \
                Each image's timestamp is given in brackets.
                """))
            for frame in frames {
                parts.append(.text("[\(timestamp(frame.seconds))]"))
                parts.append(.image(frame.jpeg))
            }
        }
        parts.append(.text("Transcript:\n\n" + paragraphs(from: transcript)))
        return parts
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

    static func request(for parts: [Part], config: AIConfiguration) throws -> URLRequest {
        let path: String
        var headers = ["content-type": "application/json"]
        let body: [String: Any]

        switch config.provider {
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
                "options": ["num_ctx": min(max(estimatedTokens, 8192), 131_072)],
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

    private static func errorMessage(from bytes: URLSession.AsyncBytes, status: Int) async throws -> String {
        var body = ""
        for try await line in bytes.lines { body += line }
        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String ?? body
        return "The model server returned an error (HTTP \(status)): \(detail)"
    }
}
