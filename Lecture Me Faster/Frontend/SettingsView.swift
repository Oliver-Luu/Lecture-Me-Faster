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
                Section("Model") {
                    AIModelFields(state: modelList, mode: .basic)
                }

                Section {
                    NoteDetailPicker()
                } header: {
                    Text("Notes")
                } footer: {
                    Text("This is the level written first for a new lecture. Any other level can be written later from the lecture's Notes tab.")
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
                        Text("A lecture too long for the model's context window is written in parts and then combined, which takes several requests. The app asks first unless this is on.")
                    }

                    Section {
                        SpeedSlider()
                    } header: {
                        Text("Faster or more accurate")
                    } footer: {
                        Text("Balanced suits most lectures. Slides are found and read the same way at every setting, because the faster and finer versions lost slides when measured.")
                    }

                    Section {
                        Toggle("Transcribe long recordings in pieces", isOn: $settings.stored.transcribeInPieces)
                    } header: {
                        Text("Transcription")
                    } footer: {
                        Text("Splits a long recording at pauses into up to 4 pieces and transcribes them together, about 3 times faster with the same accuracy in testing. A few words can differ from one run to the next. Turn this off for one pass that gives the same transcript every time.")
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
                        Text("Every distinct slide in a video is kept. Up to this many go to the model as pictures in each request, starting with the ones that have the most diagrams. The rest go as the text on them, so none is left out. Models that can't see images get every slide as text, plus a short description when Apple Intelligence is on. Fewer pictures cost less on paid services and run faster on local models.")
                    }
                }
            }
            .formStyle(.grouped)
            .canvasBackground()
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
