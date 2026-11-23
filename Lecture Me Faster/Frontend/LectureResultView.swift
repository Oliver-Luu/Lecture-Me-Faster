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
    /// True for a moment after Copy Notes, so the button can show it worked.
    @State private var didCopy = false
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
            // The model on the left and the tabs on the right; stacked when the window is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.medium) {
                    modelButton
                    Spacer(minLength: Metrics.small)
                    tabPicker
                }
                VStack(alignment: .leading, spacing: Metrics.small) {
                    modelButton
                    tabPicker
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metrics.large)
            .padding(.vertical, Metrics.medium)

            switch tab {
            case .notes: notes
            case .transcript: transcript
            case .slides: slides
            case .materials: MaterialsList(documents: session.documents)
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

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(tabs, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The model the shown level is written with, always at the top left of the lecture. Clicking it
    /// opens the model switcher. (It used to be a toolbar item, which macOS hid in the overflow menu
    /// whenever the lecture's name or the model's name was long.)
    private var modelButton: some View {
        Button { isChoosingModel = true } label: {
            HStack(spacing: Metrics.tight) {
                Text(settings.chosenModelName(for: shownLevel.detail))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Metrics.tight)
            .padding(.horizontal, Metrics.small)
            .contentShape(.rect)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        // Keeps the name's left edge where it was before the padding the highlight needs.
        .padding(.leading, -Metrics.small)
        .help("Change the model notes are written with")
        .accessibilityLabel("Model: \(settings.chosenModelName(for: shownLevel.detail))")
        .accessibilityHint("Changes the model notes are written with")
        .popover(isPresented: $isChoosingModel, arrowEdge: .bottom) {
            ModelSwitcher(
                detail: shownLevel.detail,
                actionTitle: canWrite(shownLevel) ? (session.hasVersion(shownLevel.detail) ? "Rewrite \(shownLevel.label) Notes" : "Write \(shownLevel.label) Notes") : nil,
                action: { write(shownLevel) }
            )
        }
    }

    /// Under finished notes: copy, share, write again, and who wrote them.
    private func actionRow(text: String, version: NoteVersion?) -> some View {
        HStack(spacing: Metrics.tight) {
            Button(didCopy ? "Copied" : "Copy Notes", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                Self.copyNotes(text)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            }
            .help("Copy all of these notes, with headings and bullets, to paste into a document")
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .padding(Metrics.tight)
            .hoverHighlight()
            ShareLink(item: text)
                .help("Share these notes")
                .padding(Metrics.tight)
                .hoverHighlight()
            Button("Rewrite These Notes", systemImage: "arrow.clockwise") { write(shownLevel) }
                .help("Write the \(shownLevel.label) notes again, keeping the other levels")
                .disabled(!canWrite(shownLevel))
                .padding(Metrics.tight)
                .hoverHighlight()
            if let version {
                Text(caption(for: version))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, Metrics.small)
            }
        }
        .padding(.leading, -Metrics.tight)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        // Quiet, like the row under a chat reply: the notes are what the eye should land on.
        .foregroundStyle(.secondary)
        .imageScale(.large)
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
            ScrollView(.horizontal) { levelBar }
                .scrollIndicators(.hidden)
                .readingColumn()
                .padding(.bottom, Metrics.small)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.regular) {
                    if let proposal = splitProposalForShownLevel {
                        SplitProposalCard(proposal: proposal)
                    }
                    if let error = errorForShownLevel {
                        Notice(.failure, error)
                    }
                    let text = session.notes(for: shownLevel.detail)
                    let shownVersion = session.versions.first { $0.detail == shownLevel.detail }
                    if session.transcript.isEmpty, !session.frames.isEmpty, isWritingShownLevel || !text.isEmpty {
                        Notice(.warning, Self.noSpeechWarning)
                    }
                    if isWritingShownLevel ? session.isSendingSlidesAsText : (!text.isEmpty && shownVersion?.slidesAsText == true) {
                        Notice(.warning, Self.slidesAsTextWarning)
                    }
                    if !text.isEmpty {
                        MarkdownView(text: text)
                        if !isWritingShownLevel {
                            actionRow(text: text, version: shownVersion)
                        }
                    }
                    if isWritingShownLevel {
                        HStack(spacing: Metrics.small) {
                            ProgressView().controlSize(.small)
                            Text(progressText(hasText: !text.isEmpty))
                                .foregroundStyle(.secondary)
                        }
                    } else if text.isEmpty, splitProposalForShownLevel == nil {
                        missingVersion
                    }
                }
                .readingColumn()
                .padding(.vertical, Metrics.regular)
            }
        }
    }

    /// The levels of detail side by side. A filled dot marks a level that has been written, a ring one
    /// that hasn't, and a spinner the one being written now.
    private var levelBar: some View {
        HStack(spacing: Metrics.tight) {
            ForEach(levels, id: \.self) { item in
                let isSelected = item == shownLevel
                let state = levelState(item)
                Button { level = item } label: {
                    HStack(spacing: Metrics.small) {
                        LevelMarker(state: state)
                        Text(item.label)
                            .fontWeight(isSelected ? .semibold : .regular)
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, Metrics.medium)
                    .padding(.vertical, Metrics.small)
                    .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear), in: .capsule)
                    .contentShape(.capsule)
                    .hoverHighlight(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.label) notes")
                .accessibilityValue(state.spokenName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func levelState(_ item: NotesLevel) -> LevelMarker.State {
        if session.phase == .summarizing, item != .earlier, session.writingDetail == item.detail { return .writing }
        return session.hasVersion(item.detail) ? .written : .unwritten
    }

    /// Shown for a level that hasn't been written yet.
    @ViewBuilder private var missingVersion: some View {
        if let detail = shownLevel.detail, session.phase != .processing {
            EmptyState(title: "No \(detail.label) notes yet", message: detail.summary) {
                Button("Write \(detail.label) Notes") { write(shownLevel) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canWrite(shownLevel))
                if session.phase == .summarizing, let writing = session.writingDetail {
                    Text("Available once the \(writing.label) notes are finished.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !session.hasSource {
                    Text("This lecture has no transcript, slides or material text to write notes from.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, Metrics.large)
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
        lecture has a spoken voice, check the Transcript tab and that the speech is in your device's language.
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
            HStack(alignment: .firstTextBaseline, spacing: Metrics.medium) {
                Text(timestamp(segment.seconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text(segment.text)
            }
            .padding(.vertical, Metrics.tight / 2)
        }
        .canvasBackground()
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
                EmptyState("No transcript", session.frames.isEmpty && session.documents.isEmpty
                    ? "This lecture has no recording."
                    : "No speech was recognized. Check that the recording has spoken audio in your device's language.")
            }
        }
    }

    private var slides: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.regular) {
                if let note = Self.slidesNote(kept: session.frames.count, distinct: session.distinctFrameCount, imageLimit: settings.stored.maxFrames) {
                    Notice(.info, note)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Metrics.regular)], spacing: Metrics.regular) {
                    ForEach(session.frames) { frame in
                        VStack(alignment: .leading, spacing: Metrics.tight) {
                            FrameImage(frame: frame)
                            Text(timestamp(frame.seconds))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.large)
            .padding(.vertical, Metrics.regular)
        }
        .overlay {
            if session.frames.isEmpty {
                EmptyState("No slides", "Slides come from video. This lecture has none.")
            }
        }
    }
}

/// The dot beside a level of detail's name.
private struct LevelMarker: View {
    enum State {
        case unwritten, writing, written

        var spokenName: String {
            switch self {
            case .unwritten: "Not written yet"
            case .writing: "Being written"
            case .written: "Written"
            }
        }
    }

    let state: State

    var body: some View {
        Group {
            switch state {
            case .unwritten: Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            case .writing: ProgressView().controlSize(.mini)
            case .written: Circle().fill(.tint)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Centres content in a column no wider than a comfortable line of text.
    func readingColumn() -> some View {
        frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .padding(.horizontal, Metrics.large)
            .frame(maxWidth: .infinity)
    }
}

/// One slide in the Slides tab, shown as a small copy made off the main thread and kept for next time.
/// (Decoding the full-size JPEG in `body` ran again for every slide on every redraw and scroll.)
private struct FrameImage: View {
    let frame: LectureFrame
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
        // A hairline, so a white slide has an edge on a white window.
        .overlay { RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(.quaternary) }
        .task(id: frame.id) { image = await FrameThumbnails.thumbnail(for: frame) }
    }
}

/// Small copies of slide images for the Slides tab.
nonisolated enum FrameThumbnails {
    /// The longest side in pixels: twice the 260-point grid cell, for Retina screens.
    static let maxPixels = 640

    /// Emptied by the system when memory is short.
    private nonisolated(unsafe) static let cache = NSCache<NSUUID, CGImage>()

    @concurrent
    static func thumbnail(for frame: LectureFrame) async -> CGImage? {
        if let cached = cache.object(forKey: frame.id as NSUUID) { return cached }
        guard let image = thumbnail(from: frame.jpeg) else { return nil }
        cache.setObject(image, forKey: frame.id as NSUUID)
        return image
    }

    static func thumbnail(from jpeg: Data, maxPixels: Int = maxPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
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

        VStack(alignment: .leading, spacing: Metrics.medium) {
            if proposal.fitsInOneRequest {
                Text("This lecture fits in one request")
                    .font(.headline)
                Text("It is about \(proposal.estimatedTokens.formatted()) tokens, and \(proposal.model) reads about \(proposal.contextTokens.formatted()) at a time.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This lecture is too long for one request")
                    .font(.headline)
                Text("It is about \(proposal.estimatedTokens.formatted()) tokens, and \(proposal.model) reads about \(proposal.contextTokens.formatted()) at a time, including room for the notes.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("The \(proposal.detail.label) notes can be written in \(proposal.parts) parts and then combined, which is \(proposal.requests) requests. That takes longer and, on a paid service, costs more. A model with a larger context window needs fewer parts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Don't ask again", isOn: $settings.stored.splitWithoutAsking)
            }
            HStack(spacing: Metrics.small) {
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
        .padding(Metrics.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel, in: .rect(cornerRadius: Metrics.cornerRadius))
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
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    Label(document.name, systemImage: document.kind.symbol)
                    Text(details(for: document))
                        .font(.caption)
                        .foregroundStyle(document.readError == nil && !document.text.isEmpty ? Color.secondary : Color.orange)
                }
            }
        }
        .canvasBackground()
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
