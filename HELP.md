# Lecture Me Faster Help

## Quick start

1. **Pick a model** (one-time). Click the gear icon to open Settings and choose a provider:
   - **Ollama (local, free):** install [Ollama](https://ollama.com), then pull a model in Terminal, for
     example `ollama pull gemma3:12b`. It appears in the Model list. To use slides, the model must be
     able to see images.
   - **Claude:** paste your Anthropic API key and choose a model. Opus writes the best notes; Sonnet
     and Haiku cost less.
   - **OpenAI-compatible:** enter the server's base URL and model name (LM Studio, llama.cpp,
     OpenRouter, and similar). The API key is optional for local servers.
2. **Open a lecture.** Drag a video or audio file onto the window, or click **Choose File…**.
3. **Wait for processing.** The app finds the slides and transcribes the speech on your device, then
   the notes stream in as the model writes them.

## Reading the results

- **Notes:** the study notes. Use the share button to copy or export them.
- **Transcript:** the on-device transcription with timestamps.
- **Slides:** the frames that were captured, each with its timestamp.

**Summarize Again** (the circular arrow) rewrites the notes without redoing the extraction and
transcription. Use it after switching models or changing whether slides are sent. **New Lecture** (the
plus button) clears everything.

## Settings

| Setting | What it does |
|---|---|
| Provider / Model | Which AI writes the notes |
| Send slides to the model | Turn off for models that cannot see images, or to save cost |
| Up to N slides per lecture | Upper limit on slides kept (5–100). Applies to the next lecture you open |

## What leaves your device

Slide extraction and transcription happen on your device. The transcript and slides are then sent to
the provider you chose. With Ollama on the same machine, nothing leaves your computer. With Claude or
another hosted API, the transcript and slides are sent to that service. API keys are stored in the
Keychain.

## Troubleshooting

**"Open Settings and choose an Ollama model."** No model is selected. Open Settings and pick one.

**"Ollama is running but has no models."** Pull one in Terminal (`ollama pull gemma3:12b`), then click
**Refresh Model List**.

**"Can't reach Ollama at this address."** Start the Ollama app, and check the Server field (the default
is `http://localhost:11434`). On iPhone or iPad, enter the address of the Mac running Ollama.

**"This file has no audio track to transcribe."** The file is a silent video. The app needs speech.

**The first transcription is slow to start.** The system downloads the speech model for your language
the first time. Later lectures start immediately.

**The transcript is in the wrong language.** Transcription uses your system language and falls back to
US English. There is no per-lecture language setting yet.

**A local model is very slow or the notes are thin.** Long lectures are a lot of text for a small
model. Try lowering the slide limit, turning slides off, or using a larger model.

**The notes mention slides but the model ignored them.** The model probably cannot see images. Choose a
vision-capable model.

**"The notes were cut off because the model reached its output limit."** Click **Summarize Again**, or
use a model with a larger output limit.

**Too many or too few slides.** A slide is captured when the picture changes noticeably, so a moving
webcam overlay can add extra slides and small handwriting changes can be missed. Adjust the slide limit
in Settings; the Slides tab tells you when distinct frames were dropped to fit it.
