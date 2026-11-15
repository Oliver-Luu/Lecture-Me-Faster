import Foundation
import Observation

/// Saves processed lectures on this device and keeps track of the history and Recently Deleted.
///
/// Each lecture is a folder named by its ID:
///
///     <root>/<id>/lecture.json    the SavedLecture record
///     <root>/<id>/frames/0.jpg    slide images, in the order of `frameSeconds`
///
/// Moving a lecture to Recently Deleted only sets its `deletedAt`. The files stay until the lecture is
/// deleted for good, either by hand or automatically `retentionDays` after it was deleted.
@Observable final class LectureHistory {
    static let retentionDays = 30

    /// Lectures in the history, newest first.
    private(set) var lectures: [SavedLecture] = []
    /// Lectures in Recently Deleted, most recently deleted first.
    private(set) var recentlyDeleted: [SavedLecture] = []
    /// The last file error, shown to the user and then cleared.
    var lastError: String?

    let root: URL
    private let now: () -> Date

    /// - Parameters:
    ///   - root: Folder that holds the lecture folders. Tests pass a temporary folder.
    ///   - now: The clock. Tests pass a fixed one to check the 30-day expiry.
    init(root: URL = LectureHistory.defaultRoot, now: @escaping () -> Date = { Date() }) {
        self.root = root
        self.now = now
        reload()
        purgeExpired()
    }

    /// Inside the app's container on a sandboxed Mac, and the app's own Application Support on iOS.
    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Lectures", directoryHint: .isDirectory)
    }

    // MARK: Reading

    func lecture(_ id: UUID) -> SavedLecture? {
        lectures.first { $0.id == id } ?? recentlyDeleted.first { $0.id == id }
    }

    /// Loads a lecture's slide images from disk. Missing image files are skipped.
    func frames(for lecture: SavedLecture) -> [LectureFrame] {
        let folder = framesFolder(for: lecture.id)
        return lecture.frameSeconds.enumerated().compactMap { index, seconds in
            guard let jpeg = try? Data(contentsOf: folder.appending(path: "\(index).jpg")) else { return nil }
            return LectureFrame(seconds: seconds, jpeg: jpeg)
        }
    }

    /// Days left before a lecture in Recently Deleted is deleted for good, rounded up.
    func daysRemaining(for lecture: SavedLecture) -> Int {
        guard let deletedAt = lecture.deletedAt else { return Self.retentionDays }
        let expiry = deletedAt.addingTimeInterval(Double(Self.retentionDays) * 86_400)
        return max(0, Int((expiry.timeIntervalSince(now()) / 86_400).rounded(.up)))
    }

    /// Re-reads every lecture folder from disk. Folders whose record can't be read are ignored.
    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        let all = folders.compactMap { folder -> SavedLecture? in
            guard let data = try? Data(contentsOf: folder.appending(path: "lecture.json")) else { return nil }
            return try? JSONDecoder().decode(SavedLecture.self, from: data)
        }
        lectures = all.filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
        recentlyDeleted = all.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
    }

    // MARK: Writing

    /// Saves a newly processed lecture and adds it to the top of the history.
    @discardableResult
    func save(
        title: String,
        transcript: [TranscriptSegment],
        frames: [LectureFrame],
        distinctFrameCount: Int,
        parts: [LecturePart] = [],
        documents: [LectureDocument] = []
    ) throws -> SavedLecture {
        let lecture = SavedLecture(
            id: UUID(), title: title, createdAt: now(), transcript: transcript,
            frameSeconds: frames.map(\.seconds), distinctFrameCount: distinctFrameCount,
            summary: "", deletedAt: nil, parts: parts.count > 1 ? parts : nil,
            documents: documents.isEmpty ? nil : documents
        )
        let framesFolder = framesFolder(for: lecture.id)
        do {
            try FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() {
                try frame.jpeg.write(to: framesFolder.appending(path: "\(index).jpg"))
            }
            try write(lecture)
        } catch {
            // Don't leave a half-written folder behind.
            try? FileManager.default.removeItem(at: folder(for: lecture.id))
            throw error
        }
        lectures.insert(lecture, at: 0)
        return lecture
    }

    /// Stores one version of a lecture's notes, replacing any earlier version at the same detail level.
    /// Does nothing if the lecture was deleted for good meanwhile.
    func saveNotes(_ version: NoteVersion, for id: UUID) throws {
        guard var lecture = lecture(id) else { return }
        let others = lecture.noteVersions.filter { $0.detail != version.detail }
        lecture.notes = NoteVersion.ordered(others + [version])
        lecture.summary = ""  // any older notes now live in `notes`
        try write(lecture)
        replace(lecture)
    }

    /// Renames a lecture. Surrounding spaces are trimmed; an empty name is ignored.
    func rename(_ id: UUID, to newTitle: String) throws {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var lecture = lecture(id), lecture.title != title else { return }
        lecture.title = title
        try write(lecture)
        replace(lecture)
    }

    func moveToRecentlyDeleted(_ id: UUID) throws {
        guard var lecture = lectures.first(where: { $0.id == id }) else { return }
        lecture.deletedAt = now()
        try write(lecture)
        lectures.removeAll { $0.id == id }
        recentlyDeleted.insert(lecture, at: 0)
    }

    func restore(_ id: UUID) throws {
        guard var lecture = recentlyDeleted.first(where: { $0.id == id }) else { return }
        lecture.deletedAt = nil
        try write(lecture)
        recentlyDeleted.removeAll { $0.id == id }
        lectures.append(lecture)
        lectures.sort { $0.createdAt > $1.createdAt }
    }

    /// Deletes a lecture's files. Only lectures already in Recently Deleted can be deleted for good.
    func deletePermanently(_ id: UUID) throws {
        guard recentlyDeleted.contains(where: { $0.id == id }) else { return }
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: folder)
        }
        recentlyDeleted.removeAll { $0.id == id }
    }

    func emptyRecentlyDeleted() throws {
        for lecture in recentlyDeleted {
            try deletePermanently(lecture.id)
        }
    }

    // MARK: Several at once

    /// Moves several lectures to Recently Deleted. A failure doesn't stop the rest; the first one is
    /// thrown at the end.
    func moveToRecentlyDeleted(_ ids: [UUID]) throws {
        try forEach(ids, moveToRecentlyDeleted)
    }

    func restore(_ ids: [UUID]) throws {
        try forEach(ids, restore)
    }

    /// Deletes several lectures for good. Only lectures in Recently Deleted are deleted.
    func deletePermanently(_ ids: [UUID]) throws {
        try forEach(ids, deletePermanently)
    }

    private func forEach(_ ids: [UUID], _ action: (UUID) throws -> Void) throws {
        var firstError: (any Error)?
        for id in ids {
            do { try action(id) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Deletes for good every lecture that has been in Recently Deleted for `retentionDays`.
    func purgeExpired() {
        for lecture in recentlyDeleted where daysRemaining(for: lecture) == 0 {
            attempt { try deletePermanently(lecture.id) }
        }
    }

    /// Runs a file operation from the UI, turning a failure into `lastError` for an alert.
    func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Files

    private func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func framesFolder(for id: UUID) -> URL {
        folder(for: id).appending(path: "frames", directoryHint: .isDirectory)
    }

    private func write(_ lecture: SavedLecture) throws {
        let folder = folder(for: lecture.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(lecture).write(to: folder.appending(path: "lecture.json"), options: .atomic)
    }

    private func replace(_ lecture: SavedLecture) {
        if let index = lectures.firstIndex(where: { $0.id == lecture.id }) {
            lectures[index] = lecture
        } else if let index = recentlyDeleted.firstIndex(where: { $0.id == lecture.id }) {
            recentlyDeleted[index] = lecture
        }
    }
}
