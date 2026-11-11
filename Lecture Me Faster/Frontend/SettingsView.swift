import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var ollamaModels: [String] = []
    @State private var ollamaError: String?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("AI model") {
                    Picker("Provider", selection: $settings.stored.provider) {
                        ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                    }
                    switch settings.stored.provider {
                    case .ollama: ollamaFields
                    case .claude: claudeFields
                    case .openAICompatible: openAIFields
                    }
                }

                Section {
                    Toggle("Send slides to the model", isOn: $settings.stored.includeFrames)
                    Stepper(
                        "Up to \(settings.stored.maxFrames) slides per lecture",
                        value: $settings.stored.maxFrames, in: 5...100, step: 5
                    )
                } header: {
                    Text("Slides")
                } footer: {
                    Text("Slides need a model that can see images. Fewer slides cost less on paid APIs and run faster on local models. The slide limit applies to the next lecture you open.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
    }

    @ViewBuilder
    private var ollamaFields: some View {
        @Bindable var settings = settings

        TextField("Server", text: $settings.stored.ollamaURL)
            .autocorrectionDisabled()
        if ollamaModels.isEmpty {
            TextField("Model", text: $settings.stored.ollamaModel, prompt: Text("e.g. gemma3:12b"))
                .autocorrectionDisabled()
        } else {
            Picker("Model", selection: $settings.stored.ollamaModel) {
                Text("Choose…").tag("")
                ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
            }
        }
        if let ollamaError {
            Text(ollamaError)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Button("Refresh Model List") {
            Task { await loadOllamaModels() }
        }
        .task(id: settings.stored.ollamaURL) { await loadOllamaModels() }
    }

    @ViewBuilder
    private var claudeFields: some View {
        @Bindable var settings = settings

        SecureField(
            "API key", text: $settings.claudeKey,
            prompt: Text(DevKeys.anthropic.isEmpty ? "sk-ant-…" : "Using the key from Secrets.env")
        )
        Picker("Model", selection: $settings.stored.claudeModel) {
            ForEach(FileToAI.claudeModels, id: \.self) { Text($0).tag($0) }
        }
        Text("Opus writes the best notes; Sonnet and Haiku cost less. Your key is stored in the Keychain.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var openAIFields: some View {
        @Bindable var settings = settings

        TextField("Base URL", text: $settings.stored.openAIURL)
            .autocorrectionDisabled()
        TextField("Model", text: $settings.stored.openAIModel)
            .autocorrectionDisabled()
        SecureField(
            "API key", text: $settings.openAIKey,
            prompt: Text(DevKeys.openAICompatible.isEmpty ? "Optional for local servers" : "Using the key from Secrets.env")
        )
        Text("Works with LM Studio, llama.cpp, OpenRouter, and other servers that speak the OpenAI chat API.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func loadOllamaModels() async {
        guard let url = URL(string: settings.stored.ollamaURL), url.host() != nil else {
            ollamaModels = []
            ollamaError = "Enter the address of your Ollama server."
            return
        }
        do {
            ollamaModels = try await FileToAI.ollamaModels(baseURL: url)
            ollamaError = ollamaModels.isEmpty
                ? "Ollama is running but has no models. Pull one in Terminal, e.g. “ollama pull gemma3:12b”."
                : nil
        } catch {
            ollamaModels = []
            ollamaError = "Can't reach Ollama at this address. Make sure it's running."
        }
    }
}
