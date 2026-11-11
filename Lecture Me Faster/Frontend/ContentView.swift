import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LectureSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var isImporting = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle: importPrompt
                case .processing: processingView
                default: LectureResultView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(session.title.isEmpty ? "Lecture Me Faster" : session.title)
            .toolbar {
                if session.phase != .idle {
                    ToolbarItem {
                        Button("New Lecture", systemImage: "plus") { session.reset() }
                    }
                }
                ToolbarItem {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result {
                session.start(url, settings: settings)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.start(url, settings: settings)
            return true
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private var importPrompt: some View {
        ContentUnavailableView {
            Label("Drop a lecture here", systemImage: "waveform.badge.plus")
        } description: {
            Text("Video or audio. Slides and speech are extracted on this device, then sent to \(settings.stored.provider.label) for notes.")
        } actions: {
            Button("Choose File…") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressView("Finding slides in the video", value: min(session.frameProgress, 1))
            ProgressView("Transcribing audio on device", value: min(session.transcriptProgress, 1))
            Button("Cancel", role: .cancel) { session.reset() }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 420)
        .padding(32)
    }
}

#Preview {
    ContentView()
        .environment(LectureSession())
        .environment(AppSettings())
}
