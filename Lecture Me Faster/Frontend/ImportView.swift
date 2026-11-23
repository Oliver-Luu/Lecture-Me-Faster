import SwiftUI

/// The first screen: a place to drop a lecture's files, or a button to choose them.
struct ImportView: View {
    /// True while files are being dragged over the window.
    var isTargeted: Bool
    var onChoose: () -> Void

    @Environment(LectureSession.self) private var session
    @Environment(AppSettings.self) private var settings

    @State private var isChoosingModel = false

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: Metrics.large) {
            VStack(spacing: Metrics.regular) {
                LogoMark()
                    .fill(.tint)
                    .frame(width: 50, height: 40)
                    .accessibilityHidden(true)
                Text("Which lecture do you want notes on?")
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            composer
            Label(Self.privacyLine(provider: settings.stored.provider, providerName: settings.providerName), systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.width)
            if session.phase == .summarizing {
                HStack(spacing: Metrics.small) {
                    ProgressView().controlSize(.small)
                    Text("Still writing notes for “\(session.title)”. They will be in the sidebar when done.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(Metrics.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let width: CGFloat = 640
    private static let composerRadius: CGFloat = 24

    /// Laid out like a chat app's message box: what to put in it on top, and along the bottom the button
    /// that adds files and the two choices that shape the notes (how detailed, and which model).
    private var composer: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: Metrics.large) {
            Text(isTargeted
                ? "Let go to add these files"
                : "Drop a video or audio recording here, with any slides, handouts or readings")
                .font(.title3)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            HStack(spacing: Metrics.small) {
                Button("Add Files", systemImage: "plus", action: onChoose)
                    .buttonStyle(.borderedProminent)
                    .hoverHighlight(.capsule)
                Menu {
                    Picker("Note detail", selection: $settings.stored.noteDetail) {
                        ForEach(NoteDetail.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(settings.stored.noteDetail.label, systemImage: "text.alignleft")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
                .hoverHighlight(.capsule)
                .help("How detailed the notes are")
                Button { isChoosingModel = true } label: {
                    Label(settings.chosenModelName(for: settings.stored.noteDetail), systemImage: "cpu")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.bordered)
                .hoverHighlight(.capsule)
                .help("The model that writes the notes")
                .popover(isPresented: $isChoosingModel, arrowEdge: .bottom) {
                    ModelSwitcher(detail: settings.stored.noteDetail, actionTitle: nil, action: nil)
                }
                Spacer(minLength: 0)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(Metrics.regular)
        .frame(maxWidth: Self.width)
        .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(Color.panel), in: .rect(cornerRadius: Self.composerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.composerRadius)
                .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: isTargeted ? 2 : 1)
        }
    }

    /// Where the lecture goes: nowhere with Apple Intelligence, otherwise to the chosen provider.
    static func privacyLine(provider: AIProvider, providerName: String) -> String {
        provider == .apple
            ? "Nothing leaves this device. Apple Intelligence writes the notes here too."
            : "The recording is read on this device. Its transcript and slides then go to \(providerName), which writes the notes."
    }
}

/// The app's mark, as on its icon: six bars in two groups whose heights fall from left to right, so they
/// read as a sound wave and as a fast-forward sign. `Tools/make_icon.swift` draws the icon with the same
/// numbers; change them in both.
struct LogoMark: Shape {
    static let heights: [CGFloat] = [1, 0.62, 0.28, 1, 0.62, 0.28]
    /// As shares of the mark's width.
    static let barWidth: CGFloat = 0.12
    static let gap: CGFloat = 0.056

    /// Each bar's frame, left to right, centred vertically. A bar is never shorter than it is wide.
    nonisolated static func bars(in rect: CGRect) -> [CGRect] {
        let width = rect.width * barWidth
        return heights.enumerated().map { index, height in
            let barHeight = max(rect.height * height, width)
            return CGRect(
                x: rect.minX + CGFloat(index) * rect.width * (barWidth + gap), y: rect.midY - barHeight / 2,
                width: width, height: barHeight
            )
        }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        for bar in Self.bars(in: rect) {
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: bar.width / 2, height: bar.width / 2))
        }
        return path
    }
}
