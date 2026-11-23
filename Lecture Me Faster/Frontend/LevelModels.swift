import SwiftUI

/// The models of every provider that is set up, for choosing a model per level of detail.
@Observable final class AllModelsState {
    struct Group: Identifiable {
        var name: String
        var choices: [AppSettings.ModelChoice]
        var id: String { name }
    }

    private(set) var groups: [Group] = []
    private(set) var isLoading = false

    func load(_ settings: AppSettings) async {
        isLoading = true
        defer { isLoading = false }
        let connections = settings.usableConnections
        var loaded: [Group] = []
        for connection in connections {
            let provider = connection.config.provider
            let models: [String]
            if provider == .apple {
                models = [AppleIntelligence.modelID]
            } else if let list = try? await ModelCatalog.models(for: connection.config), !list.isEmpty {
                models = list.map(\.id)
            } else if provider == .claude {
                models = FileToAI.claudeModels  // the usual models when the list can't be loaded
            } else {
                continue
            }
            loaded.append(Group(
                name: connection.name,
                choices: models.map { AppSettings.ModelChoice(provider: provider, service: connection.service, model: $0) }
            ))
        }
        groups = loaded
    }
}

/// A model for one level of detail: "Same as default", or any model of a provider that is set up.
struct LevelModelPicker: View {
    let detail: NoteDetail
    let models: AllModelsState

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker(detail.label, selection: selection) {
            Text("Default: \(settings.chosenModelName)").tag(AppSettings.ModelChoice?.none)
            // A saved choice stays listed even when its provider's list can't be loaded right now.
            if let current = settings.modelChoice(for: detail), !models.groups.contains(where: { $0.choices.contains(current) }) {
                Text(AppSettings.name(of: current)).tag(Optional(current))
            }
            ForEach(models.groups) { group in
                Section(group.name) {
                    ForEach(group.choices, id: \.self) { choice in
                        Text(choice.provider == .apple ? AIProvider.apple.label : choice.model).tag(Optional(choice))
                    }
                }
            }
        }
    }

    private var selection: Binding<AppSettings.ModelChoice?> {
        Binding { settings.modelChoice(for: detail) } set: { settings.setModelChoice($0, for: detail) }
    }
}

/// The Settings section: a model per level of detail.
struct LevelModelsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var models = AllModelsState()

    var body: some View {
        Section {
            ForEach(NoteDetail.allCases) { detail in
                LevelModelPicker(detail: detail, models: models)
            }
        } header: {
            HStack {
                Text("Model for each level of detail")
                if models.isLoading { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("For example a fast, cheap model for Key points and the strongest for Complete. A level left on Default uses the model chosen above. The menus list every provider that is set up (with its key or address).")
        }
        .task(id: connectionKey) { await models.load(settings) }
    }

    /// Reload the lists when a provider is set up or changed.
    private var connectionKey: [String] {
        settings.usableConnections.map { "\($0.name)|\($0.config.baseURL)|\($0.config.apiKey.count)" }
    }
}
