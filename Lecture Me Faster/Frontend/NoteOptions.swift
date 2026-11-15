import SwiftUI

/// The model list for the chosen provider and what's known about the chosen model, shared by the
/// basic and advanced parts of Settings so they agree and the list loads once.
@Observable final class ModelListState {
    var models: [AvailableModel] = []
    /// Why the list is empty or is the built-in one, if it is.
    var listProblem: String?
    var isLoading = false
    /// Extra facts about the chosen model that its list entry doesn't give (Ollama's /api/show).
    var selectedDetails: AvailableModel?

    /// Changes whenever something that decides the list changes.
    static func listKey(_ settings: AppSettings) -> String {
        let stored = settings.stored
        switch stored.provider {
        case .apple: return "apple"
        case .claude: return "claude|\(settings.claudeKey)"
        case .ollama: return "ollama|\(stored.ollamaURL)"
        case .openAICompatible: return "openai|\(stored.openAIService)|\(stored.openAIURL)|\(settings.openAIKey)"
        }
    }

    static func selectedModelID(_ settings: AppSettings) -> String {
        switch settings.stored.provider {
        case .apple: AppleIntelligence.modelID
        case .claude: settings.stored.claudeModel
        case .ollama: settings.stored.ollamaModel
        case .openAICompatible: settings.stored.openAIModel
        }
    }

    /// The list entry for the chosen model, with anything learned from asking about it filled in.
    func selectedModelInfo(_ settings: AppSettings) -> AvailableModel? {
        let id = Self.selectedModelID(settings)
        guard !id.isEmpty else { return nil }
        let listed = models.first { $0.id == id }
        let extra = selectedDetails?.id == id ? selectedDetails : nil
        var info = listed ?? AvailableModel(id: id)
        info.displayName = info.displayName ?? extra?.displayName
        info.contextTokens = extra?.contextTokens ?? info.contextTokens
        info.maxOutputTokens = info.maxOutputTokens ?? extra?.maxOutputTokens
        info.acceptsImages = extra?.acceptsImages ?? info.acceptsImages
        info.summary = info.summary ?? extra?.summary
        return info
    }

    func loadModels(_ settings: AppSettings) async {
        let provider = settings.stored.provider
        if provider == .apple {
            // One model on the device; the only thing to report is whether it can be used.
            models = [AppleIntelligence.model]
            listProblem = AppleIntelligence.unavailableReason
            return
        }
        guard let connection = settings.connection() else {
            models = []
            listProblem = switch provider {
            case .apple: AppleIntelligence.unavailableReason
            case .claude: "Add your API key to see every model your account can use. Showing the usual models for now."
            case .ollama: "Enter the address of your Ollama server."
            case .openAICompatible:
                settings.openAIService.needsKey
                    ? "Add your \(settings.openAIService.name) API key to see its models."
                    : "Enter the server's address."
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await ModelCatalog.models(for: connection)
            guard settings.stored.provider == provider else { return }  // switched while loading
            models = loaded
            listProblem = loaded.isEmpty ? Self.emptyMessage(provider) : nil
        } catch {
            guard settings.stored.provider == provider, !Task.isCancelled else { return }
            models = []
            listProblem = Self.failureMessage(provider, error)
        }
    }

    /// Asks about the chosen model when its list entry isn't enough: always for Ollama (the list has no
    /// window or vision), and for Claude only when the list didn't include it.
    func loadSelectedDetails(_ settings: AppSettings) async {
        let id = Self.selectedModelID(settings)
        let provider = settings.stored.provider
        guard let connection = settings.connection(), !id.isEmpty,
              provider == .ollama || (provider == .claude && !models.contains { $0.id == id })
        else { return }
        if let details = try? await ModelCatalog.details(of: id, for: connection), Self.selectedModelID(settings) == id {
            selectedDetails = details
        }
    }

    /// Servers that say how big each model's window is (OpenRouter) fill in the Context window setting.
    func applyListedContextWindow(_ settings: AppSettings) {
        guard settings.stored.provider == .openAICompatible,
              let tokens = AIModelFields.listedContextWindow(for: settings.stored.openAIModel, in: models),
              tokens != settings.stored.openAIContextTokens
        else { return }
        settings.stored.openAIContextTokens = tokens
    }

    private static func emptyMessage(_ provider: AIProvider) -> String {
        switch provider {
        case .apple: "Apple Intelligence isn't available right now."
        case .ollama: "Ollama is running but has no models. Pull one in Terminal, e.g. “ollama pull gemma3:12b”."
        case .claude: "Anthropic returned no models for this key."
        case .openAICompatible: "The server listed no models. Type the model name."
        }
    }

    private static func failureMessage(_ provider: AIProvider, _ error: any Error) -> String {
        switch provider {
        case .apple: "Apple Intelligence isn't available right now (\(error.localizedDescription))"
        case .ollama: "Can't reach Ollama at this address. Make sure it's running."
        case .claude: "Couldn't load Anthropic's model list (\(error.localizedDescription)) Showing the usual models."
        case .openAICompatible: "This server didn't give a model list (\(error.localizedDescription)) Type the model name."
        }
    }
}

/// Provider and model pickers. They edit the saved settings directly, so a choice made for one lecture
/// is remembered for the next. The model list comes from the provider itself (`ModelCatalog`) and
/// reloads when the provider, server, or key changes.
struct AIModelFields: View {
    enum Mode {
        /// The New Lecture sheet: kept short, with server addresses and keys only when they are
        /// missing or don't work, since the sheet has no Advanced section.
        case sheet
        /// The main part of Settings: what most people need (provider, model, Claude key). Server
        /// addresses, other keys, and the model's limits are under Advanced (`AIAdvancedFields`).
        case basic
    }

    var state: ModelListState
    var mode: Mode

    @Environment(AppSettings.self) private var settings
    @State private var isAddingProvider = false

    var body: some View {
        @Bindable var settings = settings

        Picker("Provider", selection: providerChoice) {
            Text(AIProvider.apple.label).tag(ProviderChoice.apple)
            Text(AIProvider.ollama.label).tag(ProviderChoice.ollama)
            Text(AIProvider.claude.label).tag(ProviderChoice.claude)
            ForEach(settings.menuServices) { service in
                Text(service.name).tag(ProviderChoice.service(service.id))
            }
            Text("Add Provider…").tag(ProviderChoice.addProvider)
        }
        .sheet(isPresented: $isAddingProvider) { AddProviderSheet() }
        // Reload whenever anything that decides the list changes; the short wait skips the in-between
        // states while an address or key is being typed.
        .task(id: ModelListState.listKey(settings)) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await state.loadModels(settings)
        }
        switch settings.stored.provider {
        case .apple: EmptyView()  // one model, nothing to choose; its description and any problem show below
        case .ollama: ollamaFields
        case .claude: claudeFields
        case .openAICompatible: openAIFields
        }
        ModelDetailsView(lines: Self.describeBrief(
            state.selectedModelInfo(settings), provider: settings.stored.provider
        ))
        .task(id: "\(ModelListState.listKey(settings))|\(ModelListState.selectedModelID(settings))") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await state.loadSelectedDetails(settings)
        }
        if let problem = state.listProblem {
            Text(mode == .basic && settings.stored.provider == .ollama ? problem + " The server address is under Advanced." : problem)
                .font(.callout)
                .foregroundStyle(.secondary)
            if mode == .sheet {
                Button(state.isLoading ? "Loading Models…" : "Refresh Model List") {
                    Task { await state.loadModels(settings) }
                }
                .disabled(state.isLoading)
            }
        }
    }

    /// The Provider menu lists each OpenAI-format service by name, though they share one provider.
    /// `addProvider` is the "Add Provider…" item: choosing it opens the list instead of selecting it.
    enum ProviderChoice: Hashable {
        case apple, ollama, claude
        case service(String)
        case addProvider
    }

    private var providerChoice: Binding<ProviderChoice> {
        Binding {
            switch settings.stored.provider {
            case .apple: .apple
            case .ollama: .ollama
            case .claude: .claude
            case .openAICompatible: .service(settings.stored.openAIService)
            }
        } set: { choice in
            switch choice {
            case .apple: settings.stored.provider = .apple
            case .ollama: settings.stored.provider = .ollama
            case .claude: settings.stored.provider = .claude
            case .service(let id): settings.chooseService(OpenAIService.with(id: id))
            case .addProvider: isAddingProvider = true
            }
        }
    }

    // MARK: Ollama

    @ViewBuilder
    private var ollamaFields: some View {
        @Bindable var settings = settings

        if mode == .sheet, state.listProblem != nil || !Self.isValid(settings.stored.ollamaURL) {
            TextField("Server", text: $settings.stored.ollamaURL)
                .autocorrectionDisabled()
        }
        if state.models.isEmpty {
            TextField("Model", text: $settings.stored.ollamaModel, prompt: Text("e.g. gemma3:12b"))
                .autocorrectionDisabled()
        } else {
            Picker("Model", selection: $settings.stored.ollamaModel) {
                Text("Choose…").tag("")
                ForEach(Self.including(settings.stored.ollamaModel, in: state.models)) { Text($0.label).tag($0.id) }
            }
        }
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeFields: some View {
        @Bindable var settings = settings

        // Settings always offers the key (everyone using Claude needs one); the sheet only when missing.
        if mode == .basic || (settings.claudeKey.isEmpty && DevKeys.anthropic.isEmpty) {
            SecureField(
                "API key", text: $settings.claudeKey,
                prompt: Text(DevKeys.anthropic.isEmpty ? "sk-ant-…" : "Using the key from Secrets.env")
            )
        }
        Picker("Model", selection: $settings.stored.claudeModel) {
            ForEach(Self.including(settings.stored.claudeModel, in: claudeChoices)) { model in
                Text(model.label).tag(model.id)
            }
        }
    }

    /// Anthropic's list for this key, or the built-in list until it loads (or if it can't).
    private var claudeChoices: [AvailableModel] {
        state.models.isEmpty ? FileToAI.claudeModels.map { AvailableModel(id: $0) } : state.models
    }

    // MARK: OpenAI-compatible

    @ViewBuilder
    private var openAIFields: some View {
        @Bindable var settings = settings

        let service = settings.openAIService
        // "Other" needs an address; listed services have their own.
        if service == .custom, mode == .basic || !Self.isValid(settings.stored.openAIURL) {
            TextField("Server address", text: $settings.stored.openAIURL, prompt: Text("https://…/v1"))
                .autocorrectionDisabled()
        }
        // Hosted services need a key, so it's always here (not under Advanced). Local servers rarely do.
        if service.needsKey || service == .custom, mode == .basic || settings.openAIKey.isEmpty {
            SecureField(
                "API key", text: $settings.openAIKey,
                prompt: Text(Self.keyPrompt(for: service))
            )
        }
        // A text field rather than a menu: some servers (OpenRouter) list hundreds of models.
        HStack {
            TextField("Model", text: $settings.stored.openAIModel)
                .autocorrectionDisabled()
            if !state.models.isEmpty {
                Menu("\(state.models.count) Available") {
                    ForEach(state.models) { model in
                        Button(model.label) { settings.stored.openAIModel = model.id }
                    }
                }
                .fixedSize()
            }
        }
        // Picked from the menu, typed, or the list just loaded: fill in the window if the list says.
        .onChange(of: settings.stored.openAIModel, initial: true) { state.applyListedContextWindow(settings) }
        .onChange(of: state.models) { state.applyListedContextWindow(settings) }
    }

    // MARK: Describing the chosen model

    /// The full details, for Advanced: what the model is, how much it reads at once, how long its notes
    /// can be, and whether it can see the slides.
    static func describe(
        _ model: AvailableModel?, provider: AIProvider, openAIContextSetting: Int, ollamaContextSetting: Int = 0
    ) -> [String] {
        guard let model else { return ["Choose a model to see what it can do."] }
        var lines: [String] = []

        if let summary = summaryLine(model, provider: provider) { lines.append(summary) }

        switch (provider, model.contextTokens) {
        case (.ollama, let tokens) where ollamaContextSetting > 0:
            let reported = tokens.map { "the model reports \($0.formatted())" } ?? "the model doesn't report one"
            lines.append("Context window: \(ollamaContextSetting.formatted()) tokens, from the Context window setting (\(reported)).")
        case (.ollama, let tokens?) where tokens > LongLectures.maxLocalContextTokens:
            lines.append("Context window: \(LongLectures.maxLocalContextTokens.formatted()) tokens used. The model supports \(tokens.formatted()), but larger windows need more memory on this device.")
        case (.openAICompatible, let tokens?):
            lines.append("Context window: \(tokens.formatted()) tokens, from the server's model list.")
        case (.openAICompatible, nil):
            lines.append("Context window: \(openAIContextSetting.formatted()) tokens, from the Context window setting.")
        case (_, let tokens?):
            lines.append("Context window: \(tokens.formatted()) tokens.")
        case (.claude, nil):
            lines.append("Context window: shown once Anthropic's model list loads.")
        case (.apple, nil):
            lines.append("Context window: shown once Apple Intelligence is ready.")
        case (_, nil):
            lines.append(provider == .ollama
                ? "Context window: the model doesn't report one, so \(LongLectures.fallbackContextTokens.formatted()) tokens is assumed. Set it under Context window if you know it."
                : "Context window: unknown, so \(LongLectures.fallbackContextTokens.formatted()) tokens is assumed.")
        }
        lines.append("Lectures that don't fit are written in parts.")

        if var output = model.maxOutputTokens {
            if provider == .claude { output = min(output, 64_000) }  // the app's max_tokens for Claude
            lines.append("Notes can be up to \(output.formatted()) tokens long per request.")
        }

        if let images = imagesLine(model) { lines.append(images) }
        return lines
    }

    /// The short version, for everyone: what the model is, and a warning if it can't see the slides.
    static func describeBrief(_ model: AvailableModel?, provider: AIProvider) -> [String] {
        guard let model else { return ["Choose a model."] }
        var lines: [String] = []
        if let summary = summaryLine(model, provider: provider) { lines.append(summary) }
        if model.acceptsImages == false, let images = imagesLine(model) { lines.append(images) }
        return lines
    }

    private static func summaryLine(_ model: AvailableModel, provider: AIProvider) -> String? {
        if let summary = model.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.count > 220 ? String(summary.prefix(220)) + "…" : summary
        }
        return provider == .claude ? claudeFamily(model.id) : nil
    }

    private static func imagesLine(_ model: AvailableModel) -> String? {
        switch model.acceptsImages {
        case true?: "Can see the slides."
        case false?: "Can't see images: slides are sent as the text read from them, so diagrams may be missed."
        case nil: nil
        }
    }

    /// A line about a Claude model's family when Anthropic's list gives no description.
    static func claudeFamily(_ id: String) -> String? {
        if id.contains("fable") || id.contains("mythos") { return "Anthropic's most capable model, and the most expensive." }
        if id.contains("opus") { return "Opus writes the most thorough notes and costs the most of the usual three." }
        if id.contains("sonnet") { return "Sonnet balances quality and cost." }
        if id.contains("haiku") { return "Haiku is the fastest and cheapest." }
        return nil
    }

    // MARK: Helpers

    static func keyPrompt(for service: OpenAIService) -> String {
        if !DevKeys.value(service.devKeyName).isEmpty { return "Using the key from Secrets.env" }
        return service.needsKey ? "Your \(service.name) API key" : "Optional for local servers"
    }

    static func isValid(_ address: String) -> Bool {
        URL(string: address)?.host() != nil
    }

    /// The window a server's model list gives for a model, if it gives one.
    static func listedContextWindow(for model: String, in models: [AvailableModel]) -> Int? {
        models.first { $0.id == model }?.contextTokens.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The Context window menu's sizes, plus the current value if it isn't one of them (for example a
    /// size filled in from a model list), so the menu can show it.
    static func contextOptions(including current: Int) -> [Int] {
        let presets = [8_192, 16_384, 32_768, 65_536, 131_072, 200_000, 1_000_000]
        return presets.contains(current) || current <= 0 ? presets : (presets + [current]).sorted()
    }

    /// The Ollama Context window menu: Automatic (0), then the usual sizes up to 256K, plus the current
    /// value if it isn't one of them.
    static func ollamaContextOptions(including current: Int) -> [Int] {
        let presets = [0, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144]
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    /// The list, plus the current choice if the list doesn't have it, so the menu can still show it.
    static func including(_ selected: String, in models: [AvailableModel]) -> [AvailableModel] {
        guard !selected.isEmpty, !models.contains(where: { $0.id == selected }) else { return models }
        return [AvailableModel(id: selected)] + models
    }
}

/// "Add Provider…": the providers not in the menu by default. Adding one puts it in the Provider menu
/// and switches to it; removing takes it out again (its key and model are kept).
struct AddProviderSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(OpenAIService.addable) { service in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text(service.blurb)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.stored.addedServices.contains(service.id) {
                                Button("Remove") { settings.removeService(service) }
                            } else {
                                Button("Add") {
                                    settings.addService(service)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                } footer: {
                    Text("Added providers appear in the Provider menu. Keys you enter are kept in the Keychain even if you remove the provider.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}

/// The technical half of the model settings, under Advanced in Settings: server addresses, keys that
/// are optional, the context window setting, the chosen model's limits, and reloading the list.
struct AIAdvancedFields: View {
    var state: ModelListState

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        switch settings.stored.provider {
        case .apple:
            Text("Runs on this device. Nothing about your lectures is sent over the network.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ollama:
            TextField("Ollama server", text: $settings.stored.ollamaURL)
                .autocorrectionDisabled()
            Picker("Context window", selection: $settings.stored.ollamaContextTokens) {
                ForEach(AIModelFields.ollamaContextOptions(including: settings.stored.ollamaContextTokens), id: \.self) { tokens in
                    Text(tokens == 0 ? "Automatic" : "\(tokens.formatted()) tokens").tag(tokens)
                }
            }
            Text("Automatic uses what the model reports, up to \(LongLectures.maxLocalContextTokens.formatted()) tokens. Choose a size for models that don't report one, such as Ollama's MLX versions, and keep it within what the model supports. A bigger window lets a long lecture go in one request but needs more memory; the app only uses as much as each lecture needs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .claude:
            Text("Your API key is stored in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .openAICompatible:
            let service = settings.openAIService
            if let address = service.baseURL {
                LabeledContent("Address", value: address)
                    .textSelection(.enabled)
            }
            if !service.needsKey, service != .custom {
                SecureField("API key", text: $settings.openAIKey, prompt: Text(AIModelFields.keyPrompt(for: service)))
            }
            Text("Your API key is stored in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Context window", selection: $settings.stored.openAIContextTokens) {
                ForEach(AIModelFields.contextOptions(including: settings.stored.openAIContextTokens), id: \.self) { tokens in
                    Text("\(tokens.formatted()) tokens").tag(tokens)
                }
            }
            if AIModelFields.listedContextWindow(for: settings.stored.openAIModel, in: state.models) == settings.stored.openAIContextTokens {
                Text("Set from the server's model list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Works with LM Studio, llama.cpp, OpenRouter, and other servers that speak the OpenAI chat API. Set the context window to what the model is loaded with; longer lectures are split to fit.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ModelDetailsView(lines: AIModelFields.describe(
            state.selectedModelInfo(settings), provider: settings.stored.provider,
            openAIContextSetting: settings.stored.openAIContextTokens,
            ollamaContextSetting: settings.stored.ollamaContextTokens
        ))
        Button(state.isLoading ? "Loading Models…" : "Refresh Model List") {
            Task { await state.loadModels(settings) }
        }
        .disabled(state.isLoading)
    }
}

/// The facts about the chosen model, under the model picker.
private struct ModelDetailsView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Brief-to-Thorough slider and a description of the chosen level.
struct NoteDetailPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Slider(value: step, in: 0...Double(NoteDetail.allCases.count - 1), step: 1) {
            Text("Note detail")
        } minimumValueLabel: {
            Text("Brief")
        } maximumValueLabel: {
            Text("Thorough")
        }
        LabeledContent(settings.stored.noteDetail.label) {
            Text(settings.stored.noteDetail.summary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// The slider works in Doubles; the setting is a NoteDetail.
    private var step: Binding<Double> {
        Binding {
            Double(settings.stored.noteDetail.rawValue)
        } set: {
            settings.stored.noteDetail = NoteDetail(rawValue: Int($0.rounded())) ?? .detailed
        }
    }
}
