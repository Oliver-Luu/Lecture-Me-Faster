import Foundation
import Observation
import Security

@Observable final class AppSettings {
    struct Stored: Codable {
        /// Apple Intelligence: free, on the device, and on every Apple silicon Mac with it turned on.
        var provider = AIProvider.apple
        var claudeModel = FileToAI.claudeModels[0]
        var ollamaURL = "http://localhost:11434"
        var ollamaModel = ""
        /// The address of "Other (OpenAI-compatible)". Listed services have fixed addresses.
        var openAIURL = "http://localhost:1234/v1"
        /// Which OpenAI-format service is chosen (`OpenAIService.id`).
        var openAIService = OpenAIService.custom.id
        /// The model chosen for the current OpenAI-format service.
        var openAIModel = ""
        /// The model last chosen for each other service, so switching back finds it again.
        var serviceModels: [String: String] = [:]
        /// Services added to the Provider menu with "Add Provider…" (beyond the featured ones).
        var addedServices: [String] = []
        var includeFrames = true
        var maxFrames = 30
        var noteDetail = NoteDetail.detailed
        /// OpenAI-compatible servers can't be asked for their context window, so the user says.
        var openAIContextTokens = 32_768
        /// Ollama's context window: 0 uses what the model reports (capped at
        /// `LongLectures.maxLocalContextTokens`); any other value is used as is, for models that don't
        /// report one (Ollama's MLX builds) or to go above the cap.
        var ollamaContextTokens = 0
        /// Split lectures too long for one request without asking first.
        var splitWithoutAsking = false
        /// Transcribe a long recording in up to 4 pieces at once: about 3x faster with the same accuracy,
        /// but a few words can differ from one run to the next. Off: one pass, the same every time.
        var transcribeInPieces = true
        /// For a model that can't see images: add Apple Intelligence's short description of each slide's
        /// visuals to its text (slower; off sends only the text read from the slides).
        var describeSlides = true
        /// A model for particular levels of detail (keyed by `NoteDetail.rawValue`), e.g. a small fast model
        /// for Key points and the strongest for Complete. Levels not listed use the model chosen above.
        var levelModels: [String: ModelChoice] = [:]

        init() {}

        /// Missing keys keep their defaults, so adding a setting doesn't throw away the settings saved by an
        /// older version of the app.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
            }
            let defaults = Stored()
            provider = value(.provider, defaults.provider)
            claudeModel = value(.claudeModel, defaults.claudeModel)
            ollamaURL = value(.ollamaURL, defaults.ollamaURL)
            ollamaModel = value(.ollamaModel, defaults.ollamaModel)
            openAIURL = value(.openAIURL, defaults.openAIURL)
            openAIService = value(.openAIService, defaults.openAIService)
            openAIModel = value(.openAIModel, defaults.openAIModel)
            serviceModels = value(.serviceModels, defaults.serviceModels)
            addedServices = value(.addedServices, defaults.addedServices)
            includeFrames = value(.includeFrames, defaults.includeFrames)
            maxFrames = value(.maxFrames, defaults.maxFrames)
            noteDetail = value(.noteDetail, defaults.noteDetail)
            openAIContextTokens = value(.openAIContextTokens, defaults.openAIContextTokens)
            ollamaContextTokens = value(.ollamaContextTokens, defaults.ollamaContextTokens)
            splitWithoutAsking = value(.splitWithoutAsking, defaults.splitWithoutAsking)
            transcribeInPieces = value(.transcribeInPieces, defaults.transcribeInPieces)
            describeSlides = value(.describeSlides, defaults.describeSlides)
            levelModels = value(.levelModels, defaults.levelModels)
        }
    }

    /// One model at one provider (and, for OpenAI-format providers, one service).
    struct ModelChoice: Codable, Hashable, Sendable {
        var provider: AIProvider
        /// `OpenAIService.id`, for `.openAICompatible` only.
        var service: String?
        var model: String
    }

    // MARK: Faster or more accurate

    /// The positions of the Faster ↔ Most accurate slider. Each sets settings whose trade-off is known;
    /// slide finding itself is the same at every position, because its faster and finer variants were
    /// measured to lose slides (2 s sampling skipped a 160 s stretch of board work; 0.5 s overflowed the
    /// slide cap; Vision's fast text mode read nothing on real slides).
    enum SpeedPreset: Int, CaseIterable, Identifiable {
        case faster, balanced, accurate
        var id: Self { self }

        var label: String {
            switch self {
            case .faster: "Faster"
            case .balanced: "Balanced"
            case .accurate: "Most accurate"
            }
        }

        /// Slides sent as pictures in each request.
        var imagesPerRequest: Int {
            switch self {
            case .faster: 10
            case .balanced: 30
            case .accurate: 60
            }
        }

        var transcribeInPieces: Bool { self != .accurate }
        var describeSlides: Bool { self != .faster }

        var summary: String {
            switch self {
            case .faster:
                "Up to 10 slides go to the model as pictures in each request, so requests are smaller, quicker and cheaper. Models that can't see images get the slides' text only. Long recordings are transcribed in pieces at once."
            case .balanced:
                "Up to 30 slides as pictures in each request. Models that can't see images also get a short description of each slide's visuals. Long recordings are transcribed in pieces at once, about 3 times faster with the same accuracy in testing."
            case .accurate:
                "Up to 60 slides as pictures in each request, so the model sees more diagrams; requests are bigger and slower, and cost more on paid services. Slide descriptions are on. Audio is transcribed in one pass, which gives the same transcript every time (about 3 times slower for a long recording)."
            }
        }
    }

    /// The slider position matching the current settings, or nil when they were changed by hand (Custom).
    var speedPreset: SpeedPreset? {
        SpeedPreset.allCases.first {
            $0.imagesPerRequest == stored.maxFrames && $0.transcribeInPieces == stored.transcribeInPieces
                && $0.describeSlides == stored.describeSlides
        }
    }

    func apply(_ preset: SpeedPreset) {
        stored.maxFrames = preset.imagesPerRequest
        stored.transcribeInPieces = preset.transcribeInPieces
        stored.describeSlides = preset.describeSlides
    }

    // MARK: Model for each level

    func modelChoice(for detail: NoteDetail?) -> ModelChoice? {
        detail.flatMap { stored.levelModels[String($0.rawValue)] }
    }

    func setModelChoice(_ choice: ModelChoice?, for detail: NoteDetail) {
        stored.levelModels[String(detail.rawValue)] = choice
    }

    /// The configuration for writing notes at `detail`: its own model if one is set, else the default.
    func configuration(for detail: NoteDetail?) throws -> AIConfiguration {
        guard let choice = modelChoice(for: detail) else { return try configuration() }
        let level = detail?.label ?? ""
        switch choice.provider {
        case .apple:
            if let reason = AppleIntelligence.unavailableReason { throw Problem.unavailable(reason) }
            return Self.appleConfiguration
        case .claude:
            guard !anthropicKey.isEmpty else { throw Problem.missing("add your Anthropic API key (\(level) notes use Claude)") }
            return AIConfiguration(provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!, model: choice.model, apiKey: anthropicKey)
        case .ollama:
            guard let url = URL(string: stored.ollamaURL), url.host() != nil else {
                throw Problem.missing("enter a valid Ollama server address (\(level) notes use Ollama)")
            }
            return AIConfiguration(provider: .ollama, baseURL: url, model: choice.model, apiKey: "")
        case .openAICompatible:
            let service = OpenAIService.with(id: choice.service ?? OpenAIService.custom.id)
            guard let url = serviceURL(service) else { throw Problem.missing("enter a valid address for \(service.name)") }
            let key = serviceKey(service)
            if service.needsKey, key.isEmpty { throw Problem.missing("add your \(service.name) API key (\(level) notes use it)") }
            return AIConfiguration(provider: .openAICompatible, baseURL: url, model: choice.model, apiKey: key)
        }
    }

    /// The model notes at `detail` will be written with, for showing ("Claude: claude-haiku-5-5").
    func chosenModelName(for detail: NoteDetail?) -> String {
        guard let choice = modelChoice(for: detail) else { return chosenModelName }
        return Self.name(of: choice)
    }

    static func name(of choice: ModelChoice) -> String {
        switch choice.provider {
        case .apple: AIProvider.apple.label
        case .openAICompatible: "\(OpenAIService.with(id: choice.service ?? OpenAIService.custom.id).name): \(choice.model)"
        default: "\(choice.provider.label): \(choice.model)"
        }
    }

    /// The default model as a choice, so a level can be set to it.
    var defaultModelChoice: ModelChoice? {
        switch stored.provider {
        case .apple: ModelChoice(provider: .apple, model: AppleIntelligence.modelID)
        case .claude: ModelChoice(provider: .claude, model: stored.claudeModel)
        case .ollama: stored.ollamaModel.isEmpty ? nil : ModelChoice(provider: .ollama, model: stored.ollamaModel)
        case .openAICompatible:
            stored.openAIModel.isEmpty ? nil : ModelChoice(provider: .openAICompatible, service: stored.openAIService, model: stored.openAIModel)
        }
    }

    /// Every provider that is set up well enough to list its models (an address, and a key where one is
    /// needed), for choosing a model per level.
    var usableConnections: [(name: String, service: String?, config: AIConfiguration)] {
        var out: [(String, String?, AIConfiguration)] = []
        if AppleIntelligence.unavailableReason == nil { out.append((AIProvider.apple.label, nil, Self.appleConfiguration)) }
        if !anthropicKey.isEmpty {
            out.append((AIProvider.claude.label, nil, AIConfiguration(provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!, model: "", apiKey: anthropicKey)))
        }
        if let url = URL(string: stored.ollamaURL), url.host() != nil {
            out.append((AIProvider.ollama.label, nil, AIConfiguration(provider: .ollama, baseURL: url, model: "", apiKey: "")))
        }
        for service in menuServices {
            guard let url = serviceURL(service) else { continue }
            let key = serviceKey(service)
            if service.needsKey, key.isEmpty { continue }
            out.append((service.name, service.id, AIConfiguration(provider: .openAICompatible, baseURL: url, model: "", apiKey: key)))
        }
        return out
    }

    private func serviceURL(_ service: OpenAIService) -> URL? {
        guard let url = URL(string: service.baseURL ?? stored.openAIURL), url.host() != nil else { return nil }
        return url
    }

    private func serviceKey(_ service: OpenAIService) -> String {
        let typed = key(for: service)
        return typed.isEmpty && persists ? DevKeys.value(service.devKeyName) : typed
    }

    enum Problem: LocalizedError {
        case missing(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .missing(let what): "Open Settings and \(what)."
            case .unavailable(let reason): reason
            }
        }
    }

    var stored: Stored {
        didSet {
            if persists { UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: "settings") }
        }
    }
    var claudeKey: String {
        didSet { if persists { Keychain.set(claudeKey, for: "claude") } }
    }
    /// Each OpenAI-format service's key, by service ID, kept in the Keychain.
    private(set) var serviceKeys: [String: String]

    /// False for settings made with `init(unsaved:)`.
    private let persists: Bool

    /// The user's saved settings. Changes are saved as they are made.
    init() {
        let saved = UserDefaults.standard.data(forKey: "settings")
        stored = saved.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        claudeKey = Keychain.get("claude")
        serviceKeys = Dictionary(uniqueKeysWithValues: OpenAIService.all.map { ($0.id, Keychain.get($0.keychainAccount)) })
        persists = true
    }

    /// Settings that are never saved, start with no API keys, and ignore Secrets.env. For tests, which
    /// run inside the app and would otherwise read and overwrite the user's real settings, or use the
    /// developer's real keys.
    init(unsaved stored: Stored) {
        self.stored = stored
        claudeKey = ""
        serviceKeys = [:]
        persists = false
    }

    // MARK: OpenAI-format services

    var openAIService: OpenAIService { OpenAIService.with(id: stored.openAIService) }

    /// The key typed in for the current OpenAI-format service.
    var openAIKey: String {
        get { serviceKeys[stored.openAIService] ?? "" }
        set { setKey(newValue, for: openAIService) }
    }

    func key(for service: OpenAIService) -> String { serviceKeys[service.id] ?? "" }

    func setKey(_ key: String, for service: OpenAIService) {
        serviceKeys[service.id] = key
        if persists { Keychain.set(key, for: service.keychainAccount) }
    }

    /// Switches to another OpenAI-format service, keeping each service's model.
    func chooseService(_ service: OpenAIService) {
        guard service.id != stored.openAIService || stored.provider != .openAICompatible else { return }
        var updated = stored
        updated.serviceModels[updated.openAIService] = updated.openAIModel
        updated.provider = .openAICompatible
        updated.openAIService = service.id
        updated.openAIModel = updated.serviceModels[service.id] ?? ""
        stored = updated
    }

    /// Adds a service to the Provider menu and switches to it.
    func addService(_ service: OpenAIService) {
        if !service.isFeatured, !stored.addedServices.contains(service.id) {
            stored.addedServices.append(service.id)
        }
        chooseService(service)
    }

    /// Takes a service out of the Provider menu. Its key and model are kept in case it's added again.
    /// If it was the one in use, the app switches to Apple Intelligence, the free default.
    func removeService(_ service: OpenAIService) {
        var updated = stored
        updated.addedServices.removeAll { $0 == service.id }
        if updated.provider == .openAICompatible, updated.openAIService == service.id {
            updated.serviceModels[service.id] = updated.openAIModel
            updated.provider = .apple
        }
        stored = updated
    }

    /// The services in the Provider menu right now.
    var menuServices: [OpenAIService] {
        OpenAIService.menuServices(
            added: stored.addedServices,
            current: stored.provider == .openAICompatible ? stored.openAIService : nil
        )
    }

    /// The name of where notes are sent, e.g. "Google Gemini" or "Claude".
    var providerName: String {
        stored.provider == .openAICompatible ? openAIService.name : stored.provider.label
    }

    // MARK: Keys and addresses

    /// Apple Intelligence has no address or key; the URL is a placeholder that is never requested.
    static let appleConfiguration = AIConfiguration(
        provider: .apple, baseURL: URL(string: "apple-intelligence://on-device")!, model: AppleIntelligence.modelID, apiKey: ""
    )

    private var anthropicKey: String { claudeKey.isEmpty && persists ? DevKeys.anthropic : claudeKey }

    private var currentServiceKey: String {
        let typed = openAIKey
        return typed.isEmpty && persists ? DevKeys.value(openAIService.devKeyName) : typed
    }

    private var currentServiceURL: URL? {
        guard let url = URL(string: openAIService.baseURL ?? stored.openAIURL), url.host() != nil else { return nil }
        return url
    }

    /// The chosen provider's address and key, without requiring a model: enough to ask which models it
    /// offers. Nil when the address is invalid, or when a key is needed and missing.
    func connection() -> AIConfiguration? {
        switch stored.provider {
        case .apple:
            return Self.appleConfiguration
        case .claude:
            guard !anthropicKey.isEmpty else { return nil }
            return AIConfiguration(provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!, model: "", apiKey: anthropicKey)
        case .ollama:
            guard let url = URL(string: stored.ollamaURL), url.host() != nil else { return nil }
            return AIConfiguration(provider: .ollama, baseURL: url, model: "", apiKey: "")
        case .openAICompatible:
            guard let url = currentServiceURL, !(openAIService.needsKey && currentServiceKey.isEmpty) else { return nil }
            return AIConfiguration(provider: .openAICompatible, baseURL: url, model: "", apiKey: currentServiceKey)
        }
    }

    /// The model notes will be written with, for showing next to a lecture ("Claude: claude-opus-5-5").
    var chosenModelName: String {
        let model: String
        switch stored.provider {
        case .apple: return AIProvider.apple.label
        case .claude: model = stored.claudeModel
        case .ollama: model = stored.ollamaModel
        case .openAICompatible: model = stored.openAIModel
        }
        return model.isEmpty ? providerName : "\(providerName): \(model)"
    }

    /// Changes whenever anything that decides how a lecture's notes are planned changes: the provider,
    /// the model, its key or address, the context window settings, and the slide settings. A split
    /// proposal on screen is worked out again when it changes.
    var planningKey: [String] {
        [
            stored.provider.rawValue, stored.claudeModel, stored.ollamaURL, stored.ollamaModel,
            stored.openAIService, stored.openAIURL, stored.openAIModel,
            String(stored.openAIContextTokens), String(stored.ollamaContextTokens),
            String(stored.maxFrames), String(stored.includeFrames),
            claudeKey, openAIKey,
            stored.levelModels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.provider.rawValue)/\($0.value.service ?? "")/\($0.value.model)" }.joined(separator: ","),
        ]
    }

    func configuration() throws -> AIConfiguration {
        switch stored.provider {
        case .apple:
            if let reason = AppleIntelligence.unavailableReason { throw Problem.unavailable(reason) }
            return Self.appleConfiguration
        case .claude:
            guard !anthropicKey.isEmpty else { throw Problem.missing("add your Anthropic API key") }
            return AIConfiguration(
                provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!,
                model: stored.claudeModel, apiKey: anthropicKey
            )
        case .ollama:
            guard let url = URL(string: stored.ollamaURL), url.host() != nil else {
                throw Problem.missing("enter a valid Ollama server address")
            }
            guard !stored.ollamaModel.isEmpty else { throw Problem.missing("choose an Ollama model") }
            return AIConfiguration(provider: .ollama, baseURL: url, model: stored.ollamaModel, apiKey: "")
        case .openAICompatible:
            let service = openAIService
            guard let url = currentServiceURL else { throw Problem.missing("enter a valid server address") }
            if service.needsKey, currentServiceKey.isEmpty { throw Problem.missing("add your \(service.name) API key") }
            guard !stored.openAIModel.isEmpty else { throw Problem.missing("choose a \(service.name) model") }
            return AIConfiguration(provider: .openAICompatible, baseURL: url, model: stored.openAIModel, apiKey: currentServiceKey)
        }
    }
}

/// Developer keys from the git-ignored Secrets.env, which is bundled into Debug builds only.
nonisolated enum DevKeys {
    static var anthropic: String { value("ANTHROPIC_API_KEY") }
    static func value(_ name: String) -> String { values[name] ?? "" }

    private static let values: [String: String] = {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "env"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
        #else
        return [:]
        #endif
    }()

    /// Parses `KEY=value` lines, skipping blanks, `#` comments, and keys with no value.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !value.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

nonisolated enum Keychain {
    private static func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "LectureMeFaster",
            kSecAttrAccount: account,
        ]
    }

    static func get(_ account: String) -> String {
        var item: CFTypeRef?
        let lookup = query(account).merging([kSecReturnData: true]) { $1 }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        SecItemAdd(query(account).merging([kSecValueData: Data(value.utf8)]) { $1 } as CFDictionary, nil)
    }
}
