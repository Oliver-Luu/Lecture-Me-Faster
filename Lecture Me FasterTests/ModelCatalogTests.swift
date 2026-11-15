import Foundation
import Testing
@testable import Lecture_Me_Faster

/// Asking each provider which models it offers. Network answers come from `MockModelServer`.
@Suite(.serialized)
struct ModelCatalogTests {
    private func config(_ provider: AIProvider, host: String, path: String = "", key: String = "k") -> AIConfiguration {
        AIConfiguration(provider: provider, baseURL: URL(string: "http://\(host)\(path)")!, model: "", apiKey: key)
    }

    // MARK: Parsing

    @Test func parsesAClaudePage() throws {
        let page = try ModelCatalog.parseClaudePage(Data("""
            {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000},
                     {"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],
             "has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-haiku-5-5"}
            """.utf8))
        #expect(page.models == [
            AvailableModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", contextTokens: 1_000_000),
            AvailableModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", contextTokens: nil),
        ])
        #expect(page.hasMore)
        #expect(page.lastID == "claude-haiku-5-5")
        #expect(page.models[0].label == "Claude Opus 5.5")
    }

    @Test func parsesOllamaTagsInNaturalOrder() throws {
        let models = try ModelCatalog.parseOllamaTags(Data(#"{"models":[{"name":"qwen3:14b"},{"name":"gemma3:12b"},{"name":"gemma3:4b"}]}"#.utf8))
        #expect(models.map(\.id) == ["gemma3:4b", "gemma3:12b", "qwen3:14b"])
    }

    @Test func parsesOpenAIStyleListsWithOrWithoutExtras() throws {
        let plain = try ModelCatalog.parseOpenAIModels(Data(#"{"object":"list","data":[{"id":"b-model","object":"model"},{"id":"a-model","object":"model"}]}"#.utf8))
        #expect(plain.map(\.id) == ["a-model", "b-model"])
        #expect(plain[0].label == "a-model")

        // OpenRouter adds a display name and the context window.
        let openRouter = try ModelCatalog.parseOpenAIModels(Data(#"{"data":[{"id":"openai/gpt-4","name":"GPT-4","context_length":8192}]}"#.utf8))
        #expect(openRouter == [AvailableModel(id: "openai/gpt-4", displayName: "GPT-4", contextTokens: 8_192)])

        #expect(throws: (any Error).self) { try ModelCatalog.parseOpenAIModels(Data(#"{"data":{"models":[]}}"#.utf8)) }
    }

    @Test func theCurrentChoiceStaysInTheMenu() {
        let models = [AvailableModel(id: "a"), AvailableModel(id: "b")]
        #expect(AIModelFields.including("b", in: models).map(\.id) == ["a", "b"])
        #expect(AIModelFields.including("old", in: models).map(\.id) == ["old", "a", "b"], "Not dropped just because it isn't listed")
        #expect(AIModelFields.including("", in: models).map(\.id) == ["a", "b"])
    }

    // MARK: Requests

    @Test func claudeListsEveryPage() async throws {
        let host = "claude.catalog.test"
        let log = MockModelServer.start(host: host) { request in
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after_id" }?.value
            return after == nil
                ? (200, #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":true,"last_id":"claude-opus-5-5"}"#)
                : (200, #"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":false,"last_id":"claude-haiku-5-5"}"#)
        }
        defer { MockModelServer.stop(host: host) }

        let models = try await ModelCatalog.models(for: config(.claude, host: host))
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(log.requestURLs.map(\.path) == ["/v1/models", "/v1/models"])
        #expect(log.requestURLs.last?.query?.contains("after_id=claude-opus-5-5") == true)
    }

    @Test func aRejectedKeyIsReportedPlainly() async throws {
        let host = "badkey.catalog.test"
        MockModelServer.start(host: host) { _ in (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) }
        defer { MockModelServer.stop(host: host) }

        await #expect(throws: ModelCatalog.Failure.self) { _ = try await ModelCatalog.models(for: config(.claude, host: host)) }
        #expect(ModelCatalog.Failure.status(401, "invalid x-api-key").localizedDescription .hasPrefix("The server didn't accept the API key. It may have expired"))
    }

    @Test func openAICompatibleServersAreAskedAtBaseURLSlashModels() async throws {
        let host = "openai.catalog.test"
        let log = MockModelServer.start(host: host) { _ in (200, #"{"data":[{"id":"local-model"}]}"#) }
        defer { MockModelServer.stop(host: host) }

        let models = try await ModelCatalog.models(for: config(.openAICompatible, host: host, path: "/v1"))
        #expect(models.map(\.id) == ["local-model"])
        #expect(log.requestURLs.map(\.path) == ["/v1/models"])
    }

    @Test func ollamaIsAskedForItsTags() async throws {
        let host = "ollama.catalog.test"
        let log = MockModelServer.start(host: host) { _ in (200, #"{"models":[{"name":"gemma3:12b"}]}"#) }
        defer { MockModelServer.stop(host: host) }

        let models = try await ModelCatalog.models(for: config(.ollama, host: host))
        #expect(models.map(\.id) == ["gemma3:12b"])
        #expect(log.requestURLs.map(\.path) == ["/api/tags"])
    }

    @Test @MainActor func connectionDetailsDontNeedAModel() {
        var stored = AppSettings.Stored()
        stored.provider = .ollama
        stored.ollamaModel = ""
        let settings = AppSettings(unsaved: stored)
        #expect(settings.connection()?.baseURL.absoluteString == "http://localhost:11434")
        #expect(throws: (any Error).self) { try settings.configuration() }

        settings.stored.ollamaURL = "not a url"
        #expect(settings.connection() == nil)
    }
}

/// Filling in the OpenAI-compatible context window from the server's model list.
struct ListedContextWindowTests {
    private let models = [
        AvailableModel(id: "openai/gpt-4", displayName: "GPT-4", contextTokens: 8_192),
        AvailableModel(id: "anthropic/claude-opus-5-5", displayName: "Claude Opus 5.5", contextTokens: 1_000_000),
        AvailableModel(id: "local-model"),
        AvailableModel(id: "broken", contextTokens: 0),
    ]

    @Test func usesTheListedWindowForTheChosenModel() {
        #expect(AIModelFields.listedContextWindow(for: "openai/gpt-4", in: models) == 8_192)
        #expect(AIModelFields.listedContextWindow(for: "anthropic/claude-opus-5-5", in: models) == 1_000_000)
    }

    @Test func leavesTheSettingAloneWhenTheListDoesntSay() {
        #expect(AIModelFields.listedContextWindow(for: "local-model", in: models) == nil)
        #expect(AIModelFields.listedContextWindow(for: "broken", in: models) == nil, "A zero window isn't believed")
        #expect(AIModelFields.listedContextWindow(for: "not-listed", in: models) == nil)
        #expect(AIModelFields.listedContextWindow(for: "openai/gpt-4", in: []) == nil)
    }

    @Test func theMenuCanShowAnyListedSize() {
        #expect(AIModelFields.contextOptions(including: 32_768) == [8_192, 16_384, 32_768, 65_536, 131_072, 200_000, 1_000_000])
        #expect(AIModelFields.contextOptions(including: 128_000) == [8_192, 16_384, 32_768, 65_536, 128_000, 131_072, 200_000, 1_000_000])
        #expect(!AIModelFields.contextOptions(including: 0).contains(0))
    }
}

/// What the app learns about one model, and what the details panel says about it.
struct ModelDetailsTests {
    @Test func claudeListEntriesCarryLimitsAndVision() throws {
        let page = try ModelCatalog.parseClaudePage(Data("""
            {"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000,
                      "capabilities":{"image_input":{"supported":true},"thinking":{"supported":true}}}],"has_more":false}
            """.utf8))
        let opus = try #require(page.models.first)
        #expect(opus.contextTokens == 1_000_000)
        #expect(opus.maxOutputTokens == 128_000)
        #expect(opus.acceptsImages == true)
    }

    @Test func ollamaShowGivesWindowVisionAndSize() throws {
        let show = Data("""
            {"capabilities":["completion","thinking","vision"],
             "details":{"format":"gguf","family":"gemma4","parameter_size":"8.0B","quantization_level":"Q4_K_M"},
             "model_info":{"general.architecture":"gemma4","gemma4.context_length":262144}}
            """.utf8)
        let model = try ModelCatalog.parseOllamaShow(show, name: "gemma4:8b")
        #expect(model == AvailableModel(id: "gemma4:8b", contextTokens: 262_144, acceptsImages: true, summary: "8.0B parameters · Q4_K_M"))

        let textOnly = try ModelCatalog.parseOllamaShow(Data(#"{"capabilities":["completion"]}"#.utf8), name: "m")
        #expect(textOnly.acceptsImages == false)
        #expect(textOnly.summary == nil)
    }

    @Test func openRouterEntriesCarryDescriptionVisionAndReplyLimit() throws {
        let list = try ModelCatalog.parseOpenAIModels(Data("""
            {"data":[{"id":"openai/gpt-4","name":"GPT-4","description":"A large model.","context_length":8192,
                      "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
                      "top_provider":{"max_completion_tokens":4096}},
                     {"id":"vision/model","architecture":{"input_modalities":["text","image"]}}]}
            """.utf8))
        #expect(list[0] == AvailableModel(id: "openai/gpt-4", displayName: "GPT-4", contextTokens: 8_192, maxOutputTokens: 4_096, acceptsImages: false, summary: "A large model."))
        #expect(list[1].acceptsImages == true)
    }

    @Test func ollamaDetailsAreAskedForByName() async throws {
        let host = "ollama.details.test"
        let log = MockModelServer.start(host: host) { _ in (200, #"{"capabilities":["completion","vision"],"model_info":{"llama.context_length":8192}}"#) }
        defer { MockModelServer.stop(host: host) }
        let config = AIConfiguration(provider: .ollama, baseURL: URL(string: "http://\(host)")!, model: "", apiKey: "")

        let details = try #require(try await ModelCatalog.details(of: "llava:7b", for: config))
        #expect(details.contextTokens == 8_192)
        #expect(details.acceptsImages == true)
        #expect(log.requestURLs.map(\.path) == ["/api/show"])
        #expect(log.requests.first?.contains("llava:7b") == true)
        #expect(try await ModelCatalog.details(of: "", for: config) == nil)
    }

    // MARK: The panel

    private func describe(_ model: AvailableModel?, _ provider: AIProvider, setting: Int = 32_768) -> [String] {
        AIModelFields.describe(model, provider: provider, openAIContextSetting: setting)
    }

    @Test func describesAClaudeModelFromTheLiveList() {
        let lines = describe(AvailableModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", contextTokens: 1_000_000, maxOutputTokens: 128_000, acceptsImages: true), .claude)
        #expect(lines == [
            "Haiku is the fastest and cheapest.",
            "Context window: 1,000,000 tokens.",
            "Lectures that don't fit are written in parts.",
            "Notes can be up to 64,000 tokens long per request.",
            "Can see the slides.",
        ])
    }

    @Test func claudeBeforeTheListLoadsSaysSo() {
        let lines = describe(AvailableModel(id: "claude-opus-5-5"), .claude)
        #expect(lines.first == "Opus writes the most thorough notes and costs the most of the usual three.")
        #expect(lines.contains("Context window: shown once Anthropic's model list loads."))
    }

    @Test func ollamaWindowsAboveTheMemoryCapAreExplained() {
        let big = describe(AvailableModel(id: "m", contextTokens: 1_048_576, acceptsImages: false, summary: "8.0B parameters · Q4_K_M"), .ollama)
        #expect(big[0] == "8.0B parameters · Q4_K_M")
        #expect(big[1].hasPrefix("Context window: 262,144 tokens used. The model supports 1,048,576"))
        #expect(big.last == "Can't see images: slides are sent as the text read from them, so diagrams may be missed.")

        #expect(describe(AvailableModel(id: "m", contextTokens: 8_192), .ollama)[0] == "Context window: 8,192 tokens.")
        #expect(describe(AvailableModel(id: "m"), .ollama)[0].hasPrefix("Context window: the model doesn't report one, so 32,768 tokens is assumed."))
        #expect(describe(AvailableModel(id: "m", contextTokens: 262_144), .ollama)[0] == "Context window: 262,144 tokens.", "256K is under the cap now")
    }

    @Test func ollamaContextSettingOverridesWhatTheModelReports() {
        let mlx = AIModelFields.describe(AvailableModel(id: "nemotron3:33b-mlx"), provider: .ollama, openAIContextSetting: 0, ollamaContextSetting: 262_144)
        #expect(mlx[0] == "Context window: 262,144 tokens, from the Context window setting (the model doesn't report one).")
        let gguf = AIModelFields.describe(AvailableModel(id: "nemotron3", contextTokens: 131_072), provider: .ollama, openAIContextSetting: 0, ollamaContextSetting: 65_536)
        #expect(gguf[0] == "Context window: 65,536 tokens, from the Context window setting (the model reports 131,072).")
        #expect(AIModelFields.ollamaContextOptions(including: 0).first == 0, "Automatic first")
        #expect(AIModelFields.ollamaContextOptions(including: 100_000).contains(100_000))
    }

    @Test func oldSettingsLoadWithAutomaticOllamaWindow() throws {
        let stored = try JSONDecoder().decode(AppSettings.Stored.self, from: Data(#"{"maxFrames": 30}"#.utf8))
        #expect(stored.ollamaContextTokens == 0)
    }

    @Test func openAICompatibleSaysWhereTheWindowCameFrom() {
        #expect(describe(AvailableModel(id: "x", contextTokens: 8_192), .openAICompatible).contains("Context window: 8,192 tokens, from the server's model list."))
        #expect(describe(AvailableModel(id: "x"), .openAICompatible, setting: 65_536).contains("Context window: 65,536 tokens, from the Context window setting."))
    }

    @Test func longDescriptionsAreShortenedAndNoModelIsHandled() {
        let long = describe(AvailableModel(id: "x", summary: String(repeating: "a", count: 500)), .openAICompatible)
        #expect(long[0].count == 221)
        #expect(long[0].hasSuffix("…"))
        #expect(describe(nil, .ollama) == ["Choose a model to see what it can do."])
    }
}

/// The basic/advanced split in Settings.
@MainActor
struct SettingsSplitTests {
    private func settings(_ provider: AIProvider) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = provider
        stored.ollamaModel = "gemma3:12b"
        return AppSettings(unsaved: stored)
    }

    @Test func theBasicSettingsOnlyDescribeTheModelAndWarnAboutSlides() {
        let sees = AvailableModel(id: "claude-haiku-5-5", contextTokens: 1_000_000, maxOutputTokens: 128_000, acceptsImages: true)
        #expect(AIModelFields.describeBrief(sees, provider: .claude) == ["Haiku is the fastest and cheapest."],
                "Context window and limits are under Advanced")

        let blind = AvailableModel(id: "m", contextTokens: 8_192, acceptsImages: false, summary: "8.0B parameters · Q4_K_M")
        #expect(AIModelFields.describeBrief(blind, provider: .ollama) == [
            "8.0B parameters · Q4_K_M",
            "Can't see images: slides are sent as the text read from them, so diagrams may be missed.",
        ], "A model that can't see the slides is worth warning everyone about")

        #expect(AIModelFields.describeBrief(AvailableModel(id: "x"), provider: .openAICompatible).isEmpty)
        #expect(AIModelFields.describeBrief(nil, provider: .ollama) == ["Choose a model."])
    }

    @Test func theChosenModelCombinesItsListEntryWithWhatWasAskedAboutIt() {
        let state = ModelListState()
        let settings = settings(.ollama)
        state.models = [AvailableModel(id: "gemma3:12b"), AvailableModel(id: "qwen3:14b")]
        #expect(state.selectedModelInfo(settings) == AvailableModel(id: "gemma3:12b"))

        state.selectedDetails = AvailableModel(id: "gemma3:12b", contextTokens: 131_072, acceptsImages: true, summary: "12.2B parameters")
        let info = state.selectedModelInfo(settings)
        #expect(info?.contextTokens == 131_072)
        #expect(info?.acceptsImages == true)
        #expect(info?.summary == "12.2B parameters")

        settings.stored.ollamaModel = "qwen3:14b"
        #expect(state.selectedModelInfo(settings)?.contextTokens == nil, "Details of another model aren't borrowed")
        settings.stored.ollamaModel = ""
        #expect(state.selectedModelInfo(settings) == nil)
    }

    @Test func theListReloadsWhenWhatDecidesItChanges() {
        let settings = settings(.ollama)
        let before = ModelListState.listKey(settings)
        settings.stored.ollamaModel = "something-else"
        #expect(ModelListState.listKey(settings) == before, "Choosing another model doesn't reload the list")
        settings.stored.ollamaURL = "http://other:11434"
        #expect(ModelListState.listKey(settings) != before)
        settings.stored.provider = .claude
        #expect(ModelListState.listKey(settings).hasPrefix("claude|"))
    }

    @Test func aListedWindowFillsInTheSettingOnlyForOpenAICompatible() {
        let state = ModelListState()
        state.models = [AvailableModel(id: "openai/gpt-4", contextTokens: 8_192)]
        let settings = settings(.openAICompatible)
        settings.stored.openAIModel = "openai/gpt-4"
        state.applyListedContextWindow(settings)
        #expect(settings.stored.openAIContextTokens == 8_192)

        let ollama = self.settings(.ollama)
        state.applyListedContextWindow(ollama)
        #expect(ollama.stored.openAIContextTokens == 32_768)
    }
}
