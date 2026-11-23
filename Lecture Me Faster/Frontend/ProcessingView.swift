import SwiftUI

/// Shown while a lecture's files are read: each step, what it is doing, and how far along it is.
struct ProcessingView: View {
    struct Stage: Equatable, Identifiable {
        enum State: Equatable {
            case waiting
            /// 0...1.
            case running(Double)
            case done
        }

        var title: String
        var detail: String
        var state: State
        var id: String { title }
    }

    @Environment(LectureSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.large) {
            VStack(alignment: .leading, spacing: Metrics.tight) {
                Text(session.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if session.partCount > 1 {
                    Text(partsLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: Metrics.regular) {
                ForEach(stages) { StageRow(stage: $0) }
            }
            Button("Cancel", role: .cancel) { session.reset() }
                .controlSize(.large)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(Metrics.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var partsLine: String {
        let done = "\(session.finishedPartCount) of \(session.partCount) recordings done"
        return session.runningParts.isEmpty ? done : "\(done). Working on \(session.currentPartName)."
    }

    private var stages: [Stage] {
        Self.stages(
            isReadingMaterials: session.isReadingMaterials, currentMaterial: session.currentMaterial,
            materialCount: session.materialCount, materialName: session.currentMaterialName,
            recordingCount: session.partCount, frameProgress: session.frameProgress,
            transcriptProgress: session.transcriptProgress
        )
    }

    /// The steps for this lecture, in the order they happen: materials are read first, then every
    /// recording's slides and speech together, and the notes are written last. Steps a lecture doesn't
    /// have (no materials, or no recording) are left out.
    static func stages(
        isReadingMaterials: Bool, currentMaterial: Int, materialCount: Int, materialName: String,
        recordingCount: Int, frameProgress: Double, transcriptProgress: Double
    ) -> [Stage] {
        var stages: [Stage] = []
        if materialCount > 0 {
            stages.append(isReadingMaterials
                ? Stage(
                    title: "Read the materials",
                    detail: "File \(min(currentMaterial + 1, materialCount)) of \(materialCount): \(materialName)",
                    state: .running(Double(currentMaterial) / Double(materialCount))
                )
                : Stage(
                    title: "Read the materials",
                    detail: materialCount == 1 ? "1 file read" : "\(materialCount) files read",
                    state: .done
                ))
        }
        if recordingCount > 0 {
            func state(_ progress: Double) -> Stage.State {
                if isReadingMaterials { return .waiting }
                return progress >= 1 ? .done : .running(max(progress, 0))
            }
            stages.append(Stage(
                title: "Find the slides", detail: "Keeps one picture of each slide in the video",
                state: state(frameProgress)
            ))
            stages.append(Stage(
                title: "Transcribe the speech", detail: "On this device",
                state: state(transcriptProgress)
            ))
        }
        stages.append(Stage(title: "Write the notes", detail: "Starts when the steps above finish", state: .waiting))
        return stages
    }
}

/// One step of `ProcessingView`: a marker for its state, its name, a bar while it runs, and a detail line.
struct StageRow: View {
    let stage: ProcessingView.Stage

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.medium) {
            marker
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: Metrics.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.title)
                        .font(.headline)
                        .foregroundStyle(stage.state == .waiting ? .secondary : .primary)
                    Spacer()
                    if case .running(let progress) = stage.state {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if case .running(let progress) = stage.state {
                    ProgressView(value: min(progress, 1))
                        .accessibilityLabel(stage.title)
                }
                Text(stage.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        switch stage.state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            Image(systemName: "circle.dotted.circle").foregroundStyle(.tint)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        }
    }
}
