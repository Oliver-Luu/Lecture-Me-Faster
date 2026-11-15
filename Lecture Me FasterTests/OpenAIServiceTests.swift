import Foundation
import Testing
@testable import Lecture_Me_Faster

/// OpenAI-format services (OpenAI, Gemini, DeepSeek, OpenRouter, LM Studio, Other): addresses, keys
/// kept per service, models kept per service, and test settings never using real keys.
@MainActor
struct OpenAIServiceTests {
    private func settings(_ service: OpenAIService = .custom) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIService = service.id
        return AppSettings(unsaved: stored)
    }

    @Test func servicesUseTheirDocumentedAddresses() {
        #expect(OpenAIService.all.map(\.id) == ["openai", "gemini", "deepseek", "openrouter", "lmstudio", "custom"])
        #expect(OpenAIService.openAI.baseURL == "https://api.openai.com/v1")
        #expect(OpenAIService.gemini.baseURL == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(OpenAIService.deepSeek.baseURL == "https://api.deepseek.com")
        #expect(OpenAIService.openRouter.baseURL == "https://openrouter.ai/api/v1")
        #expect(OpenAIService.lmStudio.baseURL == "http://localhost:1234/v1")
        #expect(OpenAIService.custom.baseURL == nil)
        #expect(OpenAIService.with(id: "unknown") == .custom)
    }

    @Test func otherKeepsTheKeychainEntryUsedBeforeServicesExisted() {
        #expect(OpenAIService.custom.keychainAccount == "openai-compatible")
        #expect(OpenAIService.gemini.keychainAccount == "service.gemini")
        #expect(Set(OpenAIService.all.map(\.keychainAccount)).count == OpenAIService.all.count)
    }

    @Test func aHostedServiceAsksForItsKeyByName() throws {
        let settings = settings(.gemini)
        settings.stored.openAIModel = "gemini-flash"
        #expect(throws: AppSettings.Problem.self) { try settings.configuration() }
        #expect((try? settings.configuration()) == nil)
        do { _ = try settings.configuration() } catch {
            #expect(error.localizedDescription == "Open Settings and add your Google Gemini API key.")
        }
        #expect(settings.connection() == nil, "No model list without a key")

        settings.openAIKey = "g-key"
        let config = try settings.configuration()
        #expect(config.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(config.apiKey == "g-key")
        #expect(config.model == "gemini-flash")
        #expect(config.provider == .openAICompatible)
    }

    @Test func localAndOtherServersDontNeedAKey() throws {
        let lmStudio = settings(.lmStudio)
        lmStudio.stored.openAIModel = "qwen"
        #expect(try lmStudio.configuration().apiKey == "")

        let other = settings(.custom)
        other.stored.openAIURL = "http://my-server:8000/v1"
        other.stored.openAIModel = "m"
        #expect(try other.configuration().baseURL.absoluteString == "http://my-server:8000/v1", "Other uses the typed address")
    }

    @Test func eachServiceKeepsItsOwnKeyAndModel() {
        let settings = settings(.gemini)
        settings.openAIKey = "gemini-key"
        settings.stored.openAIModel = "gemini-flash"

        settings.chooseService(.deepSeek)
        #expect(settings.openAIKey == "", "DeepSeek doesn't get Gemini's key")
        #expect(settings.stored.openAIModel == "", "…or its model")
        settings.openAIKey = "deepseek-key"
        settings.stored.openAIModel = "deepseek-chat"

        settings.chooseService(.gemini)
        #expect(settings.openAIKey == "gemini-key")
        #expect(settings.stored.openAIModel == "gemini-flash")
        #expect(settings.key(for: .deepSeek) == "deepseek-key")
    }

    @Test func choosingAServiceFromAnotherProviderSwitchesProvider() {
        var stored = AppSettings.Stored()
        stored.provider = .claude
        let settings = AppSettings(unsaved: stored)
        settings.chooseService(.openRouter)
        #expect(settings.stored.provider == .openAICompatible)
        #expect(settings.openAIService == .openRouter)
        #expect(settings.providerName == "OpenRouter")
        settings.stored.provider = .claude
        #expect(settings.providerName == "Claude")
    }

    @Test func testSettingsNeverUseSecretsEnvKeys() {
        // Even if this Debug build bundles a Secrets.env with real keys, unsaved settings must not use them.
        var stored = AppSettings.Stored()
        stored.provider = .claude
        let claude = AppSettings(unsaved: stored)
        #expect(claude.connection() == nil)
        #expect((try? claude.configuration()) == nil)

        let openAI = settings(.openAI)
        openAI.stored.openAIModel = "gpt"
        #expect((try? openAI.configuration()) == nil)
    }

    @Test func settingsFromBeforeServicesLoadAsOther() throws {
        let stored = try JSONDecoder().decode(AppSettings.Stored.self, from: Data(#"{"provider":"openAICompatible","openAIURL":"http://box:1234/v1","openAIModel":"m"}"#.utf8))
        #expect(stored.openAIService == "custom")
        #expect(stored.openAIURL == "http://box:1234/v1")
        #expect(stored.openAIModel == "m")
        #expect(stored.serviceModels.isEmpty)
    }

    @Test func geminiModelsAreListedUnderItsOpenAIPath() async throws {
        let host = "gemini.service.test"
        let log = MockModelServer.start(host: host) { _ in (200, #"{"object":"list","data":[{"id":"models/gemini-flash","object":"model"}]}"#) }
        defer { MockModelServer.stop(host: host) }
        let config = AIConfiguration(provider: .openAICompatible, baseURL: URL(string: "https://\(host)/v1beta/openai")!, model: "", apiKey: "k")

        let models = try await ModelCatalog.models(for: config)
        #expect(models.map(\.id) == ["models/gemini-flash"])
        #expect(log.requestURLs.map(\.path) == ["/v1beta/openai/models"])
    }
}

/// The short Provider menu and "Add Provider…".
@MainActor
struct ProviderMenuTests {
    private func settings(_ provider: AIProvider = .claude) -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = provider
        return AppSettings(unsaved: stored)
    }

    @Test func theMenuStartsWithOnlyTheMainProviders() {
        #expect(settings().menuServices.map(\.id) == ["openai", "gemini"], "Plus Ollama and Claude, which aren't services")
        #expect(OpenAIService.addable.map(\.id) == ["deepseek", "openrouter", "lmstudio", "custom"])
    }

    @Test func addingAProviderPutsItInTheMenuAndUsesIt() {
        let settings = settings()
        settings.addService(.deepSeek)
        #expect(settings.menuServices.map(\.id) == ["openai", "gemini", "deepseek"])
        #expect(settings.stored.provider == .openAICompatible)
        #expect(settings.openAIService == .deepSeek)

        settings.addService(.deepSeek)
        #expect(settings.stored.addedServices == ["deepseek"], "Adding twice doesn't add it twice")
    }

    @Test func removingTheProviderInUseSwitchesToTheFreeDefault() {
        let settings = settings()
        settings.addService(.openRouter)
        settings.openAIKey = "or-key"
        settings.stored.openAIModel = "some/model"

        settings.removeService(.openRouter)
        #expect(settings.stored.provider == .apple, "Apple Intelligence is the free default")
        #expect(!settings.menuServices.contains(.openRouter))
        #expect(settings.key(for: .openRouter) == "or-key", "Its key is kept")

        settings.addService(.openRouter)
        #expect(settings.stored.openAIModel == "some/model", "…and its model, if it's added again")
    }

    @Test func removingAnotherProviderLeavesTheCurrentChoiceAlone() {
        let settings = settings()
        settings.addService(.lmStudio)
        settings.stored.provider = .claude
        settings.removeService(.lmStudio)
        #expect(settings.stored.provider == .claude)
    }

    @Test func theProviderInUseIsAlwaysInTheMenu() {
        // Settings saved before the short menu existed, using a service that isn't featured.
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIService = "custom"
        let settings = AppSettings(unsaved: stored)
        #expect(settings.menuServices.map(\.id) == ["openai", "gemini", "custom"])
        #expect(OpenAIService.menuServices(added: [], current: nil).map(\.id) == ["openai", "gemini"])
    }

    @Test func addedProvidersAreSaved() throws {
        let stored = try JSONDecoder().decode(AppSettings.Stored.self, from: Data(#"{"addedServices":["deepseek","lmstudio"]}"#.utf8))
        #expect(stored.addedServices == ["deepseek", "lmstudio"])
        let old = try JSONDecoder().decode(AppSettings.Stored.self, from: Data("{}".utf8))
        #expect(old.addedServices.isEmpty)
    }
}
