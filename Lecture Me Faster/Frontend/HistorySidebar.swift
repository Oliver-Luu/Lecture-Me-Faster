import SwiftUI

/// The sidebar: New Lecture, every saved lecture, and Recently Deleted. Several lectures can be selected
/// with Shift- or Command-click and deleted together.
struct HistorySidebar: View {
    typealias Item = ContentView.SidebarItem

    @Binding var selection: Set<Item>
    /// Called to move lectures to Recently Deleted (the caller asks first when there are several).
    var onDelete: ([UUID]) -> Void
    /// Called with a lecture and its new name.
    var onRename: (UUID, String) -> Void

    @Environment(LectureHistory.self) private var history
    @Environment(LectureSession.self) private var session
    @State private var renaming: SavedLecture?
    @State private var newTitle = ""

    var body: some View {
        // Tag rows with plain `Item` values. Tagging with `Optional(...)` compiled but made every row
        // unselectable on macOS 27.
        List(selection: $selection) {
            Label(currentLabel, systemImage: "plus.circle")
                .tag(Item.current)

            Section("History") {
                ForEach(history.lectures) { lecture in
                    row(for: lecture)
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
                            .tint(.blue)
                        }
                }
                if history.lectures.isEmpty {
                    Text("Lectures you open are saved here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .badge(history.recentlyDeleted.count)
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
        .navigationTitle("Lecture Me Faster")
        .alert("Rename Lecture", isPresented: renameIsShown, presenting: renaming) { lecture in
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { onRename(lecture.id, newTitle) }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

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

    private var currentLabel: String {
        guard session.phase == .processing else { return "New Lecture" }
        return session.partCount > 1
            ? "Processing \(session.partCount) parts (\(session.finishedPartCount) done)…"
            : "Processing…"
    }

    private func row(for lecture: SavedLecture) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lecture.title)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(lecture.createdAt, format: .dateTime.month(.abbreviated).day().year())
                if !lecture.hasNotes {
                    Text("· Notes unfinished")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
