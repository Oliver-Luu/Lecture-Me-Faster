import SwiftUI

@main struct MyApp: App {
    @State private var history: LectureHistory
    @State private var session: LectureSession
    @State private var settings = AppSettings()

    init() {
        let history = LectureHistory()
        _history = State(initialValue: history)
        _session = State(initialValue: LectureSession(history: history))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(history)
                .environment(session)
                .environment(settings)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
