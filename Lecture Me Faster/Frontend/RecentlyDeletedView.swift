import SwiftUI

/// Lectures moved out of the history. They can be restored or deleted for good, one at a time or
/// several at once (Shift- or Command-click), and each is deleted automatically
/// `LectureHistory.retentionDays` days after it was deleted.
struct RecentlyDeletedView: View {
    @Environment(LectureHistory.self) private var history
    @State private var selection: Set<UUID> = []
    /// Lectures waiting for "Delete for good?" to be confirmed.
    @State private var pendingDeletion: [UUID]?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(history.recentlyDeleted) { lecture in
                    row(for: lecture)
                        .tag(lecture.id)
                        .swipeActions {
                            Button(role: .destructive) { pendingDeletion = [lecture.id] } label: {
                                Label("Delete Now", systemImage: "trash").labelStyle(.iconOnly)
                            }
                            Button { restore([lecture.id]) } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
                            }
                        }
                }
            } footer: {
                if !history.recentlyDeleted.isEmpty {
                    Text("Lectures show the days remaining before deletion. After that time, items will be permanently deleted. This make take up to \(LectureHistory.retentionDays) days.")
                }
            }
        }
        // Acts on every selected row, or on the row right-clicked if it isn't selected.
        .contextMenu(forSelectionType: UUID.self) { ids in
            let ordered = ordered(ids)
            if !ordered.isEmpty {
                Button(ordered.count == 1 ? "Restore" : "Restore \(ordered.count) Lectures", systemImage: "arrow.uturn.backward") {
                    restore(ordered)
                }
                Button(role: .destructive) { pendingDeletion = ordered } label: {
                    Label(ordered.count == 1 ? "Delete Now" : "Delete \(ordered.count) Lectures Now", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            let ids = ordered(selection)
            if !ids.isEmpty { pendingDeletion = ids }
        }
        #endif
        .overlay {
            if history.recentlyDeleted.isEmpty {
                ContentUnavailableView(
                    "No Recently Deleted Lectures", systemImage: "trash",
                    description: Text("Deleted lectures stay here for \(LectureHistory.retentionDays) days.")
                )
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem {
                    Button("Restore \(selection.count)", systemImage: "arrow.uturn.backward") { restore(ordered(selection)) }
                        .help("Restore the selected lectures")
                }
                ToolbarItem {
                    Button("Delete \(selection.count)", systemImage: "trash", role: .destructive) {
                        pendingDeletion = ordered(selection)
                    }
                    .help("Delete the selected lectures for good")
                }
            }
            ToolbarItem {
                Button("Delete All", systemImage: "trash.slash", role: .destructive) { isConfirmingDeleteAll = true }
                    .disabled(history.recentlyDeleted.isEmpty)
            }
        }
        .confirmationDialog(deletionTitle, isPresented: pendingDeletionIsShown, presenting: pendingDeletion) { ids in
            Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Lectures", role: .destructive) {
                selection.subtract(ids)
                history.attempt { try history.deletePermanently(ids) }
            }
        } message: { ids in
            if ids.count == 1, let lecture = history.lecture(ids[0]) {
                Text("“\(lecture.title)” and its notes will be deleted. This can't be undone.")
            } else {
                Text("These \(ids.count) lectures and their notes will be deleted. This can't be undone.")
            }
        }
        .confirmationDialog("Delete all lectures in Recently Deleted?", isPresented: $isConfirmingDeleteAll) {
            Button("Delete All", role: .destructive) {
                selection = []
                history.attempt { try history.emptyRecentlyDeleted() }
            }
        } message: {
            Text("This can't be undone.")
        }
        // Drop selections of lectures that were restored, deleted, or expired.
        .onChange(of: history.recentlyDeleted.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .onAppear { history.purgeExpired() }
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.count ?? 0
        return count == 1 ? "Delete this lecture for good?" : "Delete \(count) lectures for good?"
    }

    /// Selected IDs in the order the list shows them.
    private func ordered(_ ids: Set<UUID>) -> [UUID] {
        history.recentlyDeleted.map(\.id).filter(ids.contains)
    }

    private func row(for lecture: SavedLecture) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lecture.title)
                Text(daysLeftText(for: lecture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { restore([lecture.id]) }
                .buttonStyle(.bordered)
        }
    }

    private func daysLeftText(for lecture: SavedLecture) -> String {
        let days = history.daysRemaining(for: lecture)
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    private func restore(_ ids: [UUID]) {
        selection.subtract(ids)
        history.attempt { try history.restore(ids) }
    }

    private var pendingDeletionIsShown: Binding<Bool> {
        Binding { pendingDeletion != nil } set: { if !$0 { pendingDeletion = nil } }
    }
}
