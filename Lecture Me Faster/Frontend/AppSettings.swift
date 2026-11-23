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
        /// The context window of the current OpenAI-format service's model. Most such servers can't be
        /// asked, so the user says; a server whose model list gives it (OpenRouter, Gemini) fills it in.
        var openAIContextTokens = 32_768
        /// The window last set for each other service, so one service's size is never used for another.
        var serviceContextTokens: [String: Int] = [:]
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
            serviceContextTokens = value(.serviceContextTokens, defaults.serviceContextTokens)
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
        return try configuration(
            provider: choice.provider, service: OpenAIService.with(id: choice.service ?? OpenAIService.custom.id),
            model: choice.model, level: detail?.label ?? ""
        )
    }

    /// The Context window setting that applies to notes at `detail`: the setting of the service its model
    /// is on. (Used only when that service's model list doesn't give the model's window.)
    func contextSetting(for detail: NoteDetail?) -> Int {
        guard let choice = modelChoice(for: detail), choice.provider == .openAICompatible else {
            return stored.openAIContextTokens
        }
        return contextSetting(forService: choice.service ?? OpenAIService.custom.id)
    }

    func contextSetting(forService id: String) -> Int {
        id == stored.openAIService
            ? stored.openAIContextTokens
            : stored.serviceContextTokens[id] ?? Stored().openAIContextTokens
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

    /// Every provider that is set up well enough to list its models (an address, and a key where one is
    /// needed), for choosing a model per level.
    var usableConnections: [(name: String, service: String?, config: AIConfiguration)] {
        let providers: [(String, AIProvider, OpenAIService?)] =
            [AIProvider.apple, .claude, .ollama].map { ($0.label, $0, nil) }
            + menuServices.map { ($0.name, .openAICompatible, $0) }
        return providers.compactMap { name, provider, service in
            guard let config = try? configuration(
                provider: provider, service: service ?? .custom, model: "", level: nil, needsModel: false
            ) else { return nil }
            return (name, service?.id, config)
        }
    }

    /// Where requests for one model go: the one place that knows each provider's address and key, and
    /// what to say when one is missing. `level` names the level whose own model this is, for the message.
    private func configuration(
        provider: AIProvider, service: OpenAIService, model: String, level: String?, needsModel: Bool = true
    ) throws -> AIConfiguration {
        func note(_ user: String) -> String { level.map { " (\($0) notes use \(user))" } ?? "" }
        switch provider {
        case .apple:
            if let reason = AppleIntelligence.unavailableReason { throw Problem.unavailable(reason) }
            return Self.appleConfiguration
        case .claude:
            guard !anthropicKey.isEmpty else { throw Problem.missing("add your Anthropic API key" + note("Claude")) }
            return AIConfiguration(provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!, model: model, apiKey: anthropicKey)
        case .ollama:
            guard let url = URL(string: stored.ollamaURL), url.host() != nil else {
                throw Problem.missing("enter a valid Ollama server address" + note("Ollama"))
            }
            if needsModel, model.isEmpty { throw Problem.missing("choose an Ollama model") }
            return AIConfiguration(provider: .ollama, baseURL: url, model: model, apiKey: "")
        case .openAICompatible:
            guard let url = URL(string: service.baseURL ?? stored.openAIURL), url.host() != nil else {
                throw Problem.missing(level == nil ? "enter a valid server address" : "enter a valid address for \(service.name)")
            }
            let key = serviceKey(service)
            if service.needsKey, key.isEmpty { throw Problem.missing("add your \(service.name) API key" + note("it")) }
            if needsModel, model.isEmpty { throw Problem.missing("choose a \(service.name) model") }
            return AIConfiguration(provider: .openAICompatible, baseURL: url, model: model, apiKey: key)
        }
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
        updated.serviceContextTokens[updated.openAIService] = updated.openAIContextTokens
        updated.provider = .openAICompatible
        updated.openAIService = service.id
        updated.openAIModel = updated.serviceModels[service.id] ?? ""
        updated.openAIContextTokens = updated.serviceContextTokens[service.id] ?? Stored().openAIContextTokens
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

    /// The chosen provider's address and key, without requiring a model: enough to ask which models it
    /// offers. Nil when the address is invalid, or when a key is needed and missing.
    func connection() -> AIConfiguration? {
        // Listed even when it can't be used right now, so the model list can say why.
        if stored.provider == .apple { return Self.appleConfiguration }
        return try? configuration(provider: stored.provider, service: openAIService, model: "", level: nil, needsModel: false)
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
            stored.serviceContextTokens.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
            String(stored.maxFrames), String(stored.includeFrames),
            claudeKey, openAIKey,
            stored.levelModels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.provider.rawValue)/\($0.value.service ?? "")/\($0.value.model)" }.joined(separator: ","),
        ]
    }

    func configuration() throws -> AIConfiguration {
        let model = switch stored.provider {
        case .apple: AppleIntelligence.modelID
        case .claude: stored.claudeModel
        case .ollama: stored.ollamaModel
        case .openAICompatible: stored.openAIModel
        }
        return try configuration(provider: stored.provider, service: openAIService, model: model, level: nil)
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
