import SwiftUI
import UniformTypeIdentifiers

/// The files waiting in the New Lecture sheet. Files that arrive while the sheet is open (a second
/// drop, Add Files…, or a drop delivered in several pieces) are added here, never replacing the earlier ones.
@Observable
final class NewLectureFiles: Identifiable {
    private(set) var recordings: [URL] = []
    private(set) var materials: [URL] = []
    /// Set once the user reorders the parts; after that, new parts go at the end instead of by name.
    private(set) var isManuallyOrdered = false
    var title = ""
    /// Whether the title is still the suggested one, so it can follow the files as they are added.
    private var titleIsSuggested: Bool { title == suggestedTitle }

    init(_ urls: [URL] = []) {
        add(urls)
    }

    var suggestedTitle: String {
        LectureSession.suggestedTitle(for: recordings.isEmpty ? materials : recordings)
    }

    /// Adds files, skipping any already listed. Recordings stay sorted by name until the user reorders them.
    func add(_ urls: [URL]) {
        let followTitle = titleIsSuggested
        let known = Set((recordings + materials).map(\.standardizedFileURL))
        var seen = known
        let new = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        let newRecordings = new.filter(LectureSession.isLectureFile)
        recordings = isManuallyOrdered
            ? recordings + LectureSession.sortedByName(newRecordings)
            : LectureSession.sortedByName(recordings + newRecordings)
        materials = LectureSession.sortedByName(materials + new.filter { !LectureSession.isLectureFile($0) })
        if followTitle { title = suggestedTitle }
    }

    func moveRecordings(fromOffsets source: IndexSet, toOffset destination: Int) {
        recordings.move(fromOffsets: source, toOffset: destination)
        isManuallyOrdered = true
    }

    func swapRecordings(_ a: Int, _ b: Int) {
        guard recordings.indices.contains(a), recordings.indices.contains(b) else { return }
        recordings.swapAt(a, b)
        isManuallyOrdered = true
    }

    func remove(_ url: URL) {
        let followTitle = titleIsSuggested
        recordings.removeAll { $0 == url }
        materials.removeAll { $0 == url }
        if followTitle { title = suggestedTitle }
    }
}

/// Shown whenever files are added: name the lecture, put the recording's parts in order, check the
/// materials, and choose the model and how detailed the notes should be.
struct NewLectureSheet: View {
    @Bindable var files: NewLectureFiles
    /// Called with the recording files in playing order, the materials, and the lecture's name.
    var onStart: (_ recordings: [URL], _ materials: [URL], _ title: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var modelList = ModelListState()
    @State private var isAddingFiles = false

    private var recordings: [URL] { files.recordings }
    private var materials: [URL] { files.materials }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Lecture name", text: $files.title)
                } footer: {
                    Text(summaryText)
                }

                Section {
                    Button("Add Files…", systemImage: "plus") { isAddingFiles = true }
                } footer: {
                    Text("Add more recording parts or materials here, or drop them onto this window.")
                }

                if !recordings.isEmpty {
                    Section {
                        ForEach(recordings, id: \.self) { url in
                            recordingRow(for: url)
                        }
                        .onMove { files.moveRecordings(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text(recordings.count > 1 ? "Recording parts, in playing order" : "Recording")
                    } footer: {
                        if recordings.count > 1 {
                            Text("Sorted by file name. Each part continues where the one before it ends.")
                        }
                    }
                }

                if !materials.isEmpty {
                    Section {
                        ForEach(materials, id: \.self) { url in
                            materialRow(for: url)
                        }
                    } header: {
                        Text("Materials")
                    } footer: {
                        Text("Text is read from these on this device and given to the model as extra context. Scanned pages and images are read with text recognition, which takes longer.")
                    }
                }

                Section {
                    AIModelFields(state: modelList, mode: .sheet)
                    NoteDetailPicker()
                } header: {
                    Text("Notes")
                } footer: {
                    if let problem = modelProblem {
                        Label("\(problem) Until then the slides and transcript are still saved, and you can write the notes later from the Notes tab.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Your choice is remembered for next time. Change it any time in Settings.")
                    }
                }
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                let usable = urls.filter { LectureSession.isLectureFile($0) || DocumentToText.kind(of: $0) != nil }
                files.add(usable)
                return !usable.isEmpty
            }
            .fileImporter(
                isPresented: $isAddingFiles, allowedContentTypes: [.movie, .audio] + DocumentToText.contentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { files.add(urls) }
            }
            .navigationTitle("New Lecture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make Notes") {
                        onStart(recordings, materials, cleanTitle)
                        dismiss()
                    }
                    .disabled(recordings.isEmpty && materials.isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 560)
    }

    /// Why notes can't be written with the current choice (a missing model or key), if they can't.
    private var modelProblem: String? {
        do {
            _ = try settings.configuration(for: settings.stored.noteDetail)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var summaryText: String {
        switch (recordings.count, materials.count) {
        case (0, _): "Notes will be written from the materials alone."
        case (1, 0): "One recording."
        case (let r, 0): "These \(r) recordings become one lecture with one set of notes."
        case (1, let m): "One recording, with \(m) \(m == 1 ? "file" : "files") of materials for context."
        case (let r, let m): "\(r) recordings joined into one lecture, with \(m) \(m == 1 ? "file" : "files") of materials for context."
        }
    }

    private func recordingRow(for url: URL) -> some View {
        let index = recordings.firstIndex(of: url) ?? 0
        return HStack {
            Text("\(index + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(LectureSession.displayName(url))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Move Up", systemImage: "chevron.up") { files.swapRecordings(index, index - 1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "chevron.down") { files.swapRecordings(index, index + 1) }
                .disabled(index == recordings.count - 1)
            Button("Remove", systemImage: "xmark.circle.fill") { files.remove(url) }
                .disabled(recordings.count + materials.count <= 1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func materialRow(for url: URL) -> some View {
        let kind = DocumentToText.kind(of: url)
        return HStack {
            Label(url.lastPathComponent, systemImage: kind?.symbol ?? "doc")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(kind?.label ?? "")
                .foregroundStyle(.secondary)
            Button("Remove", systemImage: "xmark.circle.fill") { files.remove(url) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(recordings.count + materials.count <= 1)
        }
    }

    private var cleanTitle: String {
        let trimmed = files.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? files.suggestedTitle : trimmed
    }
}
