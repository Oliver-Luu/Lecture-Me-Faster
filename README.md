# Lecture Me Faster

Turn a recorded lecture into thorough study notes. Give the app a lecture video or audio file; it pulls
out the slides and transcribes the speech on your device, then asks an AI model to write notes covering
everything that was taught.

The app is built to cost as little as possible to run. Slide extraction and transcription never leave
your device, and the notes can be written by a free local model through Ollama. Paid APIs are optional.

For how to use the app, see [HELP.md](HELP.md).

## How it works

```
lecture file ──┬─► VideoToFrames ───────► slides (JPEG + timestamp) ───┐
               │                                                       ├─► FileToAI ─► study notes
               └─► AudioToTranscription ► transcript (text + timestamp)┘
```

The first two steps run in parallel. Audio-only lectures simply produce no slides.

### Lectures recorded as several files

Choosing or dropping several files makes **one** lecture from them (a class recorded in parts). A sheet
(`Frontend/NewLectureSheet.swift`) asks for the lecture's name, suggested from what the file names
share ("Lecture 5 - Part 1/2" gives "Lecture 5"), and the order of the parts, sorted by file name the way
Finder sorts, or by date when every name contains one (`LectureSession.nameDate`: month names, abbreviated
or slightly misspelled, or `YYYY-MM-DD`). The prompt says the files may be one class or a course's classes,
so a whole semester can be one lecture. The sheet's files live in `NewLectureFiles`: files that arrive while it is open (Add
Files…, a drop on the sheet or main window, or a drop SwiftUI delivers in pieces) are merged in, never
replacing the earlier ones; until the user reorders, parts stay sorted by name, and afterwards new parts go at the end. `LectureSession.start` then processes the files, several at once (`partConcurrency`), and
`LectureSession.combine` joins them into one timeline: each part's slides and transcript are shifted by
the total length of the parts before it, and each recording keeps its own slides (the cap is per
recording and grows with its length). The model is
told where each part starts, and the part list is saved with the lecture (`SavedLecture.parts`) so
notes written later use it too. A part with no audio still contributes its slides; the lecture fails only
if it has nothing at all to write notes from: no speech, no slide, and no material text. A screen
recording with no sound gets notes from its slides (before 2026-11-16 it failed with "no audio track"). Dropped files that are not video or audio are ignored.

Every lecture is saved to the **history** on the device as soon as its slides and transcript are
ready, before the model is called, so a failed or cancelled model call never loses the on-device work.
The notes are added to the saved lecture each time the model finishes writing them. The original
video or audio file is not copied.

### Supporting materials

Alongside (or instead of) a recording, a lecture can include slides, handouts, readings, and photos.
`Backend/Documents/DocumentToText.swift` reads their text on the device, with Apple frameworks only:

| File | How it is read |
|---|---|
| PDF | PDFKit, page by page. A page with under 20 characters of text is treated as a scan: it is rendered at 2× and read with Vision text recognition (`RecognizeTextRequest`) |
| Word `.docx`, PowerPoint `.pptx` | These are zip archives of XML. `ZipArchive.swift` reads them with the Compression framework (stored and deflate entries), then `XMLParser` collects the `w:t` / `a:t` text runs. Slides are read in slide-number order |
| `.txt`, `.md` | As UTF-8 text |
| Images | Vision text recognition |

Not supported: `.doc`, `.ppt`, Pages, Keynote (export them as PDF). Apple's own `.docx` reader
(`NSAttributedString` with `.officeOpenXML`) exists only on macOS, which is why the zip reader is used
on both platforms. Each file's text is capped at 120,000 characters (marked as trimmed), so one long
reading can't crowd the lecture out of the model's context. A file that can't be read is kept with its
error and the lecture continues; a lecture needs either a recording with speech or some material text.
The text goes into the prompt as "Supporting materials" before the transcript, and is saved with the
lecture (`SavedLecture.documents`).

### Notes at several levels of detail

A lecture keeps one `NoteVersion` per `NoteDetail` level (`SavedLecture.notes`): the text, the model
that wrote it, and when. A new lecture writes the level chosen in the New Lecture sheet; the Notes tab
writes any other level on demand with `LectureSession.resummarize(settings:detail:)`, reusing the
extracted slides, transcript, and materials. Writing a level replaces only that level
(`LectureHistory.saveNotes`). One level is written at a time; a failure is tied to its level
(`failedDetail`) so it doesn't show on the others. Records saved before versions existed have a single
`summary` string, which `noteVersions` presents as one version with no level ("Earlier notes"); the
first new version moves it into `notes`.

The New Lecture sheet opens for every upload and includes the model and detail choice
(`Frontend/NoteOptions.swift`, shared with Settings). It edits the saved settings, so the choice is
remembered; server addresses and API keys appear in the sheet only when they are missing.

### Selecting several items

The sidebar (`selection: Set<SidebarItem>`), Recently Deleted (`Set<UUID>`), and the transcript are
multi-select lists. Actions use `.contextMenu(forSelectionType:)`, which acts on the whole selection (or
on the right-clicked row if it isn't selected), and `.onDeleteCommand` for the Delete key on macOS.
Moving more than one lecture to Recently Deleted asks for confirmation; one lecture doesn't (it can be
restored). Deleting for good always asks. Batch operations are `LectureHistory.moveToRecentlyDeleted`,
`restore`, and `deletePermanently` taking `[UUID]`: a failure doesn't stop the rest, and the first
error is reported at the end. Transcript rows don't allow selecting text inside them, because that
would take the clicks that select rows; copying is done per line instead (⌘C).

### Model lists

The model menus come from the providers themselves (`ModelCatalog` in `FileToAI.swift`), so new
models appear without an app update:

| Provider | Request | Notes |
|---|---|---|
| Claude | `GET /v1/models?limit=100`, following `after_id` while `has_more` | Display names and context windows; needs the API key. Without a key, or if Anthropic can't be reached, the built-in list (`FileToAI.claudeModels`) is shown with a note |
| Ollama | `GET /api/tags` | The models pulled on that machine |
| OpenAI-compatible | `GET {base URL}/models` → `data[].id` | Most servers offer it (LM Studio, OpenRouter). OpenRouter also gives `name` and `context_length`. Shown as a menu next to the model text field, because some servers list hundreds |

The list reloads when the provider, server address, or key changes (after a short pause, so typing a
key doesn't send a request per keystroke), and with **Refresh Model List**. A saved model that the
list doesn't include stays selectable. `AppSettings.connection()` gives the address and key without
requiring a model to be chosen.

Settings is split so most people see only what they need. Shown: provider, model with a one-line
description (`AIModelFields.describeBrief`, which also warns when the model can't see slides), the
Claude API key, and note detail. Under **Advanced** (collapsed; open/closed is remembered with
`@AppStorage("showsAdvancedSettings")`): server addresses, the OpenAI-compatible key and context
window, the full model details, Refresh Model List, split-without-asking, and the slide settings. The
model list and the chosen model's details live in one `ModelListState` shared by both halves, so they
agree and load once. Advanced is opened with a plain button, not a `DisclosureGroup`: an empty
DisclosureGroup in a macOS form could not be opened through accessibility, so VoiceOver users couldn't
reach it. The New Lecture sheet uses `AIModelFields(mode: .sheet)`, which shows addresses and keys
only when they are missing.

The full details (`AIModelFields.describe`, under Advanced) say what the chosen model is, its context
window, the longest notes one request can produce, and whether it can see the slides. They update
with the selection. Where the facts come from:

| Provider | Description | Context window | Longest notes | Sees slides |
|---|---|---|---|---|
| Claude | A line per family (Opus/Sonnet/Haiku/Fable) | `max_input_tokens` | `max_tokens`, capped at the app's 64,000 | `capabilities.image_input.supported` |
| Ollama | Size and quantization from `/api/show` `details` | `/api/show`, or the Ollama **Context window** setting (above 262,144 the panel explains the cap) | Not reported | `"vision"` in `/api/show` `capabilities` |
| OpenRouter | `description` | `context_length` | `top_provider.max_completion_tokens` | `"image"` in `architecture.input_modalities` |
| Google Gemini | Not reported | `inputTokenLimit` from Google's own list (`GET /v1beta/models`), since its OpenAI-format list has none | `outputTokenLimit` | Not reported |
| Other OpenAI-compatible | Not reported | The Context window setting | Not reported | Not reported |

Ollama's facts (and a Claude model missing from the list) are fetched for the selected model only
(`ModelCatalog.details`).

When an OpenAI-compatible server's list gives a model's context window (OpenRouter's
`context_length`, or Gemini's `inputTokenLimit`, added from Google's own list by
`ModelCatalog.addingGeminiLimits`), choosing that model, by the menu or by typing, sets the **Context window** setting
to it (`AIModelFields.listedContextWindow`), so long lectures are split to the right size. The setting's
menu shows that exact value even when it isn't one of the presets.

### Lectures too long for one request

Before writing notes, `LectureSession` asks the provider about the model once (`ModelCatalog.check`:
its context window, its reply limit, whether it sees images, and whether the key is accepted) and
works out the window to plan for (`LongLectures.contextWindow`):

| Provider | Where the window comes from |
|---|---|
| Claude | `GET /v1/models/{model}` → `max_input_tokens` (1,000,000 for the current models) |
| Ollama | The Ollama **Context window** setting under Advanced when it isn't Automatic; otherwise `POST /api/show` → `model_info["<general.architecture>.context_length"]`, capped at 262,144 (raised from 131,072 on 2026-11-12 for Nemotron 3's 256K). Ollama's MLX builds report no length, so Automatic falls back to 32,768. `num_ctx` is sized to each lecture, so a big window only costs memory when a lecture fills it |
| OpenAI-compatible | The window the server's model list gives for the model (OpenRouter, Gemini); otherwise the **Context window** setting, since there is no standard way to ask. The setting is kept per service (`Stored.serviceContextTokens`), and a level with its own model uses its own service's setting (`AppSettings.contextSetting(for:)`) |

If the server can't be asked, 32,768 is assumed. Room is kept for the notes themselves (64,000 tokens
for Claude, which is its `max_tokens`; a quarter of the window, at most 16,384, for the others), and
the rest is the input budget. The lecture's size is estimated generously (characters ÷ 3, 1,600 per
slide image, 3,000 for the instructions). Ollama's `num_ctx` is never set above the model's window,
so Ollama no longer silently cuts off the end of a long lecture.

If the lecture doesn't fit, `LongLectures.plan` splits it by time into sections that each fit. Small
materials (a quarter of the budget or less) go with every section; larger ones get their own
sections, split at paragraph breaks. The app asks first (`Phase.awaitingSplitApproval`, shown as a
card in the Notes tab) unless **Split long lectures without asking** is on. Each section is sent with
a note saying which part it is and which stretch of time it covers. Then the parts are combined: Key
points and Concise notes are rewritten into one; Detailed and Complete notes are joined in order and a
separate request writes the Key takeaways, because rewriting very long notes would hit the model's
output limit. If the parts' notes are too long to send back in one request, they are merged in rounds first
(`LongLectures.batches`, `combineRequest(isFinal: false)`): a few parts at a time, then those
results, until everything fits one final request. For Detailed and Complete, the rounds only shrink a
copy (at Key points level) to write the takeaways from; the parts themselves are kept as written.
The saved version records how many parts it was written in (`NoteVersion.parts`).

### History and Recently Deleted

`Backend/History/LectureHistory.swift` stores each lecture as a folder under the app's Application
Support directory (inside the app container on macOS):

```
Lectures/
└── <lecture ID>/
    ├── lecture.json      title, date, transcript, slide timestamps, notes, deletedAt
    └── frames/
        ├── 0.jpg         slide images, in the order of the timestamps in lecture.json
        └── 1.jpg
```

Renaming rewrites the title in `lecture.json` (`LectureHistory.rename`); an open lecture follows the
new name, which is also what the model is given for the next notes written. Renaming is offered from
the sidebar's context menu and by clicking the lecture's name in the toolbar
(`Frontend/RenamableTitle.swift`). On macOS the toolbar field is an AppKit `NSTextField`: SwiftUI's
`@FocusState` did not give focus to a text field in the macOS toolbar, and SwiftUI's own
`navigationTitle(Binding)` rename is reported not to work on macOS.

Deleting a lecture only sets `deletedAt` in its `lecture.json`, which moves it to Recently Deleted.
From there it can be restored, deleted for good by hand, or it is deleted for good automatically 30
days later (checked at launch and whenever Recently Deleted is opened).

## Project layout

```
Lecture Me Faster/
├── MyApp.swift                    App entry point
├── LIBRARIES.md                   Every framework and service the app uses
├── Backend/
│   ├── VideoToFrames.swift        Samples the video, keeps one frame per slide change
│   ├── AudioToTranscription.swift On-device speech-to-text (Apple SpeechAnalyzer)
│   ├── FileToAI.swift             Builds the prompt, calls the model, streams the notes back
│   ├── AppleIntelligence/
│   │   └── AppleIntelligence.swift Apple's on-device model (Foundation Models framework)
│   ├── LongLectures/
│   │   └── LongLectures.swift     Context windows, splitting long lectures, combining the parts
│   ├── Documents/
│   │   ├── DocumentToText.swift   Reads text from PDF, Word, PowerPoint, text, and image files
│   │   └── ZipArchive.swift       Minimal zip reader for .docx and .pptx
│   └── History/
│       ├── SavedLecture.swift     The saved record of one lecture
│       └── LectureHistory.swift   Saves lectures to disk; history and Recently Deleted
└── Frontend/
    ├── ContentView.swift          The window: sidebar, detail pane, drops, sheets, and alerts
    ├── Metrics.swift              Shared spacing and widths, `Notice` panels, and `EmptyState` screens
    ├── ImportView.swift           The first screen: drop area, Add Files, detail and model, where the lecture is sent; `LogoMark`
    ├── ProcessingView.swift       The steps shown while a lecture's files are read
    ├── HistorySidebar.swift       New Lecture, the history grouped by date, and Recently Deleted
    ├── SavedLectureView.swift     Shows a lecture reopened from the history
    ├── RecentlyDeletedView.swift  Restore, delete now, delete all
    ├── LectureResultView.swift    Notes, Transcript, and Slides tabs
    ├── MarkdownView.swift         Renders the notes' Markdown
    ├── SettingsView.swift         Provider, model, and slide settings
    ├── LectureSession.swift       Runs the pipeline, joins multi-file lectures, saves to the history
    ├── NewLectureSheet.swift      Names a lecture, orders parts, lists materials, picks model and detail
    ├── NoteOptions.swift          Model list state, model pickers (basic + advanced), detail slider
    ├── RenamableTitle.swift       Toolbar title you click to rename the lecture
    └── AppSettings.swift          Saved settings; API keys go in the Keychain
Lecture Me FasterTests/            Unit tests (Swift Testing)
Tools/make_icon.swift              Draws the app icon and writes every size into the asset catalogue
Secrets.example.env                Template for your git-ignored development keys
```

### Backend details

- **VideoToFrames** is built so no slide is lost. Pass 1 decodes a 320×180 grayscale picture every
  second and splits it into 16×9 blocks; a new slide starts when any block has 3 or more pixels that
  changed by more than 24 levels compared with the *first* picture of the current slide (comparing with
  the previous second missed cross-fades, which change a little each second). Blocks that change in more
  than 60% of seconds (a webcam, a clock) are ignored; if most blocks do (a camera on the professor),
  only large changes count. **Live footage** (a camera on a person or a board) is recognised locally:
  when at least 75% of the seconds within ±5 s each change 20+ blocks, only a *cut* starts a new frame
  (brightness histogram distance > 0.3 or mean difference > 40), captured mid-shot. Flat frames (a fade
  to black) are dropped. Measured on a real 60 s 4K team-intro video (three talking-head shots with
  burned-in captions and fades): 49 frames before, 4 after (title card + one per speaker). Pass 1 keeps
  only counts, not the pictures, so memory stays small.
  Each slide is captured at its last settled second (not mid-fade), so a slide whose bullets appear
  one by one is captured complete. Pass 2 decodes those moments at full size, drops repeats (going back
  to an earlier slide), reads each slide's text and picture content (`analyze`), merges neighbouring
  frames with the same words that differ only in often-changing blocks, and merges build steps (the
  words of a slide are on the next one, which adds some; on slides of 10+ words up to a tenth may be
  missing, since text recognition misreads a word or two in a live code editor). Every distinct slide
  is kept, up to a safety cap per recording that grows with its length (`storedFrameCap`): 1,000, or
  one per 5 seconds of video when that is more (8,640 for 12 hours). Raised from a fixed 300 on
  2026-11-13: an 89-minute live-coding lecture had 653. Slides average about 65 KB. Joining recordings
  thins nothing more, so 13 recordings keep all of each one's slides. The cap exists only so a video the
  slide finder misreads (a frame kept every second) can't grow without end. The repeat check (going back
  to an earlier slide) looks at the 200 most recently kept slides (`repeatWindow`), so its cost grows
  in step with the lecture, not with its square. A slide revisited after more than 200 others is kept
  twice, which never loses one.
  The repeat check first compares 20×20 block averages: a block average that moved by 26 or more
  proves at least 3 pixels changed by more than 24 (a change), so the full pixel count runs only when
  it might say "repeat". That full check then reads the blocks in order of how much their averages
  moved, and stops at the first changed block (`Motion.isChange(_:_:blockMeans:_:)`, tested to give
  exactly the same answer). The per-pixel loops read memory directly instead of indexing arrays.
  Why: on an 89-minute live-coding lecture (2026-11-13), pass 2 compared every new frame with every
  kept one. In a Debug build that took 534 s for 5% of the progress bar, and slowed down further as it
  went, so the app looked stuck. The same lecture had 1,060 frames with exact build merging and 653
  with the tolerant rule.
- **Builds by picture (`mergingAdditions`, 2026-11-13):** before the text-based steps, a frame is dropped
  when all of its drawing is still visible in at least one of the next 4 kept frames (`coverageWindow`):
  a bullet, a typed line or a pen stroke added, or writing hidden behind the lecturer in one frame but
  shown in a later one. The pass runs backwards, so frames are only checked against frames that stay.
  Only real frames are kept, never a picture pieced together, and the next kept frame takes the dropped
  one's time. The frames are compared at 640×360, decoded from
  the JPEGs, and an ink pixel of the earlier frame (more than 48 from the background) must still be ink
  at exactly the same place on the later one: not background, and within 72 of its brightness. Then:
  - At most 6 missing pixels: an addition.
  - Missing pixels within a 40×40 patch (a moved mouse pointer or text cursor): an addition only if every
    word read on the earlier frame is still there.
  - Otherwise both frames are kept.
  Areas in constant motion (a webcam) are left out, and live footage never merges.
  What each rejected design got wrong, on the 89-minute lecture (653 frames before):
  - 320×180 with 1% of ink allowed: 131 frames, but it merged an erased whiteboard, because it skipped
    "busy" areas, and it merged same-template slides ("Slide 1" looked contained in "Slide 2").
  - One pixel of slack: a 5 changed to a 6 showed 0 missing pixels.
  - "Any non-background counts": a person in front of the board counted as ink.
  Against the next frame only it kept 590 frames; against the next 4 (the whiteboard parts), 542. Of
  the 116 merged away, the median kept 100% of its words in the next few kept frames. The lowest
  scorers, checked by eye, were the same board with the text reader misreading handwriting. The
  team-intro video still gives 4 frames. Before the 4-frame window, the 68 merged away had a median of 100% of their words in their
  replacement (lowest 80%, checked by eye: the same code with the pointer moved). Tests:
  `AdditionMergeTests`, plus every `SlideCaptureTests` no-slide-lost case.
- **Speed (measured on that 89-minute lecture, 2026-11-13):**
  - Text recognition reads `readingConcurrency` slides at once (8 on a 14-core Mac). On 200 real
    slides: 1 at a time 0.119 s a slide, 2: 0.057, 4: 0.030, 8: 0.022, with identical text. Scanned
    PDF pages use the same limit, and pages are rendered one at a time, so memory holds only that many.
  - Vision's first request loads its model, which took 27 s. `warmUpTextRecognition` does this during
    pass 1.
  - Pass 2 asks for all its moments in one `images(for:)` batch, and encodes a JPEG only for frames it
    keeps.
  - The pixel loops are separate raw-pointer loops, not one loop that takes a closure. In Debug, the
    closure call per pixel tripled pass 1.
  - The progress bar is split by measured time (`Stage`): scan to 40%, capture to 65%, reading to 97%.
  - Totals: Release 215 s → 60 s. Debug 31.5 min → 83 s. Output identical: the same 653 slides, with the
    same text for each.
  - Within one file, slides and transcript already run at the same time (`process`: two `async let`).
    Several files now run at once too (`LectureSession.inOrder`, results kept in playing order). Audio
    only: 4 at a time; with any video: 2 (`partConcurrency`). Measured on 4 real 75-minute WAVs: 249 s one
    at a time, 134 s two at a time, 77 s four at a time.
  - **One recording in pieces.** A recording is also split into up to 4 time ranges worked on at once,
    each at least 5 minutes long. About 4 run in total: 1 file → 4 pieces, 2 → 2, 4 or more → 1
    (`transcriptionPieces`).
    - Audio (`AudioToTranscription`): each cut moves to the quietest half-second within 30 s of its
      planned point (`quietestMoment`), so no word is split. Each piece starts 30 s early so the
      recognizer has context, and runs 20 s past its range. Pieces are joined **word by word**
      (`merge`): the recognizer reports each word's time (`.audioTimeRange`), and each piece contributes
      exactly the words that start in its own range. The first version joined whole sentences and
      dropped any sentence that started before the previous one ended. On a 36-minute known script, that
      lost up to 28 s of speech at a cut (+1.06 points of word error). Each piece feeds its range to the
      recognizer through an `AsyncStream`, with no temporary file.
      Word error rate on the 36-minute known script (`say` speech of this README and HELP, 3 cuts):
      1 piece 6.83%; 4 pieces one after another 6.80% (even cuts) and 6.84% (pause cuts); 4 pieces at
      once with pause cuts, as the app does, 6.67–6.81% over 3 runs. Running pieces at once adds about
      ±0.1 points of run-to-run variation; one after another is repeatable. A real 73-minute lecture: the
      same 11,356 words as 1 piece, 58 s → 19 s. Settings > Advanced > Speed > "Transcribe long
      recordings in pieces" (`transcribeInPieces`, on by default) turns it off for the same transcript
      every time.
    - Slides, pass 1 (`scanTimeline`): one-minute blocks are decoded up to 4 at a time, each with its own
      `AVAssetImageGenerator`, and added to the timeline strictly in time order. So the result is
      identical to decoding one sample after another: the same 653 slides and text on the 89-minute
      lecture, while pass 1 went from 25 s to 12 s. At most 8 decoded blocks wait in memory (about 3.5 MB
      each). The first version scanned separate pieces with a 30 s warm-up and joined them. That kept 647
      slides, not 653, because each piece learned the moving areas on its own.
    - The whole video (slides and audio together, Debug test host): 84 s → 69 s.
  - Speech, Vision and Apple Intelligence are Apple's on-device models. The system decides whether
    each runs on the Neural Engine, GPU or CPU; the app does not choose. To see it, run
    `sudo powermetrics --samplers ane_power` while a lecture processes.
  Why: the old method (48×48 thumbnail, 3% of pixels, every 2 s, then evenly thinned to 30) kept 1
  frame for a generated 45-slide deck in one template, and missed a one-formula change and a 3-second
  slide. Measured now (`SlideCaptureTests`): every slide kept with noise, a webcam overlay, and fades
  together; a generated 1-hour, 120-slide video took about 2 minutes on an M4 Pro.
- **The slide limit (Settings, 30 by default) is the number of slides sent as images**, not kept.
  When a lecture has more, `VideoToFrames.imageChoice` sends the ones with the most picture content as
  images and the rest as their text (`FileToAI.slideAsText`), so none is left out. Picture content
  (`visualScores`) is the share of a 64×36 thumbnail that differs from the deck's template (the median
  of all slides, so a header bar on every slide doesn't count) outside any text box.
  When a lecture is written in parts, the plan is made with the limit's most visual slides of the whole
  lecture as images (a bounded amount). Then each request with room left gets more images, up to the
  limit per request (`LongLectures.imagesThatFit`). Requests are fixed before those are added, so
  images can never add requests. Why (2026-11-13): an earlier version chose up to the limit per section
  first and planned after. Every new section brought more images and so more sections, and together
  with the reply-reserve bug below, 653 slides were planned as 931 requests.
- **Apple Intelligence accuracy experiments (2026-11-13):** Key points of the 89-minute pointers lecture
  (542 slides, 29–31 parts), scored by hand against 16 facts from Claude Haiku's notes:
  - Default sampling: about 8.5 facts, 521 words, 9 min.
  - Greedy sampling: one run took 78 min; with the prompt change it looped ("B → [i]" … "B → [z]"),
    1,254 words.
  - Spoken-code prompt ("b sub k is b[k]", copy code from slides): about 11 facts and 704 words in one
    run, but a worse 1,382-word set in the next. At temperature 0.3 it copied garbled handwriting
    recognition word for word.
  Neither change is in the app (the off switches kept for measuring were removed on 2026-11-16):
  run-to-run variation was bigger than either effect. Apple Intelligence also ignored the
  500-word target (521–1,382 words). One deterministic fix was kept: `removingEmptyMaterialsSection`
  strips a "From the materials" section from notes of a lecture without materials, which 4 of 6 runs
  wrote despite the prompt.
- **Selecting and copying notes (2026-11-13):** `MarkdownView` renders the whole note as one `Text`
  (`document(from:)`): headings in larger bold type, indented list markers, code on a tinted background.
  A selection can therefore cross blocks; before this, each block was its own `Text` and only one line
  could be selected at a time. **Copy Notes** (⇧⌘C) puts HTML (`MarkdownView.html(from:)`) and Markdown on
  the pasteboard. Emphasis needs text touching its markers, so `2 * 3 * 4` and `snake_case_name` stay as
  they are. `NotesCopyTests` covers both.
- **Brief levels stay brief when written in parts (2026-11-13):** Key points has a target of about 500 words
  for the whole lecture, and Concise about 15 words a minute, between 800 and 3,000
  (`LongLectures.targetWords`). Each part is told its share (`shareOfWords`, at least 60 words); each merge
  round is told the share of the parts it covers; the final rewrite gets the target. When notes are each
  too long to merge with another, every one is shortened to its share (`shortenRequest`), within at most 8
  rounds. Before this, each of N parts wrote a full two-to-three-minute summary. If the final request still
  didn't fit, all the parts were pasted together, so with Apple Intelligence's 8K window, Key points came
  out longer than Detailed. `BriefLengthTests` checks this against `MockModelServer`, whose new `chat:`
  responder answers by request text. With the shortening step switched off, the test fails.
- **Faster ↔ Most accurate slider (`SpeedSlider`, `AppSettings.SpeedPreset`, 2026-11-13):** in Settings > Advanced
  only; Balanced by default (it matches the earlier defaults, so existing settings land there). The positions
  set `maxFrames` (10/30/60 images per request), `describeSlides` (off/on/on) and `transcribeInPieces`
  (on/on/off). Changing one of these by hand shows Custom. Slide finding is deliberately not on the
  slider, because each variant measured on the 89-minute lecture lost something:
  - Sampling every 2 s: 195 frames in 20 s, but it skipped a 160 s stretch of board work (1 s gave dozens
    of frames there), probably because twice the change per sample looked like live footage.
  - Sampling every 0.5 s: 1,724 frames, over the 1,068 cap, so they were thinned evenly.
  - Vision's `.fast` text level: 0% of the accurate level's words, on handwriting and on typed code.
  `SpeedPresetTests` covers the presets; `SlidesAsTextTests` checks that with descriptions off, none is
  written or sent.
- **Model per level of detail (2026-11-13):** `Stored.levelModels` maps `NoteDetail.rawValue` to a
  `ModelChoice` (provider, OpenAI-format service id, model). `AppSettings.configuration(for:)` uses it
  when set, else the default, and `summarize` calls it for the level being written. The pickers
  (`LevelModels.swift`: `LevelModelsSection` in Settings, `LevelModelPicker` in `ModelSwitcher`) list the
  models of every provider in `usableConnections`, loaded with `ModelCatalog`. A saved choice stays listed
  even when its provider's list can't load. `LevelModelTests` covers it; one test checks against
  `MockModelServer` that Key points requests carry the level's model and Detailed the default.
- **Changing the model from a lecture (2026-11-13, moved 2026-11-16):** the top left of the lecture shows `AppSettings.chosenModelName`
  and opens `ModelSwitcher` (the New Lecture sheet's `AIModelFields`, plus Write/Rewrite). A split
  proposal on screen is worked out again (`LectureSession.replan`, `summarize(planOnly:)`) when
  `AppSettings.planningKey` changes: provider, model, key, address, context-window or slide settings,
  after a 0.5 s pause. It writes nothing; the proposal can come back as "fits in one request"
  (`SplitProposal.fitsInOneRequest`). Before this, the card kept the old model's numbers.
  `ReplanTests` checks it against `MockModelServer`.
- **Rejected keys and small windows (2026-11-13):** an expired Claude key made the context-window
  lookup fail, so the app fell back to 32,768 tokens. Claude's reply reserve was a flat 64,000, which
  left the 4,000-token minimum per request, and a lecture that fits in one request was planned as 931
  parts and about 1 million tokens. Now:
  - `ModelCatalog.check` checks the key before planning, in the same request that looks up the model
    (Claude: `GET /v1/models/{model}`; OpenAI-compatible with a key: `GET /models`). HTTP 401/403 stops with "The API key was rejected …
    may have expired, been revoked, or been mistyped …", keeping the provider's own message. 402 and 429
    get their own advice (`FileToAI.Failure.forStatus`), during the notes request too.
  - The reply reserve is at most a quarter of the window.
  - Claude's fallback window is 200,000 tokens when the Models API can't be reached.
- **Interface redesign (2026-11-16).** Every screen now takes its spacing from `Metrics` (4, 8, 12, 16,
  24, 40 points) instead of its own numbers, and its colour from `Color.brand`, a blue (#2774AE) set as
  the app's tint in `MyApp` (the "Brand" colour in the asset catalogue, the same in light and dark mode).
  - Messages are `Notice` panels: normal-coloured text on a tinted panel, replacing orange and red text
    that was hard to read in dark mode. Empty tabs and lists use `EmptyState`.
  - The first screen is `ImportView`: a drop area that turns blue while files are over it
    (`dropDestination`'s `isTargeted`), and a line saying where the lecture is sent.
  - `ProcessingView` lists the steps and their state (`ProcessingView.stages`, a pure function so it
    can be tested) in place of two bare progress bars.
  - The Notes tab's level picker is a row of buttons with a dot for written, a ring for unwritten, and a
    spinner for the level being written, replacing a segmented control with "✓" in its labels. Notes sit
    in a 720-point reading column with three heading sizes.
  - The sidebar groups lectures under Today, Previous 7 Days, and Earlier (`HistorySidebar.groups`).
  - Wording across Settings, the New Lecture sheet, alerts, and Recently Deleted was shortened.
  - To look at a screen from the terminal (the screen can't be captured there): in a test, put the view
    in an `NSHostingView` inside an `NSWindow`, call `cacheDisplay(in:to:)`, record the PNG with
    `Attachment.record`, run with `-resultBundlePath`, and export with
    `xcrun xcresulttool export attachments`. Lists in a sidebar don't draw correctly this way.
- **Folders (2026-11-16).** `LectureFolder` is an ID and a name; the list lives in
  `<root>/folders.json` and each lecture records its folder in `SavedLecture.folderID` (absent in older
  records, which still load). `LectureHistory` has `createFolder(named:)`, `renameFolder`, `deleteFolder`
  (its lectures become unfiled, including ones in Recently Deleted), `move(_:toFolder:)`,
  `lectures(in:)`, and `unfiledLectures` (which also holds lectures whose folder is missing, so none can
  become unreachable). Names are trimmed and kept apart ("Physics 2"). **New Folder** is a row under New
  Lecture that looks like it but is a button (it opens the naming prompt and is never selected); the
  Folders heading only appears once there is a folder. The sidebar shows folders as disclosure groups
  above the date headings; lectures are filed from the right-click menu, alone or
  several at once. Not built: dragging a lecture onto a folder, and folders inside folders.
- **Faster switching between lectures (2026-11-16).** Measured with a 120,000-character set of notes:
  reading the files took 3 ms, but laying the notes out as one `Text` took about 300 ms, and they were
  parsed again (70 ms) on every redraw. `MarkdownView` now shows long notes as several `Text`s in a
  `LazyVStack`, split at headings once a piece passes 6,000 characters (`sections(of:)`), and keeps the
  parsed result of the last 12 notes (`sections(for:)`). First display fell from about 400 ms to about
  130 ms, and to about 40 ms for notes seen before. The cost: in long notes a text selection stays
  inside one piece. Short notes are still one `Text`, and Copy Notes copies everything.
- **Hover highlight (2026-11-16).** `hoverHighlight(_:)` in `Metrics.swift` lays a faint tint over a
  control while the pointer is on it: the model name, the level buttons, the icons under the notes, the
  first screen's buttons, and Settings in the sidebar. Every sidebar row (New Lecture, New Folder,
  folders, lectures, Recently Deleted) uses `sidebarRowHover()` instead, which draws the tint as the
  row's `listRowBackground`, so it lines up with the selection highlight at any indent; a tint laid over
  the row's content started further right than the selection, worst inside a folder. It must sit on the
  row itself (for New Folder, on the button, not its label), or the list ignores it.
  `showsHoverForPreview` in the environment shows every highlight at once, for rendering screens in
  tests where there is no pointer.
- **Near-black dark mode (2026-11-16).** Three background colours in the asset catalogue replace the
  system's dark grey: `Color.canvas` (#0D0D0F) behind content, `Color.sidebarSurface` (#141416) behind the
  sidebar, and `Color.panel` (#1A1A1D) for boxes on the canvas. Their light-mode values are white and two
  near-whites, so light mode looks as before. Lists and forms take the canvas through
  `canvasBackground()` (which hides the system's own list background), and the window, including behind
  the toolbar, through `windowCanvas()`. Use these for any new screen.
- **Chat-app layout (2026-11-16).** The layout chat apps share, applied to lectures:
  - The model is a name with a chevron at the top left of the lecture (`LectureResultView.modelButton`),
    beside the tabs, and opens `ModelSwitcher`. It was a toolbar item, which macOS moved into the overflow
    menu when the lecture's or model's name was long, so it seemed to come and go.
  - Copy, Share and Rewrite are a quiet row of icons under the notes, with who wrote them
    (`actionRow`); Copy shows a tick for a moment. The lecture toolbar now holds only the name and New
    Lecture.
  - Settings is a row at the foot of the sidebar (`safeAreaInset`), also on ⌘,.
  - The first screen is a question over a rounded box like a message field: what to drop in it, then Add
    Files, the level of detail (a menu), and the model (opens `ModelSwitcher`). Both choices are the saved
    settings, the same ones the New Lecture sheet shows.
- **App icon (2026-11-16).** Six chalk-coloured bars on the brand blue (#2774AE), in two groups whose heights
  fall from left to right, so they read as a sound wave and as a fast-forward sign. `Tools/make_icon.swift`
  draws it with Core Graphics (no design file) and writes `AppIcon.appiconset`: one full-square 1024-pixel
  image for iPhone and iPad, and ten Mac sizes drawn as a rounded square with a margin and shadow. To
  change it, edit the script and run
  `swift Tools/make_icon.swift "Lecture Me Faster/Assets.xcassets/AppIcon.appiconset"`. The app target
  sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`. `LogoMark` draws the same bars on the first
  screen; its numbers must match the script's. There is no Vision Pro icon yet (that needs layered images).
- **Whole-codebase review (2026-11-16).** Found by reading every file, confirmed with probe tests
  that failed on the old code, and fixed:
  - *Stopped work carried on.* Cancel during transcription still saved a lecture (with no name and part
    of the transcript) and sent it to the model, and "Stop and Start New Lecture" left the stopped
    lecture's empty notes in the new one. Cause: a cancelled `SpeechAnalyzer` run returns what it has, and
    a cancelled `for try await` over an `AsyncThrowingStream` ends without an error, so the code after
    them ran as if they had finished. Now every `await` in `LectureSession.start` and `summarize` that is
    followed by a change to the session is followed by `Task.checkCancellation()` first, a stopped
    request no longer clears its replacement's state, and late progress from a stopped lecture is
    ignored (`generation`).
  - *An empty reply was saved as finished notes.* It is now `FileToAI.Failure.empty`.
  - *One Context window setting for every OpenAI-format service* (see the table above).
  - *Claude requests:* `output_config.effort` is left out for models that reject it (the Models API's
    `capabilities.effort.supported`, else by name: Haiku 4.5, Sonnet 4.5, Claude 3), `max_tokens` is
    never above the model's own limit, and the refusal fallback goes only to the models Anthropic's
    reference lists for it (Fable, Mythos, Opus 5 and 5.5, Sonnet 5.5; reference dated 2026-11-03).
    Not tried against the real API with an old model.
  - *Ollama's `num_ctx`* added only 6,000 tokens to the prompt; it now adds the instructions and the
    same reply reserve the plan uses (up to 16,384), so a long reply isn't cut off.
  - *One request before writing instead of three* (`ModelCatalog.check` replaced `FileToAI.verifyKey`,
    `ModelCatalog.acceptsImages` and the request inside `LongLectures.contextWindow`).
  - *A video that doesn't report its length* no longer hangs `scanTimeline` (the list of sample times
    never ended when the length wasn't a number; measured with a 3-line program).
  - *Slides tab:* each slide is shown as a 640-pixel copy made off the main thread and cached
    (`FrameThumbnails`), instead of decoding the full JPEG in the view's `body` on every redraw.
  - *Streaming a lecture written in parts* joins the finished parts once per part, not once per chunk.
  - Measured and left alone: opening a saved lecture reads its slides on the main thread, but 1,000
    slide-sized files (65 MB) read in 15 ms.
  - Removed as unused: `AppSettings.defaultModelChoice`, `PieceTuning`, the greedy-sampling and
    spoken-code switches, `combine(maxFrames:)`, `missingInk`'s `reach`, and four functions only tests
    called (now in `TestSupport.swift` or replaced). `AppSettings` builds a provider's configuration
    in one place instead of four. `VideoToFrames.Options.maxFrames` stays: the app never sets it, but it
    is how the slide cap is tested.
- **AudioToTranscription** splits the audio track out of videos into a temporary `.m4a`, then
  transcribes it with `SpeechTranscriber`. The speech model for your language is downloaded by the
  system the first time it is needed.
- **Slides for models that can't see images.** Before writing, `ModelCatalog.acceptsImages` asks the
  provider: Claude and Ollama per model (`capabilities`), OpenAI-format services from the model list
  (only OpenRouter says, via `architecture.input_modalities`), Apple Intelligence always yes. If the
  answer is no, each frame is sent as text instead of an image (`FileToAI.slideAsText`): the words
  Vision read from it plus a 2–4 sentence description of its visuals from Apple Intelligence
  (`AppleIntelligence.describeSlide`, about 1.5–2.5 s per slide measured on an M4 Pro; skipped when
  Apple Intelligence is off). If the provider doesn't say, the images are sent, and a rejection whose
  message mentions images, vision, or modalities (`FileToAI.isImageRejection`) sends the request
  again as text, once. Descriptions are cached for the session. The prompt tells the model it can't see
  the slides and to trust the transcript when they disagree. `NoteVersion.slidesAsText` records it, and
  the Notes tab shows an orange warning while writing and on those notes. Planning uses the average
  text slide size in place of an image's size.
- **Fixing misheard terms with the slides.** Speech recognition mishears rare terms and names
  ("Kol Megorov" for "Kolmogorov"). Before the notes are written, `VideoToFrames.readText` reads the
  text on every slide frame with Vision (language correction off, so rare words aren't "corrected"),
  and `FileToAI.slideTerms` keeps the words of four or more letters that never appear in the
  transcript, up to 150. Common words appear in both and drop out, so no dictionary is needed. The list
  goes into the prompt just before the transcript, with the instruction to use those spellings where a
  transcript word sounds like one. It is read once per lecture, even when slide images are turned off,
  and counted in the size estimate for long lectures. Measured on the on-device model (live test
  `LiveSlideTermsTests`, 5 runs, 2026-11-12): 0–3 of 8 misheard terms spelled right without the list,
  5–8 with it.
  Why not give the vocabulary to the speech recognizer itself? `SpeechAnalyzer` accepts a list
  (`AnalysisContext.contextualStrings`), but `SpeechTranscriber` ignores it: on macOS 27.2 its output
  was identical with and without the list. `DictationTranscriber` uses the list but transcribes ordinary
  speech worse ("Nike rate" for "Nyquist rate", missing punctuation), so the app keeps `SpeechTranscriber`.
- **FileToAI** supports four kinds of provider: Apple Intelligence (on the device, through Apple's
  Foundation Models framework), Ollama (`/api/chat`), Claude (`/v1/messages`), and anything that
  accepts OpenAI's format (`/chat/completions`). The network ones are called over plain HTTP with
  streaming; there are no SDK dependencies.
- **Apple Intelligence** (`Backend/AppleIntelligence/AppleIntelligence.swift`) is the default for new
  installs: free, private, offline, on any Apple silicon Mac with Apple Intelligence turned on. Its
  context window is small (`SystemLanguageModel.default.contextSize`: 8,192 tokens measured on an M4
  Pro with macOS 27.2), so most lectures are written in parts, without asking since it costs nothing.
  Because the window is small, the app measures with Apple's tokenizer instead of estimating: the
  instructions, one slide image, and the characters per token of the lecture's own text (about 5 for
  English, versus the generic estimate of 3). If a part still overflows (`contextSizeExceeded`), the
  lecture is re-split into smaller parts and tried again, up to four times. The framework streams
  snapshots of the whole reply, which `AppleIntelligence.newText` turns into increments. Availability
  (turned off, unsupported device, model still downloading) is reported in Settings and when writing.
- **OpenAI-format services** (`OpenAIService` in `FileToAI.swift`): OpenAI, Google Gemini, DeepSeek,
  OpenRouter, LM Studio, and "Other" (any address). Gemini and DeepSeek offer OpenAI-format endpoints, so
  one implementation covers them all. Each service is listed by name in the Provider menu and keeps its
  own API key (Keychain account `service.<id>`; "Other" keeps the older `openai-compatible` account) and
  its own model (`Stored.serviceModels`). To add a service, add one line to `OpenAIService.all` with its
  address, whether it needs a key, its `Secrets.env` variable name, `isFeatured`, and a one-line blurb.
- **The Provider menu** is kept short: Ollama, Claude, and the featured services (OpenAI, Google
  Gemini), then **Add Provider…**, which opens `AddProviderSheet` listing the rest (DeepSeek,
  OpenRouter, LM Studio, Other). Added ones are saved in `Stored.addedServices`; removing one keeps its
  key and model, and if it was in use the app switches to Ollama. The provider in use always appears in
  the menu. Which services are featured is a judgment call, not usage data (`isFeatured`).
- **Note detail** (`NoteDetail` in `FileToAI.swift`): four levels, Key points, Concise, Detailed (the
  default), and Complete, chosen with the slider in Settings. Each level replaces the paragraph of the
  system prompt that sets how long and deep the notes are; the rules about misheard words and the
  Markdown the renderer supports are the same at every level. Every provider gets the same prompt.

## Building

Requirements: Xcode 27.2 or later. Targets macOS, iOS, and visionOS 27.2.

Open `Lecture Me Faster.xcodeproj` and run, or from Terminal:

```sh
xcodebuild -project "Lecture Me Faster.xcodeproj" -scheme "Lecture Me Faster" \
  -destination 'platform=macOS' build
```

## Development API keys

People using the app type their own API key into Settings, where it is saved in the Keychain. For
development you can skip that by keeping your keys in a file that git ignores:

1. Copy `Secrets.example.env` to `Lecture Me Faster/Secrets.env` (next to `MyApp.swift`).
2. Fill in the keys you use (see the template for every name):

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   GEMINI_API_KEY=...
   DEEPSEEK_API_KEY=...
   ```

3. Build and run. When a key field in Settings is empty, the app uses the key from `Secrets.env`.

How it stays safe:

- `.gitignore` excludes `Secrets.env`, so it is never committed.
- The file is copied into **Debug** builds only. The `EXCLUDED_SOURCE_FILE_NAMES[config=Release]`
  build setting keeps it out of Release builds, and the code that reads it is compiled only in Debug.
- A key entered in Settings always takes priority over the one in `Secrets.env`.

Do not share a Debug build of the app with anyone: it contains your `Secrets.env` in plain text.

## Testing

Press ⌘U in Xcode, or:

```sh
xcodebuild test -project "Lecture Me Faster.xcodeproj" -scheme "Lecture Me Faster" \
  -destination 'platform=macOS'
```

| Test file | Covers |
|---|---|
| `FileToAITests.swift` | Prompt assembly, the note-detail levels and that each provider receives the chosen one, the request sent to each provider, and parsing of each provider's response stream (text, errors, refusals, truncation) |
| `MarkdownViewTests.swift` | Markdown block parsing, including half-streamed code blocks |
| `DevKeysTests.swift` | Parsing of `Secrets.env` |
| `MultiFileLectureTests.swift` | Lectures made of several files: which files are accepted, sorting, the suggested name, joining parts into one timeline, silent parts, a lecture with slides but no sound written from its slides, and failing when there is no sound and no slide |
| `StoppedLectureTests.swift` | A stopped lecture leaves nothing behind: Cancel while a spoken recording is transcribed saves and sends nothing; a new lecture gets nothing from the one it replaced; a stopped request is not saved as notes; an empty reply is a failure. Uses `StallingModelServer`, which starts a reply and never finishes |
| `ReviewFixTests.swift` | The one question asked of the provider before writing (rejected key, unreachable server), Gemini's limits from Google's list, a context window per service and per level, Slides tab thumbnails, and a video that doesn't say how long it is |
| `EmptyMaterialsSectionTests.swift` | Removing an empty "From the materials" section |
| `TestSupport.swift` | Not tests: shorthands the tests use (`FileToAI.request(…detail:)`, `VideoToFrames.isAddition`) |
| `TestMedia.swift` | Not tests: generates the silent slide videos used by the media and multi-file tests, and spoken audio (`makeSpeech`, the system voice) |
| `DocumentToTextTests.swift` | Reading a real `.docx`, a `.pptx` (slide order, stored and compressed zip entries), text PDFs, scanned PDF pages and images with text recognition, the size cap, unsupported types |
| `LongLecturesTests.swift` | The context window to plan for from what each provider reports and the settings, input budgets, splitting by time and by paragraph, part prompts, and the whole flow against `MockModelServer`: asking first, one request per part plus combining, declining, "don't ask again", and lectures that fit |
| `OpenAIServiceTests.swift` | The short Provider menu and adding/removing providers, service addresses, keys and models kept per service, asking for a hosted service's key by name, old settings loading as "Other", and test settings never using `Secrets.env` keys |
| `SlidesAsTextTests.swift` | Slides as text in the prompt, recognising providers' image rejections, old notes loading, and the whole flow against `MockModelServer`: a model listed as text-only, a rejection retried as text, other errors not retried, and image models still getting images. `LiveSlideDescriptionTests` prints Apple Intelligence's description of a drawn bar chart and only runs with `TEST_RUNNER_LMF_LIVE_APPLE=1` |
| `SlideTermsTests.swift` | Picking slide words the transcript never says (case, short words, hyphens, possessives, the cap), where the term list goes in the prompt, and reading text from frames. `LiveSlideTermsTests` compares the on-device model's notes with and without the list and only runs with `TEST_RUNNER_LMF_LIVE_APPLE=1` |
| `AppleIntelligenceTests.swift` | Apple Intelligence as the default provider, streaming increments, the on-device model entry; small-window planning with measured sizes, batching, and combining in rounds end to end (`SmallWindowTests`). `LiveAppleIntelligenceTests` call the real on-device model and only run with `TEST_RUNNER_LMF_LIVE_APPLE=1` |
| `ModelCatalogTests.swift` | Parsing each provider's model list, following Claude's pages, a rejected key, the address asked for each provider, keeping the current choice in the menu, filling in the context window from the list, each provider's per-model facts, what the details panel says, the short description in basic Settings, merging list and looked-up details, and when the list reloads |
| `MockModelServer.swift` | Not tests: a fake model server inside the test process (`URLProtocol`), one made-up host per suite, used by the long-lecture and model-list tests |
| `MultiSelectTests.swift` | Moving, restoring, and deleting several lectures at once; selected sidebar lectures in history order; copied transcript lines |
| `NoteVersionsTests.swift` | Several note versions: a failed level leaves the others alone, a new lecture writes the level chosen when it was added, materials-only lectures can be rewritten, ordering |
| `MaterialsTests.swift` | Materials in the prompt, lectures made from materials alone, a silent video plus slides, unreadable files, and that test settings never touch the real ones |
| `TestDocuments.swift` | Not tests: embedded `.docx`/`.pptx` fixtures and generators for text PDFs, scanned PDFs, and images |
| `AppSettingsTests.swift` | Settings saved by older versions still load when a new setting is added; note detail is saved |
| `MediaPipelineTests.swift` | Slide detection on a generated 3-slide video, frame thinning, block comparison, and rejecting files with no audio |
| `SlideCaptureTests.swift` | No slide lost: generated decks in one template, a one-formula change, a 3-second slide, a bullet build (kept complete), going back to a slide, heavy noise, and noise + webcam + fades together, each checked by reading the slides' text back; fade detection, build merging, picture-content scores, and which slides get images. Takes about 2 minutes (it encodes videos) |
| `LectureHistoryTests.swift` | Saving and reloading lectures and slides, history order, saving notes later, one version per level and rewriting a level, old single-notes records, renaming (including when a toolbar edit should rename), part lists and loading records saved before them, delete/restore, delete for good, the 30-day expiry (with a test clock), ignoring broken folders, and reopening a saved lecture in a session |

| `FoldersTests.swift` | Folders: saved across a relaunch, name order and unique names, renaming, deleting (lectures kept), moving lectures in, between and out, restoring a deleted lecture to its folder, records from before folders, and a lecture whose folder is missing |
| `RedesignTests.swift` | Which progress steps a lecture shows and each one's state, the sidebar's date headings, the line saying where a lecture is sent, the logo's bars, and how long notes are split into pieces |

Not covered by automated tests: the accuracy of transcription (it depends on the system speech model),
live calls to real model servers, and the UI. When you change those areas, check them by hand with a
real lecture.

## Adding a setting

Add the property with a default to `AppSettings.Stored` **and** a line for it in `Stored.init(from:)`.
That initializer reads each setting on its own and falls back to the default when it is missing or
unreadable, so users' saved settings survive an update. Skipping it would either leave the new
setting stuck on its default or, with the compiler-generated decoder, reset every setting.

Tests run inside the app, so they share its saved settings and the Debug `Secrets.env` keys. Tests
must use `AppSettings(unsaved:)`, which never saves and ignores both the Keychain and `Secrets.env`, so a
test can't overwrite your settings or make a paid API call with your keys.

To also run the tests that use the real Apple Intelligence model (free and on-device, but about 30
seconds), set `TEST_RUNNER_LMF_LIVE_APPLE=1` before `xcodebuild test`.

## Adding a dependency

The app currently has no third-party dependencies. If you add a framework, package, or service, list it
in `Lecture Me Faster/LIBRARIES.md`.
