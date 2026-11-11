import SwiftUI

@main struct MyApp: App {
    @State private var session = LectureSession()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(settings)
        }
        .defaultSize(width: 900, height: 700)
    }
}
