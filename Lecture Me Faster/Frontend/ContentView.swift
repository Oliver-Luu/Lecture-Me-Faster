import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// What the sidebar has selected.
    enum SidebarItem: Hashable {
        /// The import screen, or the lecture being processed right now.
        case current
        case lecture(UUID)
        case recentlyDeleted
    }

    @Environment(LectureSession.self) private var session
    @Environment(LectureHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    /// Usually one item; several when lectures are Shift- or Command-clicked in the sidebar.
    @State private var selection: Set<SidebarItem> = [.current]
    /// Lectures waiting for "Move N lectures to Recently Deleted?" to be confirmed.
    @State private var lecturesAwaitingDeletion: [UUID]?
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var newLecture: NewLectureFiles?
    @State private var unsupportedFiles: [String] = []
    @State private var filesAwaitingConfirmation: [URL]?

    var body: some View {
        NavigationSplitView {
            HistorySidebar(selection: $selection, onDelete: requestDeletion, onRename: rename)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // On the detail pane only, so dropping onto the sidebar does nothing.
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    open(urls)
                    return true
                }
                .toolbar {
                    ToolbarItem {
                        Button("New Lecture", systemImage: "plus", action: startNewLecture)
                    }
                    ToolbarItem {
                        Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                    }
                }
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.movie, .audio] + DocumentToText.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                open(urls)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(item: $newLecture) { files in
            NewLectureSheet(files: files) { recordings, materials, title in
                start(recordings, materials: materials, title: title)
            }
        }
        .alert("Some Files Can't Be Used", isPresented: unsupportedIsShown) {
            Button("OK") {}
        } message: {
            Text("\(unsupportedFiles.joined(separator: ", ")). The app reads video, audio, PDF, Word (.docx), PowerPoint (.pptx), text, and image files. Export other documents (.doc, .ppt, Pages, Keynote) as PDF.")
        }
        .confirmationDialog(
            "Stop “\(session.title)”?", isPresented: replaceIsConfirming, presenting: filesAwaitingConfirmation
        ) { urls in
            Button("Stop and Start New Lecture", role: .destructive) { proceed(with: urls) }
        } message: { _ in
            Text(session.savedID == nil
                 ? "It is still being processed and will be lost."
                 : "Its slides and transcript are saved, but its notes are unfinished. You can write them later from its Notes tab.")
        }
        .alert("Couldn't Update History", isPresented: errorIsShown) {
            Button("OK") {}
        } message: {
            Text(history.lastError ?? "")
        }
        // Once the lecture being processed is saved, follow it to its row in the history.
        .onChange(of: session.savedID) { _, id in
            if selection == [.current], let id { selection = [.lecture(id)] }
        }
        // Picking "New Lecture" in the sidebar clears a finished lecture (it is safe in the history).
        .onChange(of: selection) { _, items in
            if items == [.current], session.savedID != nil, !session.isBusy { session.reset() }
        }
        .confirmationDialog(
            "Move \(lecturesAwaitingDeletion?.count ?? 0) lectures to Recently Deleted?",
            isPresented: deletionIsConfirming, presenting: lecturesAwaitingDeletion
        ) { ids in
            Button("Move \(ids.count) Lectures to Recently Deleted", role: .destructive) { moveToRecentlyDeleted(ids) }
        } message: { _ in
            Text("You can restore them from Recently Deleted for \(LectureHistory.retentionDays) days.")
        }
    }

    /// The one selected sidebar item, or nil when several (or none) are selected.
    private var selectedItem: SidebarItem? {
        selection.count == 1 ? selection.first : nil
    }

    @ViewBuilder private var detail: some View {
        if selection.count > 1 {
            multipleSelection
        } else {
            singleDetail
        }
    }

    /// Shown when several lectures are selected in the sidebar.
    private var multipleSelection: some View {
        let ids = HistorySidebar.lectureIDs(in: selection, order: history.lectures)
        return ContentUnavailableView {
            Label("\(ids.count) Lectures Selected", systemImage: "rectangle.stack")
        } description: {
            Text("Delete moves them to Recently Deleted, where they can be restored for \(LectureHistory.retentionDays) days.")
        } actions: {
            Button("Delete \(ids.count) Lectures", systemImage: "trash", role: .destructive) { requestDeletion(ids) }
                .disabled(ids.isEmpty)
        }
        .navigationTitle("\(ids.count) Lectures")
    }

    @ViewBuilder private var singleDetail: some View {
        switch selectedItem {
        case .lecture(let id) where id == session.savedID:
            // The lecture this session is processing or just finished, shown live.
            LectureResultView()
                .renamableTitle(session.title) { rename(id, to: $0) }
        case .lecture(let id):
            SavedLectureView(id: id).id(id)
        case .recentlyDeleted:
            RecentlyDeletedView()
        default:
            currentLecture
        }
    }

    @ViewBuilder private var currentLecture: some View {
        Group {
            switch session.phase {
            case .idle:
                importPrompt
            case .processing:
                processingView
            default:
                if session.savedID == nil {
                    // Failed before it could be saved (the error is shown), or saving itself failed.
                    LectureResultView()
                } else {
                    // You picked New Lecture while this lecture's notes are still being written.
                    importPrompt
                }
            }
        }
        .navigationTitle(session.phase == .processing ? session.title : "New Lecture")
    }

    private var importPrompt: some View {
        ContentUnavailableView {
            Label("Drop a lecture here", systemImage: "waveform.badge.plus")
        } description: {
            Text("A video or audio recording (or several parts of one), plus any slides, handouts, or readings as PDF, Word, PowerPoint, text, or images. \(settings.stored.provider == .apple ? "Everything, including writing the notes with Apple Intelligence, happens on this device." : "Everything is read on this device, then sent to \(settings.providerName) for notes.")")
            if session.phase == .summarizing {
                Label("Writing notes for “\(session.title)”…", systemImage: "text.badge.plus")
                    .padding(.top, 8)
            }
        } actions: {
            Button("Choose Files…") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if session.isReadingMaterials {
                ProgressView(
                    "Reading materials (\(session.currentMaterial + 1) of \(session.materialCount)): \(session.currentMaterialName)",
                    value: Double(session.currentMaterial), total: Double(max(session.materialCount, 1))
                )
                .lineLimit(1)
                .truncationMode(.middle)
            } else if session.partCount > 0 {
                if session.partCount > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(session.finishedPartCount) of \(session.partCount) parts done")
                            .font(.headline)
                        if !session.runningParts.isEmpty {
                            Text("Working on \(session.currentPartName)")
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                ProgressView("Finding slides in the video", value: min(session.frameProgress, 1))
                ProgressView("Transcribing audio on device", value: min(session.transcriptProgress, 1))
            }
            Button("Cancel", role: .cancel) { session.reset() }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 420)
        .padding(32)
    }

    private var errorIsShown: Binding<Bool> {
        Binding { history.lastError != nil } set: { if !$0 { history.lastError = nil } }
    }

    private var replaceIsConfirming: Binding<Bool> {
        Binding { filesAwaitingConfirmation != nil } set: { if !$0 { filesAwaitingConfirmation = nil } }
    }

    private var unsupportedIsShown: Binding<Bool> {
        Binding { !unsupportedFiles.isEmpty } set: { if !$0 { unsupportedFiles = [] } }
    }

    /// Opens the New Lecture sheet, where the lecture is named, its parts ordered, and the model and note
    /// detail chosen. Files the app can't read are listed in an alert.
    /// If a lecture is still being processed, asks before stopping it.
    private func open(_ urls: [URL]) {
        unsupportedFiles = urls
            .filter { !LectureSession.isLectureFile($0) && DocumentToText.kind(of: $0) == nil }
            .map(\.lastPathComponent)
        let usable = urls.filter { LectureSession.isLectureFile($0) || DocumentToText.kind(of: $0) != nil }
        guard !usable.isEmpty else { return }
        // Files arriving while the sheet or the "Stop?" question is up join the files already there,
        // so several drops (or one drop delivered in pieces) never lose the earlier files.
        if let newLecture {
            newLecture.add(usable)
        } else if session.isBusy || filesAwaitingConfirmation != nil {
            filesAwaitingConfirmation = (filesAwaitingConfirmation ?? []) + usable
        } else {
            proceed(with: usable)
        }
    }

    private func proceed(with urls: [URL]) {
        if let newLecture {
            newLecture.add(urls)
        } else {
            newLecture = NewLectureFiles(urls)
        }
    }

    private func start(_ recordings: [URL], materials: [URL] = [], title: String) {
        selection = [.current]
        session.start(recordings, materials: materials, title: title, settings: settings)
    }

    /// Never cancels work in progress: notes still being written keep coming in the background.
    private func startNewLecture() {
        if !session.isBusy { session.reset() }
        selection = [.current]
    }

    private func rename(_ id: UUID, to title: String) {
        history.attempt { try history.rename(id, to: title) }
        if session.savedID == id, let saved = history.lecture(id) { session.rename(to: saved.title) }
    }

    private var deletionIsConfirming: Binding<Bool> {
        Binding { lecturesAwaitingDeletion != nil } set: { if !$0 { lecturesAwaitingDeletion = nil } }
    }

    /// One lecture goes to Recently Deleted at once (it can be restored); several ask first.
    private func requestDeletion(_ ids: [UUID]) {
        if ids.count > 1 {
            lecturesAwaitingDeletion = ids
        } else {
            moveToRecentlyDeleted(ids)
        }
    }

    private func moveToRecentlyDeleted(_ ids: [UUID]) {
        if let live = session.savedID, ids.contains(live), !session.isBusy { session.reset() }
        selection.subtract(ids.map(SidebarItem.lecture))
        if selection.isEmpty { selection = [.current] }
        history.attempt { try history.moveToRecentlyDeleted(ids) }
    }
}

#Preview {
    let history = LectureHistory(root: .temporaryDirectory.appending(path: "PreviewLectures"))
    ContentView()
        .environment(history)
        .environment(LectureSession(history: history))
        .environment(AppSettings())
}
