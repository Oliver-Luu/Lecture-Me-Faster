import Foundation

/// One lecture in the history: everything needed to show it again without reprocessing the file.
///
/// Slide images are not stored in this record. They live next to it as numbered JPEG files, in the same
/// order as `frameSeconds` (see `LectureHistory`).
nonisolated struct SavedLecture: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var transcript: [TranscriptSegment]
    /// The timestamp of each saved slide image.
    var frameSeconds: [Double]
    /// How many distinct frames were found before thinning to the slide limit.
    var distinctFrameCount: Int
    /// Notes from before a lecture could have several versions. Empty in newer records, and cleared once
    /// a record is updated (the text then lives in `notes` with no detail level). Read `noteVersions`.
    var summary: String
    /// Set when the lecture is moved to Recently Deleted; `nil` while it is in the history.
    var deletedAt: Date?
    /// The files the lecture was made from, when there was more than one. `nil` in records saved before
    /// multi-file lectures existed (an optional is simply absent from older JSON, so they still load).
    var parts: [LecturePart]?
    /// Supporting files (PDFs, Word, PowerPoint, images) and the text read from them. `nil` in records
    /// saved before materials existed.
    var documents: [LectureDocument]?
    /// One set of notes per detail level. `nil` in records saved before versions existed.
    var notes: [NoteVersion]?
    /// The folder the lecture is filed in. `nil` when it is in no folder, and in records saved before
    /// folders existed.
    var folderID: UUID? = nil

    /// Every version of the notes, including notes from an older record, which become one version with
    /// no detail level ("Earlier notes").
    var noteVersions: [NoteVersion] {
        if let notes { return notes }
        return summary.isEmpty ? [] : [NoteVersion(detail: nil, text: summary, model: "", writtenAt: createdAt)]
    }

    var hasNotes: Bool { !noteVersions.isEmpty }
}

/// One set of notes for a lecture, written at one detail level.
nonisolated struct NoteVersion: Codable, Sendable, Equatable {
    /// `nil` for notes written before versions existed, at a level that wasn't recorded.
    var detail: NoteDetail?
    var text: String
    /// The model that wrote them, e.g. "claude-opus-5-5" or "gemma3:12b". Empty if unknown.
    var model: String
    var writtenAt: Date
    /// How many parts a lecture too long for one request was written in. `nil` for one request.
    var parts: Int? = nil
    /// True when the model couldn't see images, so the slides were sent as text read from them (and a
    /// short description when Apple Intelligence could write one). `nil` for older notes.
    var slidesAsText: Bool? = nil

    /// Versions in slider order (Key points first), with earlier unlabelled notes before them.
    static func ordered(_ versions: [NoteVersion]) -> [NoteVersion] {
        versions.sorted { ($0.detail?.rawValue ?? -1) < ($1.detail?.rawValue ?? -1) }
    }
}

/// A folder in the sidebar, for keeping a course's lectures together. A lecture names its folder in
/// `SavedLecture.folderID`; the folder itself is only a name.
nonisolated struct LectureFolder: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
}
