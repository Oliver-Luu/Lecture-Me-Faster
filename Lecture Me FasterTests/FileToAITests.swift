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
        #expect(parts.count == 2)
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
        #expect(options["num_ctx"] == 8192)

        let longText = String(repeating: "word ", count: 20_000)
        let longJSON = try body(FileToAI.request(for: [.text(longText)], config: config(.ollama)))
        let longOptions = try #require(longJSON["options"] as? [String: Int])
        #expect(longOptions["num_ctx"] == 100_000 / 3 + 6000)
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
