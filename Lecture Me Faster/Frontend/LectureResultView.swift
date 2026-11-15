import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LectureResultView: View {
    private enum Tab: String, CaseIterable {
        case notes = "Notes", transcript = "Transcript", slides = "Slides", materials = "Materials"
    }

    /// The Materials tab only appears when the lecture has supporting files.
    private var tabs: [Tab] {
        session.documents.isEmpty ? [.notes, .transcript, .slides] : Tab.allCases
    }

    /// A level of notes in the selector. `earlier` is notes saved before levels existed.
    private enum NotesLevel: Hashable {
        case level(NoteDetail)
        case earlier

        var detail: NoteDetail? {
            if case .level(let detail) = self { detail } else { nil }
        }

        var label: String {
            switch self {
            case .level(let detail): detail.label
            case .earlier: "Earlier notes"
            }
        }
    }

    @Environment(LectureSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var tab = Tab.notes
    @State private var level: NotesLevel?
    @State private var selectedSegments: Set<TranscriptSegment.ID> = []
    @State private var isChoosingModel = false
    @State private var replanTask: Task<Void, Never>?

    /// Every level, plus "Earlier notes" when an older lecture has them.
    private var levels: [NotesLevel] {
        (session.hasVersion(nil) ? [.earlier] : []) + NoteDetail.allCases.map(NotesLevel.level)
    }

    /// What the selector shows until you pick something: the level being written, else your usual level
    /// if it exists, else the most recently written notes.
    private var shownLevel: NotesLevel {
        if let level { return level }
        if let writing = session.writingDetail { return .level(writing) }
        let preferred = settings.stored.noteDetail
        if session.hasVersion(preferred) || session.versions.isEmpty { return .level(preferred) }
        let latest = session.versions.max { $0.writtenAt < $1.writtenAt }
        return latest?.detail.map(NotesLevel.level) ?? .earlier
    }

    private var isWritingShownLevel: Bool {
        session.phase == .summarizing && session.writingDetail == shownLevel.detail && shownLevel != .earlier
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: tabs.count > 3 ? 460 : 360)
            .padding()

            switch tab {
            case .notes: notes
            case .transcript: transcript
            case .slides: slides
            case .materials: MaterialsList(documents: session.documents)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { isChoosingModel = true } label: {
                    Label(settings.chosenModelName(for: shownLevel.detail), systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .help("Change the model notes are written with")
                .popover(isPresented: $isChoosingModel) {
                    ModelSwitcher(
                        detail: shownLevel.detail,
                        actionTitle: canWrite(shownLevel) ? (session.hasVersion(shownLevel.detail) ? "Rewrite \(shownLevel.label) Notes" : "Write \(shownLevel.label) Notes") : nil,
                        action: { write(shownLevel) }
                    )
                }
            }
            ToolbarItem {
                Button("Copy Notes", systemImage: "doc.on.doc") {
                    Self.copyNotes(session.notes(for: shownLevel.detail))
                }
                .help("Copy all of these notes, with headings and bullets, to paste into a document")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(session.notes(for: shownLevel.detail).isEmpty || isWritingShownLevel)
            }
            ToolbarItem {
                ShareLink(item: session.notes(for: shownLevel.detail))
                    .disabled(session.notes(for: shownLevel.detail).isEmpty || isWritingShownLevel)
            }
            ToolbarItem {
                Button("Rewrite These Notes", systemImage: "arrow.clockwise") { write(shownLevel) }
                    .help("Write the \(shownLevel.label) notes again, keeping the other levels")
                    .disabled(!canWrite(shownLevel))
            }
        }
        // When notes start being written (a new lecture, or Write/Rewrite), show that level.
        .onChange(of: session.writingDetail) { _, writing in
            if let writing { level = .level(writing) }
        }
        // A split proposal on screen follows the model and settings: change either (here or in Settings)
        // and it is worked out again. The short wait skips the in-between states while typing.
        .onChange(of: settings.planningKey) {
            guard case .awaitingSplitApproval = session.phase else { return }
            replanTask?.cancel()
            replanTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                session.replan(settings: settings)
            }
        }
    }

    private func canWrite(_ level: NotesLevel) -> Bool {
        level.detail != nil && session.hasSource && session.phase != .summarizing && session.phase != .processing
    }

    private func write(_ level: NotesLevel) {
        guard let detail = level.detail else { return }
        session.resummarize(settings: settings, detail: detail)
    }

    private var notes: some View {
        VStack(spacing: 0) {
            Picker("Detail", selection: Binding { shownLevel } set: { level = $0 }) {
                ForEach(levels, id: \.self) { level in
                    // ✓ marks levels that have been written.
                    Text(session.hasVersion(level.detail) ? "\(level.label) ✓" : level.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let proposal = splitProposalForShownLevel {
                        SplitProposalCard(proposal: proposal)
                    }
                    if let error = errorForShownLevel {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    let text = session.notes(for: shownLevel.detail)
                    let shownVersion = session.versions.first { $0.detail == shownLevel.detail }
                    if session.transcript.isEmpty, !session.frames.isEmpty, isWritingShownLevel || !text.isEmpty {
                        Label(Self.noSpeechWarning, systemImage: "waveform.slash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if isWritingShownLevel ? session.isSendingSlidesAsText : (!text.isEmpty && shownVersion?.slidesAsText == true) {
                        Label(Self.slidesAsTextWarning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if !text.isEmpty {
                        if let version = shownVersion, !isWritingShownLevel {
                            Text(caption(for: version))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        MarkdownView(text: text)
                    }
                    if isWritingShownLevel {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progressText(hasText: !text.isEmpty))
                                .foregroundStyle(.secondary)
                        }
                    } else if text.isEmpty, splitProposalForShownLevel == nil {
                        missingVersion
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Shown for a level that hasn't been written yet.
    @ViewBuilder private var missingVersion: some View {
        if let detail = shownLevel.detail, session.phase != .processing {
            VStack(spacing: 12) {
                Text("No \(detail.label) notes yet")
                    .font(.headline)
                Text(detail.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Write \(detail.label) Notes") { write(shownLevel) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canWrite(shownLevel))
                if session.phase == .summarizing, let writing = session.writingDetail {
                    Text("Wait for the \(writing.label) notes to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !session.hasSource {
                    Text("This lecture has no transcript or material text to write notes from.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    /// A failure belongs to the level that was being written; a failure before any notes (reading the
    /// files) shows on every level.
    private var errorForShownLevel: String? {
        guard case .failed(let message) = session.phase else { return nil }
        if let failed = session.failedDetail, failed != shownLevel.detail { return nil }
        return message
    }

    private var splitProposalForShownLevel: LectureSession.SplitProposal? {
        guard case .awaitingSplitApproval(let proposal) = session.phase, proposal.detail == shownLevel.detail else {
            return nil
        }
        return proposal
    }

    /// What the Slides tab says about how the slides reach the model, or nil when there's nothing to say.
    static func slidesNote(kept: Int, distinct: Int, imageLimit: Int) -> String? {
        if distinct > kept {
            return "This video has \(distinct) distinct slides, more than the \(kept) the app stores, so \(kept) evenly spaced ones are kept."
        }
        if kept > imageLimit {
            return "\(kept) slides. In each request to the model, the \(imageLimit) with the most diagrams and pictures are sent as images; the rest are sent as the text on them, so none is left out. Change the number in Settings > Advanced > Slides."
        }
        return nil
    }

    static let noSpeechWarning = """
        No speech was recognized in this recording, so these notes come from the slides only. If the \
        lecture has a spoken voice, check the Transcript tab and that the speech is in your Mac's language.
        """

    static let slidesAsTextWarning = """
        This model can't see images, so the slides were sent as the text read from them (plus a short \
        description when Apple Intelligence is on). Diagrams, graphs, and handwriting may be missed or \
        described wrongly. For the most accurate notes, use a model that can see images.
        """

    private func progressText(hasText: Bool) -> String {
        if let progress = session.slideDescriptionProgress {
            return "Describing slide \(progress.step) of \(progress.total) for a model that can't see images…"
        }
        if let progress = session.partProgress {
            return progress.isCombining
                ? "Combining the parts…"
                : "Writing part \(progress.step) of \(progress.total - 1)…"
        }
        return hasText ? "Writing…" : "The model is reading the lecture…"
    }

    private func caption(for version: NoteVersion) -> String {
        var parts: [String] = []
        if !version.model.isEmpty { parts.append("Written by \(version.model)") }
        if let count = version.parts { parts.append("in \(count) parts") }
        parts.append(version.writtenAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// Select lines with click, Shift-click, or Command-click; copy them with ⌘C or the right-click menu.
    /// (Rows don't allow selecting text inside them, which would swallow the clicks that select rows.)
    private var transcript: some View {
        List(session.transcript, selection: $selectedSegments) { segment in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timestamp(segment.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(segment.text)
            }
        }
        .contextMenu(forSelectionType: TranscriptSegment.ID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Copy" : "Copy \(ids.count) Lines", systemImage: "doc.on.doc") {
                    Self.copyToPasteboard(Self.copyText(for: ids, in: session.transcript))
                }
            }
        }
        #if os(macOS)
        .onCopyCommand {
            guard !selectedSegments.isEmpty else { return [] }
            return [NSItemProvider(object: Self.copyText(for: selectedSegments, in: session.transcript) as NSString)]
        }
        #endif
        .overlay {
            if session.transcript.isEmpty {
                ContentUnavailableView(
                    "No transcript", systemImage: "text.quote",
                    description: Text(session.frames.isEmpty && session.documents.isEmpty
                        ? "This lecture has no recording."
                        : "No speech was recognized in this recording. Check that the file has spoken audio in your Mac's language.")
                )
            }
        }
    }

    private var slides: some View {
        ScrollView {
            if let note = Self.slidesNote(kept: session.frames.count, distinct: session.distinctFrameCount, imageLimit: settings.stored.maxFrames) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(session.frames) { frame in
                    VStack(alignment: .leading, spacing: 4) {
                        FrameImage(jpeg: frame.jpeg)
                        Text(timestamp(frame.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .overlay {
            if session.frames.isEmpty {
                ContentUnavailableView("No slides", systemImage: "photo.on.rectangle", description: Text("Audio-only lectures have no frames."))
            }
        }
    }
}

private struct FrameImage: View {
    let jpeg: Data

    var body: some View {
        if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 6))
        }
    }
}

/// Asks before writing a lecture too long for one request in several parts. It is worked out again when
/// the model or settings change, and then may say the lecture now fits in one request.
private struct SplitProposalCard: View {
    let proposal: LectureSession.SplitProposal

    @Environment(LectureSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var isChoosingModel = false

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 10) {
            if proposal.fitsInOneRequest {
                Label("This lecture fits in one request", systemImage: "checkmark.circle")
                    .font(.headline)
                Text("It comes to about \(proposal.estimatedTokens.formatted()) tokens, and \(proposal.model) takes about \(proposal.contextTokens.formatted()) at a time, so the \(proposal.detail.label) notes can be written in one request.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("This lecture is too long to send in one request", systemImage: "rectangle.split.3x1")
                    .font(.headline)
                Text("It comes to about \(proposal.estimatedTokens.formatted()) tokens, and \(proposal.model) takes about \(proposal.contextTokens.formatted()) at a time, including room for the notes. The \(proposal.detail.label) notes can be written in \(proposal.parts) parts and then combined: \(proposal.requests) requests instead of one. That takes longer, and with a paid service it costs more, mainly for the combining step and for any materials, which are sent with every part. A model with a larger context window needs fewer parts.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Don't ask again", isOn: $settings.stored.splitWithoutAsking)
            }
            HStack {
                Button(proposal.fitsInOneRequest ? "Write \(proposal.detail.label) Notes" : "Write in \(proposal.parts) Parts") {
                    session.approveSplit(settings: settings)
                }
                .buttonStyle(.borderedProminent)
                Button("Change Model…") { isChoosingModel = true }
                    .popover(isPresented: $isChoosingModel) { ModelSwitcher(detail: proposal.detail, actionTitle: nil, action: nil) }
                Button("Cancel") { session.declineSplit() }
                if session.isReplanning {
                    ProgressView().controlSize(.small)
                    Text("Checking with \(settings.chosenModelName(for: proposal.detail))…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(session.isReplanning)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

extension LectureResultView {
    /// The selected transcript lines in lecture order, one per line with its timestamp.
    static func copyText(for ids: Set<TranscriptSegment.ID>, in transcript: [TranscriptSegment]) -> String {
        transcript
            .filter { ids.contains($0.id) }
            .map { "[\(timestamp($0.seconds))] \($0.text)" }
            .joined(separator: "\n")
    }

    static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Copies notes with their formatting (HTML, for Google Docs, Word, Pages, Notes) and as Markdown
    /// text for apps that only take plain text.
    static func copyNotes(_ markdown: String) {
        let html = MarkdownView.html(from: markdown)
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(markdown, forType: .string)
        #else
        UIPasteboard.general.items = [["public.html": html, "public.utf8-plain-text": markdown]]
        #endif
    }
}

/// Each supporting file, what was read from it, and any problem reading it.
private struct MaterialsList: View {
    let documents: [LectureDocument]

    /// Showing more than this in one Text view makes scrolling sluggish; the model still gets it all.
    private static let previewCharacters = 20_000

    var body: some View {
        List(documents) { document in
            DisclosureGroup {
                if document.text.isEmpty {
                    Text("No text was found in this file.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(document.text.prefix(Self.previewCharacters))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if document.text.count > Self.previewCharacters {
                        Text("Preview shortened here. The model receives all \(document.text.count.formatted()) characters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(document.name, systemImage: document.kind.symbol)
                    Text(details(for: document))
                        .font(.caption)
                        .foregroundStyle(document.readError == nil && !document.text.isEmpty ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private func details(for document: LectureDocument) -> String {
        if let error = document.readError { return "Couldn't be read: \(error)" }
        if document.text.isEmpty { return "\(document.kind.label) · no text found" }
        var parts = [document.kind.label, "\(document.text.count.formatted()) characters"]
        if document.recognizedPages > 0 {
            parts.append(document.kind == .image
                ? "read with text recognition"
                : "\(document.recognizedPages) scanned \(document.recognizedPages == 1 ? "page" : "pages") read with text recognition")
        }
        if document.wasTrimmed { parts.append("trimmed to fit") }
        return parts.joined(separator: " · ")
    }
}
