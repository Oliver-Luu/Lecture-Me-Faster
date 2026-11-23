import SwiftUI

/// The sidebar: New Lecture, the folders with their lectures, the lectures in no folder (by date), and
/// Recently Deleted. Several lectures can be selected with Shift- or Command-click and deleted or moved
/// to a folder together.
struct HistorySidebar: View {
    typealias Item = ContentView.SidebarItem

    @Binding var selection: Set<Item>
    /// Called to move lectures to Recently Deleted (the caller asks first when there are several).
    var onDelete: ([UUID]) -> Void
    /// Called with a lecture and its new name.
    var onRename: (UUID, String) -> Void
    /// Called to open Settings.
    var onSettings: () -> Void

    @Environment(LectureHistory.self) private var history
    @Environment(LectureSession.self) private var session
    @State private var renaming: SavedLecture?
    @State private var newTitle = ""
    /// The folder being named in the alert: a new one, or one being renamed.
    @State private var folderEdit: FolderEdit?
    @State private var folderName = ""
    /// Folders closed with their disclosure arrow. Folders start open.
    @State private var closedFolders: Set<UUID> = []

    private enum FolderEdit {
        /// A new folder; these lectures go into it once it is named.
        case new(moving: [UUID])
        case rename(LectureFolder)
    }

    var body: some View {
        // Tag rows with plain `Item` values. Tagging with `Optional(...)` compiled but made every row
        // unselectable on macOS 27.
        List(selection: $selection) {
            currentRow
                .sidebarRowHover()
                .tag(Item.current)
            // An action, not a place: a row like New Lecture, but it opens the naming prompt and is never
            // selected.
            Button { beginNewFolder(moving: []) } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            // On the button, not its label: the list only reads a row's background from the row itself.
            .sidebarRowHover()
            .help("Make a folder to keep a course's lectures together")

            if !history.folders.isEmpty {
                Section("Folders") {
                    ForEach(history.folders) { folder in
                        DisclosureGroup(isExpanded: isOpen(folder)) {
                            ForEach(history.lectures(in: folder)) { lectureRow($0) }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                                .badge(history.lectures(in: folder).count)
                                .sidebarRowHover()
                                .contextMenu {
                                    Button("Rename…", systemImage: "pencil") { beginRenaming(folder) }
                                    Button("Delete Folder", systemImage: "trash") {
                                        history.attempt { try history.deleteFolder(folder.id) }
                                    }
                                }
                        }
                    }
                }
            }

            ForEach(Self.groups(history.unfiledLectures)) { group in
                Section(group.title) {
                    ForEach(group.lectures) { lectureRow($0) }
                }
            }
            if history.lectures.isEmpty {
                Section("Lectures") {
                    Text("Your lectures are kept here once their slides and transcript are ready.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .badge(history.recentlyDeleted.count)
                    .sidebarRowHover()
                    .tag(Item.recentlyDeleted)
            }
        }
        // One menu for the whole list: it acts on every selected row, or on the row right-clicked if that
        // row isn't selected.
        .contextMenu(forSelectionType: Item.self) { items in
            let ids = Self.lectureIDs(in: items, order: history.lectures)
            if ids.count == 1, let lecture = history.lecture(ids[0]) {
                Button("Rename…", systemImage: "pencil") { beginRenaming(lecture) }
            }
            if !ids.isEmpty {
                Menu("Move to Folder", systemImage: "folder") {
                    ForEach(history.folders) { folder in
                        Button(folder.name) { history.attempt { try history.move(ids, toFolder: folder.id) } }
                    }
                    if !history.folders.isEmpty { Divider() }
                    Button("New Folder…") { beginNewFolder(moving: ids) }
                    if ids.contains(where: { history.lecture($0)?.folderID != nil }) {
                        Button("Remove from Folder") { history.attempt { try history.move(ids, toFolder: nil) } }
                    }
                }
                // macOS menus don't turn destructive items red by themselves; foregroundStyle does.
                Button(role: .destructive) { onDelete(ids) } label: {
                    Label(ids.count == 1 ? "Delete" : "Delete \(ids.count) Lectures", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        #if os(macOS)
        // The Delete key.
        .onDeleteCommand {
            let ids = Self.lectureIDs(in: selection, order: history.lectures)
            if !ids.isEmpty { onDelete(ids) }
        }
        #endif
        // What NavigationSplitView picks anyway; stated so the sidebar looks the same everywhere it is drawn.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarSurface)
        // Settings sits at the foot of the sidebar, where chat apps keep it. ⌘, opens it too.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.small)
                    .padding(.vertical, Metrics.small)
                    .contentShape(.rect)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.small)
            .padding(.vertical, Metrics.tight)
            .keyboardShortcut(",", modifiers: .command)
            .background(Color.sidebarSurface)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("Lecture Me Faster")
        .alert("Rename Lecture", isPresented: renameIsShown, presenting: renaming) { lecture in
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { onRename(lecture.id, newTitle) }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .alert(folderAlertTitle, isPresented: folderEditIsShown) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button(folderAlertAction) { finishFolderEdit() }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Folders

    private func isOpen(_ folder: LectureFolder) -> Binding<Bool> {
        Binding { !closedFolders.contains(folder.id) } set: { open in
            if open { closedFolders.remove(folder.id) } else { closedFolders.insert(folder.id) }
        }
    }

    private func beginNewFolder(moving ids: [UUID]) {
        folderName = ""
        folderEdit = .new(moving: ids)
    }

    private func beginRenaming(_ folder: LectureFolder) {
        folderName = folder.name
        folderEdit = .rename(folder)
    }

    private func finishFolderEdit() {
        guard let edit = folderEdit else { return }
        history.attempt {
            switch edit {
            case .new(let ids):
                let folder = try history.createFolder(named: folderName)
                try history.move(ids, toFolder: folder.id)
            case .rename(let folder):
                try history.renameFolder(folder.id, to: folderName)
            }
        }
    }

    private var folderAlertTitle: String {
        if case .rename = folderEdit { "Rename Folder" } else { "New Folder" }
    }

    private var folderAlertAction: String {
        if case .rename = folderEdit { "Rename" } else { "Create" }
    }

    private var folderEditIsShown: Binding<Bool> {
        Binding { folderEdit != nil } set: { if !$0 { folderEdit = nil } }
    }

    /// A lecture's row with its tag and swipe actions, the same inside a folder and out of one.
    private func lectureRow(_ lecture: SavedLecture) -> some View {
        row(for: lecture)
            .sidebarRowHover()
            .tag(Item.lecture(lecture.id))
            .swipeActions {
                // Icon only: with a title as well, the button was laid out off-centre on macOS.
                Button(role: .destructive) { onDelete([lecture.id]) } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
            .swipeActions(edge: .leading) {
                Button { beginRenaming(lecture) } label: {
                    Label("Rename", systemImage: "pencil").labelStyle(.iconOnly)
                }
                .tint(.gray)
            }
    }

    // MARK: Lectures

    /// The lectures among selected sidebar items, in the order they appear in the history.
    static func lectureIDs(in items: Set<Item>, order lectures: [SavedLecture]) -> [UUID] {
        lectures.map(\.id).filter { items.contains(.lecture($0)) }
    }

    private func beginRenaming(_ lecture: SavedLecture) {
        newTitle = lecture.title
        renaming = lecture
    }

    private var renameIsShown: Binding<Bool> {
        Binding { renaming != nil } set: { if !$0 { renaming = nil } }
    }

    /// The lectures under a heading in the sidebar.
    struct Group: Identifiable, Equatable {
        var title: String
        var lectures: [SavedLecture]
        var id: String { title }
    }

    /// The history under "Today", "Previous 7 Days" and "Earlier", keeping the order it is in. Headings
    /// with no lectures are left out.
    static func groups(_ lectures: [SavedLecture], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let groups = [
            Group(title: "Today", lectures: lectures.filter { $0.createdAt >= today }),
            Group(title: "Previous 7 Days", lectures: lectures.filter { $0.createdAt < today && $0.createdAt >= weekAgo }),
            Group(title: "Earlier", lectures: lectures.filter { $0.createdAt < weekAgo }),
        ]
        return groups.filter { !$0.lectures.isEmpty }
    }

    /// The first row: New Lecture, or the lecture being read right now with how far along it is.
    @ViewBuilder private var currentRow: some View {
        if session.phase == .processing {
            HStack(spacing: Metrics.small) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: Metrics.tight / 2) {
                    Text(session.title)
                        .lineLimit(1)
                    Text(session.partCount > 1
                        ? "Reading, \(session.finishedPartCount) of \(session.partCount) recordings done"
                        : "Reading the recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("New Lecture", systemImage: "square.and.pencil")
        }
    }

    private func row(for lecture: SavedLecture) -> some View {
        VStack(alignment: .leading, spacing: Metrics.tight / 2) {
            Text(lecture.title)
                .lineLimit(2)
            HStack(spacing: Metrics.tight) {
                Text(lecture.createdAt, format: .dateTime.month(.abbreviated).day().year())
                if !lecture.hasNotes {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("No notes yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Metrics.tight / 2)
    }
}
