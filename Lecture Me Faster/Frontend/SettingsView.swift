import SwiftUI

/// Settings: what most people need up top, and the technical options under a collapsed Advanced
/// section (remembered between visits).
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var modelList = ModelListState()
    @AppStorage("showsAdvancedSettings") private var showsAdvanced = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("AI model") {
                    AIModelFields(state: modelList, mode: .basic)
                }

                Section {
                    NoteDetailPicker()
                } header: {
                    Text("Notes")
                } footer: {
                    Text("You can also choose these when you add a lecture, and write notes at other levels later from a lecture's Notes tab.")
                }

                LevelModelsSection()

                Section {
                    // A button rather than an empty DisclosureGroup: in a macOS form the group's triangle
                    // can't be opened through accessibility (VoiceOver), and a button can.
                    Button {
                        withAnimation { showsAdvanced.toggle() }
                    } label: {
                        HStack {
                            Text("Advanced")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsAdvanced ? "Shown" : "Hidden")
                    .accessibilityHint("Shows server addresses, the model's limits, and slide settings")
                }

                if showsAdvanced {
                    Section("Connection and model details") {
                        AIAdvancedFields(state: modelList)
                    }

                    Section {
                        Toggle("Split long lectures without asking", isOn: $settings.stored.splitWithoutAsking)
                    } header: {
                        Text("Long lectures")
                    } footer: {
                        Text("A lecture too long for the model's context window is written in parts and combined, which takes several requests. Normally the app asks first.")
                    }

                    Section {
                        SpeedSlider()
                    } header: {
                        Text("Faster or more accurate")
                    } footer: {
                        Text("Balanced is the default and suits most lectures. Finding slides and reading their text work the same at every setting, because the faster and finer versions measured lost slides.")
                    }

                    Section {
                        Toggle("Transcribe long recordings in pieces", isOn: $settings.stored.transcribeInPieces)
                    } header: {
                        Text("Speed")
                    } footer: {
                        Text("A long recording's audio is split at pauses into up to 4 pieces transcribed at once, about 3 times faster with the same accuracy in testing. A few words can come out differently from one run to the next. Turn off to transcribe in one pass, which gives the same transcript every time. Slides are always found in parallel; that gives the same result either way.")
                    }

                    Section {
                        Toggle("Send slides to the model", isOn: $settings.stored.includeFrames)
                        Toggle("Describe slides for models that can't see images", isOn: $settings.stored.describeSlides)
                        Stepper(
                            "Send up to \(settings.stored.maxFrames) slides as images per request",
                            value: $settings.stored.maxFrames, in: 5...100, step: 5
                        )
                    } header: {
                        Text("Slides")
                    } footer: {
                        Text("Every distinct slide in a video is kept (up to 1,000 per recording, more for very long ones). Up to this many go to the model as pictures in each request, choosing the ones with the most diagrams; the rest go as the text on them, so none is left out. A long lecture written in several requests gets this many pictures in each one. Models that can't see images get every slide as text, plus a short description when Apple Intelligence is on. Fewer images cost less on paid APIs and run faster on local models.")
                    }
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
}
