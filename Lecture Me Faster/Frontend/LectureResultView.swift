import ImageIO
import SwiftUI

struct LectureResultView: View {
    private enum Tab: String, CaseIterable {
        case notes = "Notes", transcript = "Transcript", slides = "Slides"
    }

    @Environment(LectureSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var tab = Tab.notes

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding()

            switch tab {
            case .notes: notes
            case .transcript: transcript
            case .slides: slides
            }
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: session.summary)
                    .disabled(session.phase != .done)
            }
            ToolbarItem {
                Button("Summarize Again", systemImage: "arrow.clockwise") {
                    session.resummarize(settings: settings)
                }
                .disabled(session.transcript.isEmpty || session.phase == .summarizing)
            }
        }
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case .failed(let message) = session.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                MarkdownView(text: session.summary)
                if session.phase == .summarizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(session.summary.isEmpty ? "The model is reading the lecture…" : "Writing…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private var transcript: some View {
        List(session.transcript) { segment in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timestamp(segment.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(segment.text)
                    .textSelection(.enabled)
            }
        }
        .overlay {
            if session.transcript.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote")
            }
        }
    }

    private var slides: some View {
        ScrollView {
            if session.distinctFrameCount > session.frames.count {
                Text("Kept \(session.frames.count) of \(session.distinctFrameCount) distinct frames. Raise the limit in Settings to send more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(session.frames) { frame in
                    VStack(alignment: .leading, spacing: 4) {
                        FrameImage(jpeg: frame.jpeg)
                        Text(timestamp(frame.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .overlay {
            if session.frames.isEmpty {
                ContentUnavailableView("No slides", systemImage: "photo.on.rectangle", description: Text("Audio-only lectures have no frames."))
            }
        }
    }
}

private struct FrameImage: View {
    let jpeg: Data

    var body: some View {
        if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 6))
        }
    }
}
