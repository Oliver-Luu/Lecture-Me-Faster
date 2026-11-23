import SwiftUI

/// Changes the model notes are written with, right from a lecture, without going to Settings. It shows the
/// same provider, model, and key fields as the New Lecture sheet; the choice is remembered, as in Settings.
struct ModelSwitcher: View {
    /// The level being written; its own model (if Settings sets one) can be changed here too.
    var detail: NoteDetail?
    /// What to do after choosing, such as rewriting the notes shown. Nil shows no button.
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var modelList = ModelListState()
    @State private var allModels = AllModelsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    AIModelFields(state: modelList, mode: .sheet)
                } header: {
                    Text("Model for notes")
                } footer: {
                    Text(problem.map { "\($0)." } ?? defaultFooter)
                }
                if let detail {
                    Section {
                        LevelModelPicker(detail: detail, models: allModels)
                    } header: {
                        Text("Model for \(detail.label) notes")
                    } footer: {
                        Text("Set a different model for this level only, or leave it the same as the default above.")
                    }
                    .task { await allModels.load(settings) }
                }
            }
            .formStyle(.grouped)
            .canvasBackground()
            if let actionTitle, let action {
                HStack {
                    Spacer()
                    Button(actionTitle) {
                        dismiss()
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
                }
                .padding([.horizontal, .bottom], Metrics.regular)
            }
        }
        .frame(width: 420)
        .frame(minHeight: 220)
    }

    private var defaultFooter: String {
        if let detail, settings.modelChoice(for: detail) != nil {
            return "The default, for levels without a model of their own. \(detail.label) notes use the model set below."
        }
        return "Used for the notes you write next, here and in new lectures. Context windows, slide settings, and other details are in Settings."
    }

    /// Why notes can't be written with the current choice (a missing model or key), if they can't.
    private var problem: String? {
        do {
            _ = try settings.configuration(for: detail)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
