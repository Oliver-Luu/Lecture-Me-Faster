import SwiftUI

/// Shows a lecture from the history in its own session, so a lecture being processed in the
/// background keeps running while you read an older one.
struct SavedLectureView: View {
    let id: UUID

    @Environment(LectureHistory.self) private var history
    @State private var viewer: LectureSession?

    var body: some View {
        Group {
            if let viewer {
                LectureResultView()
                    .environment(viewer)
                    .renamableTitle(viewer.title) { name in
                        history.attempt { try history.rename(id, to: name) }
                    }
            } else if history.lecture(id) == nil {
                EmptyState("Lecture not found", "It may have been deleted for good.")
            } else {
                // Opening takes a few milliseconds, so a spinner here would only flash.
                Color.canvas
            }
        }
        // Follow a rename made in the sidebar.
        .onChange(of: history.lecture(id)?.title) { _, title in
            if let title { viewer?.rename(to: title) }
        }
        .task {
            guard let lecture = history.lecture(id) else { return }
            let session = LectureSession(history: history)
            session.open(lecture)
            viewer = session
        }
    }
}
