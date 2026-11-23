import AVFoundation
import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Fixes from the whole-codebase review of 2026-11-16 that aren't covered next to the code they changed.
@MainActor
@Suite(.serialized)
struct ReviewFixTests {
    // MARK: One question to the provider before writing

    @Test func aRejectedKeyIsReportedAndAnUnreachableServerIsLeftToTheRequest() async throws {
        let host = "check.lecture-me-faster.test"
        let log = MockModelServer.start(host: host) { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/v1/models/claude-haiku-4-5") {
                return (200, #"{"id":"claude-haiku-4-5","max_input_tokens":200000,"max_tokens":64000,"capabilities":{"image_input":{"supported":true},"effort":{"supported":false}}}"#)
            }
            if path.hasSuffix("/v1/models/expired") {
                return (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
            }
            return (404, #"{"error":{"message":"not found"}}"#)
        }
        defer { MockModelServer.stop(host: host) }
        func config(_ model: String) -> AIConfiguration {
            AIConfiguration(provider: .claude, baseURL: URL(string: "http://\(host)")!, model: model, apiKey: "k")
        }

        let haiku = try #require(try await ModelCatalog.check(config("claude-haiku-4-5")))
        #expect(haiku.contextTokens == 200_000)
        #expect(haiku.maxOutputTokens == 64_000)
        #expect(haiku.acceptsImages == true)
        #expect(haiku.supportsEffort == false)
        #expect(log.requests.count == 1, "One request, where three asked for the same thing before")

        await #expect(throws: FileToAI.Failure.keyRejected("invalid x-api-key")) {
            _ = try await ModelCatalog.check(config("expired"))
        }
        #expect(try await ModelCatalog.check(config("unknown-model")) == nil, "Not found: the request itself will say")
        let unreachable = AIConfiguration(provider: .ollama, baseURL: URL(string: "http://127.0.0.1:9")!, model: "m", apiKey: "")
        #expect(try await ModelCatalog.check(unreachable) == nil)
    }

    // MARK: Gemini's context windows

    @Test func geminiLimitsComeFromGooglesOwnList() throws {
        // The shape documented at aistudio.google.com/api-reference/models (checked 2026-11-16).
        let page = Data(#"""
            {"models":[
              {"name":"models/gemini-flash","displayName":"Gemini Flash","inputTokenLimit":1048576,"outputTokenLimit":65536},
              {"name":"models/embedding-1","inputTokenLimit":2048}
            ],"nextPageToken":"abc"}
            """#.utf8)
        let parsed = try ModelCatalog.parseGeminiModels(page)
        #expect(parsed.nextPageToken == "abc")
        #expect(parsed.limits["gemini-flash"] == ModelCatalog.GeminiLimits(input: 1_048_576, output: 65_536))
        #expect(try ModelCatalog.parseGeminiModels(Data(#"{"models":[]}"#.utf8)).nextPageToken == nil)

        // The OpenAI-format list names models with or without "models/"; either matches.
        let listed = [AvailableModel(id: "models/gemini-flash"), AvailableModel(id: "gemini-flash"), AvailableModel(id: "other")]
        let filled = ModelCatalog.addingGeminiLimits(parsed.limits, to: listed)
        #expect(filled.map(\.contextTokens) == [1_048_576, 1_048_576, nil])
        #expect(filled[0].maxOutputTokens == 65_536)
    }

    // MARK: A context window per service

    @Test func eachServiceKeepsItsOwnContextWindow() {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIService = OpenAIService.lmStudio.id
        stored.openAIContextTokens = 8_192
        let settings = AppSettings(unsaved: stored)

        // Before 2026-11-16 the 8,192 set for LM Studio carried over to every other service.
        settings.chooseService(.gemini)
        #expect(settings.stored.openAIContextTokens == AppSettings.Stored().openAIContextTokens)
        settings.stored.openAIContextTokens = 1_000_000
        settings.chooseService(.lmStudio)
        #expect(settings.stored.openAIContextTokens == 8_192)
        #expect(settings.contextSetting(forService: OpenAIService.gemini.id) == 1_000_000)

        // A level with its own model on another service is planned with that service's window.
        settings.setModelChoice(.init(provider: .openAICompatible, service: OpenAIService.gemini.id, model: "g"), for: .keyPoints)
        #expect(settings.contextSetting(for: .keyPoints) == 1_000_000)
        #expect(settings.contextSetting(for: .detailed) == 8_192, "Levels without their own model use the current service")
        settings.setModelChoice(.init(provider: .claude, service: nil, model: "claude-opus-5-5"), for: .complete)
        #expect(settings.contextSetting(for: .complete) == 8_192, "Not used for Claude, which reports its own window")
    }

    @Test func settingsSavedBeforePerServiceWindowsStillLoad() throws {
        let old = Data(#"{"provider":"openAICompatible","openAIService":"gemini","openAIContextTokens":65536}"#.utf8)
        let stored = try JSONDecoder().decode(AppSettings.Stored.self, from: old)
        #expect(stored.openAIContextTokens == 65_536)
        #expect(stored.serviceContextTokens.isEmpty)
    }

    // MARK: Slides tab pictures

    @Test func slideThumbnailsAreSmallAndKeepTheirShape() throws {
        let image = TestDocuments.image(of: ["Kolmogorov Complexity"])
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let thumbnail = try #require(FrameThumbnails.thumbnail(from: data as Data, maxPixels: 100))
        #expect(max(thumbnail.width, thumbnail.height) == 100)
        let shape = Double(image.width) / Double(image.height)
        #expect(abs(Double(thumbnail.width) / Double(thumbnail.height) - shape) < 0.05)
        #expect(FrameThumbnails.thumbnail(from: Data([0, 1, 2])) == nil, "Not an image")
    }

    // MARK: A video that doesn't say how long it is

    @Test(.timeLimit(.minutes(1))) func aVideoWithNoKnownLengthIsNotScannedForever() async throws {
        let video = try await TestMedia.makeSlideVideo(slides: 1, secondsPerSlide: 2)
        defer { try? FileManager.default.removeItem(at: video) }
        // Before 2026-11-16 a length that isn't a number made the list of sample times endless.
        for duration in [Double.nan, .infinity, 0] {
            let timeline = try await VideoToFrames.scanTimeline(
                AVURLAsset(url: video), duration: duration, interval: 1, pieces: 1
            ) { _ in }
            #expect(timeline.seconds.isEmpty)
        }
    }
}
