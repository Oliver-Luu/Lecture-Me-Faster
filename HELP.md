# Lecture Me Faster Help

## Quick start

1. **Pick a model** (one-time). The app starts with **Apple Intelligence**, which is free, private, and
   runs on your Mac. If it says it's turned off, turn it on in System Settings > Apple Intelligence &
   Siri. To use something else, click **Settings** at the bottom of the sidebar (or press ⌘,) and choose a provider:
   - **Ollama (local, free):** install [Ollama](https://ollama.com), then pull a model in Terminal, for
     example `ollama pull gemma3:12b`. It appears in the Model list. A model that can see images
     gets the slides as pictures; others get the text read from them instead (see "Models that can't
     see images" below).
   - **Claude:** paste your Anthropic API key and choose a model. The list comes from Anthropic, so it
     shows every model your account can use. Opus writes the best notes; Sonnet and Haiku cost less.
   - **OpenAI or Google Gemini:** choose it in the Provider menu, paste its API key, and pick a model.
   - **Other providers:** choose **Add Provider…** at the bottom of the Provider menu to add
     **DeepSeek**, **OpenRouter** (many companies' models with one key), **LM Studio** (local, free,
     no key), or **Other** (any service that accepts OpenAI-style requests, such as Groq or Mistral, at
     an address you enter). The provider joins the menu and is selected. To take it out of the menu,
     open Add Provider… again and click **Remove**; its key is kept in case you add it back.
   - Each provider remembers its own key and model, so you can switch between them. Keys are stored in
     the Keychain.
2. **Open a lecture.** Drag a video or audio file onto the rounded box in the main area of the window
   (not the sidebar), or click **Add Files** in it. The box turns blue while files are over it. The two
   buttons beside Add Files set how detailed the notes are and which model writes them, and the line
   under the box says where your lecture will be sent. For a lecture split across several files, or with slides and readings,
   select them all (⌘-click or Shift-click on a Mac); see below. A **New Lecture** sheet opens where you
   name the lecture and choose the **model** and **how detailed** the first notes should be. Your choice
   is remembered for next time. Click **Make Notes**.
3. **Wait for processing.** The app lists its steps (read the materials, find the slides, transcribe
   the speech, write the notes), ticks each one off as it finishes, and shows how far along the running
   ones are. Then the notes stream in as the model writes them.

## Adding slides, handouts, and readings

Add supporting files with the recording (choose or drop them all together): **PDF, Word (.docx),
PowerPoint (.pptx), text or Markdown, and images** (photos of the board, screenshots). The app reads
their text on your device and gives it to the model, which uses it to get terms and formulas right and
to fill in what the professor showed but didn't say. Anything important that the lecture didn't cover
goes in a final "From the materials" section.

- You can also make notes from materials alone, with no recording.
- Scanned PDFs and photos are read with text recognition, which is slower.
- Open the **Materials** tab of a lecture to see exactly what text was read from each file.
- Older formats (.doc, .ppt, Pages, Keynote) aren't supported: export them as PDF.
- Very long files are trimmed to the first 120,000 characters (about 50 pages of dense text); the
  Materials tab says when this happened.

## A lecture recorded as several files

If a class was posted in parts, choose or drop all the parts at once. A sheet opens where you:

- **Name the lecture.** The name is suggested from what the file names have in common.
- **Check the order.** Parts are sorted by file name (Part 2 before Part 10). If every file name has a
  date in it ("september 28", "Oct 5", "2026-10-12"), they are put in date order instead. Use the arrows or drag to
  reorder, or ✕ to leave a file out.

This also works for a whole course: add every class recording plus the readings and handouts, and you
get one set of notes for the semester, with topics labelled by the class they come from. A semester is
long, so the notes are written in many parts (13 classes of about 75 minutes took 17 requests).
- **Add anything you missed.** Click **Add Files…** or drop more files onto the sheet. Files dropped
  onto the main window while the sheet is open are added too; nothing already listed is replaced.

Click **Make Notes**. Several parts are processed at once (up to 4 audio files, or 2 when there is
video), and the progress shows how many are done. They are joined in order into one lecture with one set
of notes; Part 2's timestamps continue where Part 1 ends. A part with no sound (such as a slides-only
recording) still adds its slides.

## Reading the results

- **Notes:** the study notes. Drag across any part of them (headings, bullets and all) to copy a
  section, or click **Copy Notes** under the notes (⇧⌘C) to copy the whole level you're viewing. Pasted
  into Google Docs, Word, Pages or Notes it keeps its headings, bullets and bold; pasted into a plain-text
  app it comes as Markdown. The share button exports it.
- **Transcript:** the on-device transcription with timestamps.
- **Slides:** the frames that were captured, each with its timestamp.
- **Materials:** the text read from each supporting file (only when the lecture has some).

### Notes at every level of detail

A lecture can keep one set of notes at each level: **Key points**, **Concise**, **Detailed**, and
**Complete**. Pick a level at the top of the Notes tab. A filled blue dot marks a level that is already written, a
ring one that isn't, and a spinner the one being written now. For a
level that isn't written yet, click **Write … Notes**. The slides, transcript, and materials are reused,
so nothing is reprocessed, and the other levels are kept.

**Rewrite These Notes** (the circular arrow under the notes) writes the level you're viewing again, for example after
switching models or changing whether slides are sent. It replaces only that level. Each set of notes
shows which model wrote it and when. Only one level is written at a time.

Lectures saved before levels existed keep their notes under **Earlier notes**.

**New Lecture** (the
plus button) takes you back to the import screen; the lecture you were on stays in the history. Notes
still being written keep coming in the background. Opening another lecture while one is processing
asks before stopping it.

## Apple Intelligence

Apple Intelligence writes the notes on your Mac: nothing is sent anywhere, it works offline, and it
costs nothing. Its model is small and can only read about 8,000 tokens at once (roughly 6,000 words),
so most lectures are written in several parts and then combined. This happens automatically, without
asking. Expect a one-hour lecture to take a minute or two. Its notes are shorter and simpler than
those from large paid models like Claude or Gemini; Key points and Concise suit it best.

Apple Intelligence's model is small, so on technical lectures it can copy spoken code literally ("b sub
k" for b[k]) or get details wrong. For notes you'll rely on, use a larger model for those levels: for
example a local Ollama model (free), or Claude, under Settings > **Model for each level of detail**. Apple
Intelligence is fine for a quick Key points summary.

Even when a lecture is written in many parts, Key points stay a short summary (about 500 words) and
Concise notes about 15 words per minute of lecture: each part writes only its share, and the parts are
combined and shortened into one set of notes rather than placed one after another. Detailed and
Complete notes do keep every part as written, with key takeaways at the end.

If Apple Intelligence can't write a part because it's too long even after splitting (usually because
of many slides), turn off **Send slides to the model** under Settings > Advanced.

## Very long lectures

Every model can only read so much at once (its *context window*). Current Claude models take about a
million tokens, enough for any lecture. Local Ollama models usually take far less, and the app reads
each model's limit from Ollama (if a model doesn't report one, set it under Settings > Advanced >
Context window). For an OpenAI-compatible server, set **Context window** in Settings to
what the model is loaded with.

If a lecture with its slides and materials doesn't fit, the Notes tab tells you and offers to write
the notes in parts (with Apple Intelligence it just goes ahead, since it's free): each part of the lecture is sent separately, then the parts are combined. Click
**Write in N Parts** to go ahead, or **Cancel**. Writing in parts takes several requests, so it takes
longer and costs more with a paid service. Tick **Don't ask again** (or turn on **Split long lectures
without asking** in Settings) to skip the question next time. Notes written this way say "in N parts"
under the title.

To try a model with a larger window instead, click **Change Model…** on that message (or use the model
button in the toolbar). The message is worked out again for the new model straight away, and also when
you change the model or Context window in Settings. If the lecture now fits in one request, it says so;
click **Write Notes**. Nothing is sent until you click.

## Faster or more accurate

The **Faster ↔ Most accurate** slider, under Settings > Advanced, is on **Balanced** unless you change it. It sets three things at once:

| | Faster | Balanced | Most accurate |
|---|---|---|---|
| Slides sent as pictures per request | 10 | 30 | 60 |
| Slide descriptions for models that can't see images | Off (text only) | On | On |
| Audio | In pieces at once | In pieces at once | One pass, the same transcript every time |

More pictures let the model see more diagrams, but make requests bigger, slower and costlier on paid
services. If you change one of these under Advanced, the slider shows **Custom**. Finding slides and
reading their text work the same at every position: the faster and finer versions lost slides in
testing.

## A different model for each level of detail

In Settings, **Model for each level of detail** lets each level use its own model: for example Claude
Haiku (fast and cheap) for **Key points**, and Claude Opus or Fable (the strongest) for **Complete**. A
level left on **Default** uses the model chosen at the top of Settings. The menus list every
provider you've set up (a key for Claude or a service, or an Ollama address), so a level can also use a
free local model. The model name at the top left of the lecture, the split message, and the line under the notes show which model
a level uses. You can also change the shown level's model by clicking that name.

## Changing the model for a lecture

The top left of every lecture shows the model notes are written with (for example "Claude:
claude-opus-5-5"). Click it to pick another provider or model, or to fix a key, without opening
Settings. Then click **Rewrite … Notes** (or **Write … Notes** for a level you haven't written) in the
same popover. The choice is remembered for new lectures too.

## History

Every lecture you open is saved in the sidebar, newest first, under **Today**, **Previous 7 Days**, or
**Earlier** (or in a folder once you file it; see Folders below). It is saved as
soon as the slides and transcript are ready, so even if the model fails you can come back later and
write the notes from its Notes tab without reprocessing the file. Lectures marked with an orange dot and **No notes yet**
have a transcript and slides but no notes yet.

Click a lecture to read its notes, transcript, and slides. You can keep reading old lectures while a
new one is processing.

The history keeps the slides, transcript, and notes, not the original video or audio file. Everything
is stored on this device only.

## Folders

Folders keep a course's lectures together in the sidebar.

- **Make a folder:** click **New Folder** near the top of the sidebar, under New Lecture, and type a name.
- **File a lecture:** right-click it (or several selected lectures) and choose **Move to Folder**, then a
  folder. **New Folder…** in that menu makes a folder and files them in one step.
- **Take a lecture out:** right-click it and choose **Move to Folder > Remove from Folder**. It goes back
  under Today, Previous 7 Days, or Earlier.
- **Rename or delete a folder:** right-click the folder. Deleting a folder keeps its lectures; they go
  back to the unfiled list.
- Click the arrow beside a folder to hide or show its lectures. The number beside it is how many it holds.

A new lecture starts in no folder. A lecture you delete and later restore returns to its folder.

## Renaming a lecture

Click the lecture's name at the top of the window. It turns into a text box with the name selected:
type the new name and press Return (or click elsewhere). Esc cancels.

You can also right-click a lecture in the sidebar and choose **Rename…** (on iPhone and iPad, swipe
right on it). The new name is used everywhere, including the next time you click
the next notes you write. Notes already written keep any title they mention until you rewrite them.

## Selecting several lectures

In the sidebar, Shift-click to select a range of lectures or Command-click to pick individual ones. Then
right-click any of them, press Delete, or use the **Delete … Lectures** button that appears in the main
area. When more than one lecture is selected, the app asks before moving them to Recently Deleted.

The same works in **Recently Deleted** (restore or delete several at once) and in the **Transcript** tab
(select lines and press ⌘C, or right-click **Copy**, to copy them with their timestamps).

## Recently Deleted

To delete a lecture, right-click it in the sidebar and choose **Delete**, press Delete, or swipe left on
it and tap the trash button. It moves to Recently Deleted. Deleted lectures stay in **Recently Deleted**
for 30 days, then are deleted for good. In Recently Deleted you can:

- **Restore** a lecture to the history.
- **Delete Now** (right-click, swipe, or the Delete key) to delete lectures for good. It always asks first.
- Select several and use **Restore** or **Delete** in the toolbar or right-click menu.
- **Delete All** (toolbar) to empty Recently Deleted.

Deleting for good cannot be undone.

## Settings

Settings shows the essentials. Click **Advanced** for server addresses, the model's limits (such as
its context window), splitting long lectures, and slide options. The app remembers whether Advanced
was open.

| Setting | What it does |
|---|---|
| Provider / Model | Which AI writes the notes. Under the model, a line says what it is (and warns if it can't see slides). Under **Advanced**, the full details: how much it reads at once (its context window), how long its notes can be, and whether it can see the slides. Also offered when you add a lecture. The model list comes from the provider and updates when you change the provider, server, or key; **Refresh Model List** reloads it |
| Note detail | How much the notes say, from **Key points** (a two-minute summary) through **Concise** and **Detailed** (the default) to **Complete** (every step and example). The level the first notes of a new lecture are written at; also offered when you add a lecture. Other levels can be added from the Notes tab |
| Send slides to the model | Sends the slides as pictures, or as their text for models that can't see images. Turn off to save cost |
| Split long lectures without asking | Write lectures too long for the model in parts without asking first |
| Transcribe long recordings in pieces | On (default): a long recording's audio is split at pauses into up to 4 pieces transcribed at once, about 3 times faster with the same accuracy in testing, though a few words can differ between runs. Off: one pass, the same transcript every time |
| Context window (Ollama) | **Automatic** uses what the model reports, up to 262,144 tokens. Choose a size for models that don't report one (Ollama's MLX versions show 32,768 otherwise), within what the model supports. Bigger windows let a long lecture go in one request but use more memory |
| Context window (OpenAI, Gemini, DeepSeek, OpenRouter, LM Studio, Other) | How many tokens the server's model is loaded with; longer lectures are split to fit. Filled in automatically when the service says (OpenRouter and Google Gemini do). Each service keeps its own value, so a small size set for a local server isn't used for a hosted one |
| Send up to N slides as images per request | How many slides go to the model as pictures in each request (5–100). A long lecture written in several requests gets this many in each, so more of its slides are seen as pictures. Every slide (up to 1,000 per recording, or one per 5 seconds of a longer recording) is still kept and sent; the rest go as the text on them |

## What leaves your device

Slide extraction and transcription happen on your device. The transcript and slides are then sent to
the provider you chose. With Ollama on the same machine, nothing leaves your computer. With Claude or
another hosted API, the transcript and slides are sent to that service. API keys are stored in the
Keychain.

## Troubleshooting

**"Open Settings and choose an Ollama model."** No model is selected. Open Settings and pick one.

**"Couldn't load Anthropic's model list."** Usually the API key is wrong or missing, or you're offline.
The usual Claude models are still listed, so you can keep working.

**"Add your … API key."** Each service has its own key. Paste the key for the service shown in the
Provider menu. A key for one service doesn't work for another.

**Models that can't see images.** Not every model can look at pictures. When yours can't, the app
still uses the slides: it reads the words on each one and, if Apple Intelligence is on, has it write a
short description of what the slide shows (diagrams, charts, layout). That takes a second or two per
slide, on your Mac, at no cost. The Notes tab then shows an orange warning, because diagrams,
graphs, and handwriting can be missed or described wrongly. For the most accurate notes, choose a
model that can see images. The Model section in Settings says when a model can't.

If the service doesn't say whether a model can see images, the app tries the pictures first. If the
service rejects them, it sends the slides again as text automatically.

**"This server didn't give a model list."** Not every OpenAI-compatible server lists its models. Type
the model name instead.

**"Ollama is running but has no models."** Pull one in Terminal (`ollama pull gemma3:12b`), then click
**Refresh Model List**.

**"Can't reach Ollama at this address."** Start the Ollama app, and check the Server field (the default
is `http://localhost:11434`). On iPhone or iPad, enter the address of the Mac running Ollama.

**"This file has no audio track to transcribe."** The file has no sound, and no slides were found in
it either, so there is nothing to write notes from. A silent screen recording that does show slides
gets notes from the slides, with a notice that no speech was recognized.

**"The model answered with no text, so no notes were saved."** The request worked but the reply was
empty. Click **Write … Notes** to try again, or choose another model by clicking the model name at the top left. Some local
models spend their whole reply "thinking" and write nothing.

**"Some Files Can't Be Used."** The app reads video, audio, PDF, Word (.docx), PowerPoint (.pptx),
text, and image files. Export other documents as PDF. Drop onto the main area, not the sidebar.

**A material says "no text found" or "couldn't be read."** The file may be empty, password-protected,
or damaged. For a scanned PDF with very faint text, try a clearer scan or a photo.

**Why are some slides missing their first steps?** When a slide builds up (bullets appearing, code
typed line by line, a drawing in progress), only its fullest version is kept, at the time it began.
On a whiteboard, a frame is also dropped when everything on it is still visible in the next few kept
frames, even if the lecturer was standing in front of part of it. Nothing that was erased, scrolled
away or changed is ever dropped this way.

**"Finding slides in the video" takes a long time.** A long lecture with a screen that changes all
the time (live coding, writing on slides) can have hundreds of slides to read. An 89-minute coding
lecture took about 1 minute in testing. Long recordings are split into pieces that are worked on at
the same time, for the slides and the audio alike, and several slides are read at once. The bar moves
at a steady rate through every stage.

**"The API key was rejected".** The provider refused your key: it has expired, been revoked, or was
mistyped. Create a new key in your provider's console (for Claude: console.anthropic.com), paste it in
Settings, and write the notes again from the Notes tab. Your slides and transcript are already saved.
"Out of credit" means the account needs topping up; "limiting requests" means wait a minute and try
again. Apple Intelligence and Ollama need no key.

**The app wants to write a short lecture in hundreds of parts.** This shouldn't happen any more. It
was caused by a rejected key being mistaken for a tiny context window. If you see it, check your key and
the model's Context window setting.

**The first transcription is slow to start.** The system downloads the speech model for your language
the first time. Later lectures start immediately.

**"No speech was recognized in this recording" / the model says there's no transcript.** The
Transcript tab is empty: the speech recognizer heard nothing it could transcribe. Common causes: the
file's audio is silent or only music, the voice is very quiet or far from the microphone, or the
lecture is in a different language from your Mac's. The notes are then written from the slides only,
and if the slides have little on them (a camera on the professor, a blank screen), the model may say
there is nothing to write notes from. Attaching the lecture slides as a material (PDF or PowerPoint)
gives it something to work with.

**The transcript misspells technical terms or names.** That's normal for speech recognition, and the
Transcript tab always shows exactly what was heard. The notes correct it where they can: for videos,
the app reads the words on the slides and tells the model how they're spelled, so "Kol Megorov" in the
transcript becomes "Kolmogorov" in the notes. Audio-only lectures have no slides to check against, but
attaching the lecture slides as a material (PDF or PowerPoint) gives the model the right spellings too.

**The transcript is in the wrong language.** Transcription uses your system language and falls back to
US English. There is no per-lecture language setting yet.

**A local model is very slow or the notes are thin.** Long lectures are a lot of text for a small
model. Try lowering the slide limit, turning slides off, or using a larger model. A very large context
window also needs a lot of memory; if your Mac slows to a crawl, a model with a smaller window (the
lecture is then split into parts) may run better.

**"This lecture is too long to send in one request."** See *Very long lectures* above. Turning off
**Send slides to the model**, lowering the slide limit, or leaving out long readings makes the
request smaller, and may let it fit in one.

**The notes are too dense, or too thin.** Open the lecture and pick a briefer or more thorough level at
the top of the Notes tab, then click **Write … Notes**. The slides and transcript are reused, so only
the notes are written, and the original notes are kept.

**The notes mention slides but the model ignored them.** The model may not be able to see images, and
its service may not say so (some local servers drop pictures silently). Choose a model that can see
images.

**"The notes were cut off because the model reached its output limit."** Click **Rewrite These Notes**,
try a briefer level, or use a model with a larger output limit.

**"Couldn't Update History."** A lecture could not be saved, changed, or deleted on disk, usually
because the disk is full. The lecture you were working on is still shown; free some space and try
again.

**Too many or too few slides.** The app keeps every distinct slide, including ones shown for only a
few seconds and slides where a single formula changes. When bullets appear one at a time, it keeps the
finished slide. For camera footage (someone talking to a camera, with or without captions), it keeps one
frame per shot, taken mid-shot away from fades; blank fade-to-black frames are dropped. A webcam
overlay can still add a few extra near-duplicate slides; that's deliberate, since an extra slide costs little and a missing one loses content. A slide
shown for under a second can be missed. If the Slides tab is missing a slide you saw, please note its
time in the video.
