import Foundation
import Testing
@testable import Lecture_Me_Faster

struct FileToAITests {
    private let transcript = [
        TranscriptSegment(seconds: 0, text: "Hello class."),
        TranscriptSegment(seconds: 5, text: "Today: entropy."),
        TranscriptSegment(seconds: 40, text: "Next topic."),
    ]
    private let frames = [
        LectureFrame(seconds: 0, jpeg: Data([1, 2, 3])),
        LectureFrame(seconds: 75, jpeg: Data([4, 5, 6])),
    ]

    private func config(_ provider: AIProvider, model: String = "m", key: String = "secret") -> AIConfiguration {
        AIConfiguration(provider: provider, baseURL: URL(string: "http://127.0.0.1:9/base")!, model: model, apiKey: key)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Prompt

    @Test func timestampsSwitchToHoursPastOneHour() {
        #expect(timestamp(0) == "0:00")
        #expect(timestamp(75) == "1:15")
        #expect(timestamp(3725) == "1:02:05")
    }

    @Test func transcriptIsGroupedIntoThirtySecondParagraphs() {
        #expect(FileToAI.paragraphs(from: transcript) == "[0:00] Hello class. Today: entropy.\n\n[0:40] Next topic.")
        #expect(FileToAI.paragraphs(from: []) == "")
    }

    @Test func promptLabelsEachFrameWithItsTimestamp() {
        let parts = FileToAI.promptParts(title: "Lecture 4", transcript: transcript, frames: frames)
        let described = parts.map { part -> String in
            switch part {
            case .text(let text): text
            case .image(let data): "<image \(data.count)>"
            }
        }
        #expect(described.first == "Lecture file: Lecture 4")
        #expect(Array(described[2...5]) == ["[0:00]", "<image 3>", "[1:15]", "<image 3>"])
        #expect(described.last?.hasPrefix("Transcript:\n\n[0:00] Hello class.") == true)
    }

    @Test func promptOmitsSlideIntroForAudioOnlyLectures() {
        let parts = FileToAI.promptParts(title: "Audio", transcript: transcript, frames: [])
        let texts = parts.compactMap { part -> String? in if case .text(let t) = part { t } else { nil } }
        #expect(texts.count == parts.count, "No images")
        #expect(!texts.contains { $0.contains("slide and board captures") })
        // Saying so outright keeps smaller models from describing slides or materials that don't exist.
        #expect(texts.contains("No slides are included."))
        #expect(texts.contains("No supporting materials are included."))
        #expect(texts.last?.hasPrefix("Transcript:") == true)
    }

    @Test func everyLevelForbidsInventedContent() {
        for level in NoteDetail.allCases {
            let prompt = FileToAI.systemPrompt(detail: level)
            #expect(prompt.contains("Never invent deadlines"))
            #expect(prompt.contains("Leave out any section"))
            #expect(!prompt.contains("Include any logistics"), "Logistics only if the professor actually mentions them")
        }
    }

    @Test func multiFileLecturesTellTheModelWhereEachPartStarts() throws {
        let lectureParts = [LecturePart(name: "Week 3 pt1", startSeconds: 0), LecturePart(name: "Week 3 pt2", startSeconds: 2700)]
        let parts = FileToAI.promptParts(title: "Week 3", transcript: transcript, frames: [], lectureParts: lectureParts)
        guard case .text(let header) = try #require(parts.first) else { Issue.record("Expected text first"); return }
        #expect(header.contains("Lecture: Week 3"))
        #expect(header.contains("recorded as 2 files"))
        #expect(header.contains("Part 1, \"Week 3 pt1\", starts at [0:00]"))
        #expect(header.contains("Part 2, \"Week 3 pt2\", starts at [45:00]"))

        let single = FileToAI.promptParts(title: "Week 3", transcript: transcript, frames: [], lectureParts: [lectureParts[0]])
        guard case .text(let singleHeader) = try #require(single.first) else { Issue.record("Expected text first"); return }
        #expect(singleHeader == "Lecture file: Week 3", "One file needs no part list")
    }

    // MARK: Requests

    @Test func claudeRequestCarriesKeyVersionImagesAndFallback() throws {
        let parts = FileToAI.promptParts(title: "T", transcript: transcript, frames: frames)
        let request = try FileToAI.request(for: parts, config: config(.claude, model: "claude-opus-5-5"))
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/base/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let json = try body(request)
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["stream"] as? Bool == true)
        #expect(json["fallbacks"] as? String == "default")
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "image" }
        #expect(images.count == 2)
        let source = try #require(images.first?["source"] as? [String: String])
        #expect(source == ["type": "base64", "media_type": "image/jpeg", "data": "AQID"])
    }

    @Test func claudeHaikuRequestHasNoFallback() throws {
        let request = try FileToAI.request(for: [.text("hi")], config: config(.claude, model: "claude-haiku-5-5"))
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try body(request)["fallbacks"] == nil)
    }

    @Test func ollamaRequestSendsImagesAndSizesContextWindow() throws {
        let parts = FileToAI.promptParts(title: "T", transcript: transcript, frames: frames)
        let json = try body(FileToAI.request(for: parts, config: config(.ollama)))
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["images"] as? [String] == ["AQID", "BAUG"])
        let options = try #require(json["options"] as? [String: Int])
        // The smallest window used is 8,192; this short lecture needs more only because room is kept for the notes.
        let system = FileToAI.systemPrompt(detail: .detailed)
        let reserve = LongLectures.outputReserve(provider: .ollama, contextTokens: LongLectures.maxLocalContextTokens)
        #expect(reserve == 16_384)
        let prompt = parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        #expect(options["num_ctx"] == (prompt.count + system.count) / 3 + 2 * 1000 + 1000 + reserve)

        // The window covers the lecture, the instructions, and the room the plan keeps for the notes
        // (before 2026-11-16 only 6,000 tokens were added, so a long reply could be cut off).
        let longText = String(repeating: "word ", count: 20_000)
        let longJSON = try body(FileToAI.request(for: [.text(longText)], config: config(.ollama)))
        let longOptions = try #require(longJSON["options"] as? [String: Int])
        #expect(longOptions["num_ctx"] == (100_000 + system.count) / 3 + 1000 + reserve)

        // Never more than the model's window, and the reserve shrinks with a small window.
        var small = config(.ollama)
        small.contextTokens = 16_384
        let smallOptions = try #require(try body(FileToAI.request(for: [.text(longText)], config: small))["options"] as? [String: Int])
        #expect(smallOptions["num_ctx"] == 16_384)
    }

    @Test func claudeRequestFitsWhatTheModelAccepts() throws {
        // A current model: effort is set and the reply limit is the app's own.
        let current = try body(FileToAI.request(for: [.text("hi")], config: config(.claude, model: "claude-opus-5-5")))
        #expect((current["output_config"] as? [String: String]) == ["effort": "medium"])
        #expect(current["max_tokens"] as? Int == 64_000)

        // Haiku 4.5 rejects the effort setting (Anthropic's reference, 2026-11-03), so it isn't sent,
        // whether known from the model's name or from what the model list said.
        let old = try FileToAI.request(for: [.text("hi")], config: config(.claude, model: "claude-haiku-4-5"))
        #expect(try body(old)["output_config"] == nil)
        #expect(old.value(forHTTPHeaderField: "anthropic-beta") == nil)
        var listed = config(.claude, model: "claude-some-future-model")
        listed.supportsEffort = false
        listed.maxOutputTokens = 32_000
        let future = try body(FileToAI.request(for: [.text("hi")], config: listed))
        #expect(future["output_config"] == nil)
        #expect(future["max_tokens"] as? Int == 32_000, "Never more than the model can write")
        #expect(future["fallbacks"] == nil, "Only the models Anthropic lists get the refusal fallback")

        var big = config(.claude, model: "claude-opus-5-5")
        big.maxOutputTokens = 128_000
        #expect(try body(FileToAI.request(for: [.text("hi")], config: big))["max_tokens"] as? Int == 64_000)
        #expect(FileToAI.claudeHasRefusalFallback("claude-fable-5-2"))
        #expect(FileToAI.claudeHasRefusalFallback("claude-sonnet-5-5"))
        #expect(!FileToAI.claudeHasRefusalFallback("claude-sonnet-5"))
        #expect(!FileToAI.claudeHasRefusalFallback("claude-opus-4-8"))
    }

    @Test func openAIRequestUsesBearerKeyOnlyWhenPresent() throws {
        let parts = FileToAI.promptParts(title: "T", transcript: transcript, frames: frames)
        let withKey = try FileToAI.request(for: parts, config: config(.openAICompatible))
        #expect(withKey.url?.absoluteString == "http://127.0.0.1:9/base/chat/completions")
        #expect(withKey.value(forHTTPHeaderField: "authorization") == "Bearer secret")
        let messages = try #require(try body(withKey)["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image_url" }?["image_url"] as? [String: String])
        #expect(image["url"] == "data:image/jpeg;base64,AQID")

        let withoutKey = try FileToAI.request(for: parts, config: config(.openAICompatible, key: ""))
        #expect(withoutKey.value(forHTTPHeaderField: "authorization") == nil)
    }

    // MARK: Note detail

    @Test func eachDetailLevelGetsItsOwnInstructionsAndTheSharedRules() {
        let prompts = NoteDetail.allCases.map { FileToAI.systemPrompt(detail: $0) }
        #expect(Set(prompts).count == NoteDetail.allCases.count, "Every level must produce a different prompt")
        for (level, prompt) in zip(NoteDetail.allCases, prompts) {
            #expect(prompt.contains(level.instructions))
            #expect(prompt.contains("The transcript is machine-generated"), "Mishearing rules apply at every level")
            #expect(prompt.contains("cannot render tables or LaTeX"), "Formatting rules apply at every level")
        }
        #expect(FileToAI.systemPrompt(detail: .complete).contains("thoroughness matters more than brevity"))
        #expect(FileToAI.systemPrompt(detail: .keyPoints).contains("Leave out derivations, worked examples"))
    }

    @Test func detailLevelsRunFromBriefToThorough() {
        #expect(NoteDetail.allCases == [.keyPoints, .concise, .detailed, .complete])
        #expect(NoteDetail.allCases.map(\.rawValue) == [0, 1, 2, 3], "The Settings slider maps steps 0–3 to these")
    }

    @Test func everyProviderReceivesTheChosenDetailLevel() throws {
        let expected = FileToAI.systemPrompt(detail: .keyPoints)

        let claude = try body(FileToAI.request(for: [.text("hi")], config: config(.claude), detail: .keyPoints))
        #expect(claude["system"] as? String == expected)

        for provider in [AIProvider.ollama, .openAICompatible] {
            let json = try body(FileToAI.request(for: [.text("hi")], config: config(provider), detail: .keyPoints))
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect(messages[0]["role"] as? String == "system")
            #expect(messages[0]["content"] as? String == expected)
        }
    }

    // MARK: Responses

    @Test func claudeStreamYieldsTextAndIgnoresOtherEvents() throws {
        let delta = #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi \"there\""}}"#
        #expect(try FileToAI.parse(delta, provider: .claude) == #"Hi "there""#)
        #expect(try FileToAI.parse("event: content_block_delta", provider: .claude) == nil)
        #expect(try FileToAI.parse(#"data: {"type":"message_start","message":{"id":"x"}}"#, provider: .claude) == nil)
        #expect(try FileToAI.parse(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}"#, provider: .claude) == nil)
        #expect(try FileToAI.parse(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, provider: .claude) == nil)
    }

    @Test func claudeStreamReportsRefusalTruncationAndErrors() throws {
        #expect(throws: FileToAI.Failure.self) {
            try FileToAI.parse(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, provider: .claude)
        }
        let truncated = try FileToAI.parse(#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#, provider: .claude)
        #expect(truncated?.contains("cut off") == true)

        let error = #expect(throws: FileToAI.Failure.self) {
            try FileToAI.parse(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, provider: .claude)
        }
        #expect(error?.localizedDescription == "Overloaded")
    }

    @Test func ollamaStreamYieldsContentAndReportsErrors() throws {
        #expect(try FileToAI.parse(#"{"message":{"role":"assistant","content":"Hi"},"done":false}"#, provider: .ollama) == "Hi")
        #expect(try FileToAI.parse(#"{"message":{"role":"assistant","content":""},"done":true}"#, provider: .ollama) == "")
        let error = #expect(throws: FileToAI.Failure.self) {
            try FileToAI.parse(#"{"error":"model not found"}"#, provider: .ollama)
        }
        #expect(error?.localizedDescription == "model not found")
    }

    @Test func openAIStreamYieldsContentAndStopsAtDone() throws {
        #expect(try FileToAI.parse(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#, provider: .openAICompatible) == "Hi")
        #expect(try FileToAI.parse(#"data: {"choices":[{"delta":{}}]}"#, provider: .openAICompatible) == nil)
        #expect(try FileToAI.parse("data: [DONE]", provider: .openAICompatible) == nil)
    }
}
