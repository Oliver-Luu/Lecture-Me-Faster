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

## Project layout

```
Lecture Me Faster/
├── MyApp.swift                    App entry point
├── LIBRARIES.md                   Every framework and service the app uses
├── Backend/
│   ├── VideoToFrames.swift        Samples the video, keeps one frame per slide change
│   ├── AudioToTranscription.swift On-device speech-to-text (Apple SpeechAnalyzer)
│   └── FileToAI.swift             Builds the prompt, calls the model, streams the notes back
└── Frontend/
    ├── ContentView.swift          Import/drop screen and progress
    ├── LectureResultView.swift    Notes, Transcript, and Slides tabs
    ├── MarkdownView.swift         Renders the notes' Markdown
    ├── SettingsView.swift         Provider, model, and slide settings
    ├── LectureSession.swift       Runs the pipeline and holds its state
    └── AppSettings.swift          Saved settings; API keys go in the Keychain
Lecture Me FasterTests/            Unit tests (Swift Testing)
Secrets.example.env                Template for your git-ignored development keys
```

### Backend details

- **VideoToFrames** samples one frame every 2 seconds, shrinks each to a 48×48 grayscale thumbnail, and
  keeps a frame only when more than 3% of the thumbnail differs from the last kept frame. If more
  distinct frames are found than the limit (30 by default), they are thinned evenly across the lecture.
- **AudioToTranscription** splits the audio track out of videos into a temporary `.m4a`, then
  transcribes it with `SpeechTranscriber`. The speech model for your language is downloaded by the
  system the first time it is needed.
- **FileToAI** supports three providers: Ollama (`/api/chat`), Claude (`/v1/messages`), and any
  OpenAI-compatible server (`/chat/completions`). All three are called over plain HTTP with streaming;
  there are no SDK dependencies.

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
2. Fill in the keys you use:

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   OPENAI_COMPATIBLE_API_KEY=...
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
| `FileToAITests.swift` | Prompt assembly, the request sent to each provider, and parsing of each provider's response stream (text, errors, refusals, truncation) |
| `MarkdownViewTests.swift` | Markdown block parsing, including half-streamed code blocks |
| `DevKeysTests.swift` | Parsing of `Secrets.env` |
| `MediaPipelineTests.swift` | Slide detection on a generated 3-slide video, frame thinning, and rejecting files with no audio |

Not covered by automated tests: transcription of real speech (it depends on the system speech model),
live calls to real model servers, and the UI. When you change those areas, check them by hand with a
real lecture.

## Adding a dependency

The app currently has no third-party dependencies. If you add a framework, package, or service, list it
in `Lecture Me Faster/LIBRARIES.md`.
