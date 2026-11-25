# PPTReader

Read your course slides on a Mac with an AI tutor that has read the whole deck. Record the lecture, and afterwards get what the lecturer said that isn't on the slides, plus anything about how the course runs.

**English** · [中文](README.zh-CN.md)

PPTReader is a native macOS app. Open a course folder, page through PDF, PowerPoint or Word slides, and ask the AI about them: it has read the whole deck and sees the page you're on.

## What it does

**While reading**

- Press ⌘E to explain the current page. Select text, or Shift-drag a box around a figure or formula, to have it explained, translated or illustrated with examples. Or just ask (⌘L).
- Formulas, code, tables and diagrams render properly in answers; diagrams open in a zoomable preview and can be saved as images.
- Have each page explained as you turn to it, and set how long answers are and how many diagrams and worked examples they include.

**While revising**

- **Study roadmap** (⇧⌘M): the deck's structure as one map. Pages you've asked about are marked as covered, so what's left stands out.
- **Study notes**: tell it your background and what this course expects, and explanations follow suit. Long chats are condensed into a study record, so it doesn't forget what was covered.
- **Statistics**: reading time, questions, token usage and cost by day, deck and course.

**In class** (macOS 26 and later)

- Press ⇧⌘R to record. Transcription runs offline on your Mac and audio is never uploaded; live captions are optional.
- Afterwards, click **Organize with AI**: it fixes misheard terms in the transcript, lists **what the lecturer said that isn't on the slides** and **course arrangements** (exams, assignments, deadlines…), and tags the recording with the course code.
- Organized points appear in the margin of the matching slide; click one to jump to that moment of the recording.

## Getting started

1. Download `PPTReader-vX.Y-macOS-arm64.zip` from the [latest release](https://github.com/XYoungSky/PPTReader/releases/latest), unzip it and move `PPTReader.app` to Applications. The app isn't notarized by Apple; if the first launch is blocked, click "Open Anyway" in System Settings → Privacy & Security.
2. Press ⌘O to open a course folder. Course folders are read-only; PPTReader never changes anything in them.
3. In Settings → Model, add a provider, enter your API key, click **Test connection** and choose a model.
4. Open a deck and press ⌘E.

**Requirements**: an Apple Silicon Mac with macOS 14 or later; lecture recording needs macOS 26 or later. Opening PowerPoint / Word files needs Microsoft Office; PDFs don't. Settings, API keys, chats, statistics and recordings are kept when you upgrade.

## Models and providers

Any OpenAI-compatible API works. **Add Provider** offers these templates; keep up to 5 and switch between them from the model menu at the top of the AI panel:

| Template | Base URL | Notes |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | thinking on/off |
| Kimi Code (membership) | `https://api.kimi.com/coding/v1` | international accounts use `api.kimi.ai`; adjustable thinking effort. The membership is meant for coding; if requests are refused (403), use a Kimi Platform key |
| Kimi Platform | `https://api.moonshot.cn/v1` | keeps the cache for an hour by default, so follow-up questions cost less |
| OpenRouter | `https://openrouter.ai/api/v1` | one key for many providers; searchable model menu with prices; prompt caching for Claude models too; optionally only use providers that don't collect your data |
| Other | your own | local servers such as Ollama or LM Studio don't need a key |

- **A model per task**: a strong model for explanations, a cheap one for chores like condensing the study record or finding related decks. Set them in Settings → Model → Models by task; anything you don't set follows the explanation model.
- **Saves tokens**: requests are laid out for the provider's cache, so on follow-up questions the deck is mostly billed at the cache price. The ring at the top of the AI panel shows how much context was used and how much hit the cache.
- **Adapts by itself**: when a model doesn't take images, has a shorter context than expected or rejects a parameter, PPTReader remembers and adjusts; rate limits and temporary errors are retried.

## Lecture recording

Requires macOS 26 or later; the first recording asks for microphone access.

1. **Record**: click the microphone in the toolbar or press ⇧⌘R. A recording bar appears below the slides with the time and level; pause, stop or show live captions from it. Audio is saved in 5-minute segments, so an unexpected quit loses at most the segment being recorded. Recording stops after 3 hours by default, with a reminder 5 minutes before.
2. **Transcribe**: each segment is transcribed on your Mac as soon as it's recorded. Choose the accent (US, UK, Australian and other English, or Mandarin) and the recognizer: Standard, or Dictation, which uses terms from the open deck.
3. **Play back**: in the Lectures window (⌥⌘R, or the button at the bottom left of the sidebar), recordings are grouped by course code and searchable. The transcript follows playback; click any sentence to play from there.
4. **Organize with AI**: one click runs three steps:
   1. decide which decks in the course folder the lecture covered (you confirm the list) and tag the recording with the course code (e.g. ADS205);
   2. correct misheard words using the slides, as a **Corrected** version with every change marked;
   3. list what isn't on the slides (matched to slide pages) and the course arrangements.
5. **See it on the slides**: points matched to a page appear in its margin; click one to jump to that moment of the recording. Export a copy of the PDF with these notes; the original file is never changed.

Every tab (transcript, corrected, supplements, course arrangements) can be exported as text or Markdown. Recording options are in Settings → Lectures: language, recognizer, quality (about 46 or 90 MB for 3 hours), length limit, and the space recordings use.

## Shortcuts

All can be changed in Settings → Shortcuts.

| Action | Shortcut | Action | Shortcut |
|---|---|---|---|
| Explain current page | ⌘E | Open course folder | ⌘O |
| Ask a question | ⌘L | Previous / next page | ⌥⌘↑ / ⌥⌘↓ |
| Stop generating | ⌘. | Zoom in / out / fit | ⌘= / ⌘- / ⌘0 |
| Study roadmap | ⇧⌘M | Show / hide sidebar | ⌃⌘S |
| Statistics | ⇧⌘S | Show / hide AI panel | ⌥⌘0 |
| Start / stop recording | ⇧⌘R | Lectures window | ⌥⌘R |

## Privacy and data

- Course folders are read-only. PPTReader keeps its data in `~/Library/Application Support/PPTReader` (chats, statistics, roadmaps, recordings) and `~/Library/Caches/PPTReader` (conversion and text cache); API keys are in the macOS Keychain.
- When you ask, your provider receives the deck's text, the current page number and screenshot, your selection and recent messages.
- Recordings and transcripts stay on your Mac. Only **Organize with AI** sends the transcript and the text of the decks you check to a model.
- Statistics never leave your Mac; clear them in Settings → Data. Delete recordings in the Lectures window.

## FAQ

**macOS asks for Keychain access after every upgrade.** From 2.0, releases are signed with a fixed certificate: upgrading from 1.9 asks one last time, and later upgrades don't. If you build from source, see signing below.

**Do scanned PDFs work?** Yes. Pages without a text layer are recognized automatically (OCR), with progress shown below the slides.

**The Record menu is grayed out.** Lecture recording uses the system's offline speech recognition, which needs macOS 26 or later.

**How much am I spending?** Statistics shows token usage per day and per task; with OpenRouter it also shows the actual cost.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
./scripts/build-app.sh            # → build/Products.noindex/PPTReader.app
./scripts/build-app.sh --install  # also copy to /Applications
./scripts/test.sh                 # run the tests
```

Builds are ad-hoc signed by default, so every rebuild looks like a new app to macOS and asks again for Keychain and microphone access. Run `./scripts/signing.sh create` once to make a self-signed certificate that later builds use; `./scripts/signing.sh export` backs it up so you can import it on another Mac.

```
Sources/PPTReader/
  App/        entry point, menu commands
  Models/     app state, current deck, chat, roadmap, lecture recording data and organizing
  Services/   model API, prompts, Office conversion, text extraction and OCR, settings, statistics,
              recording, transcription, playback, notes on slides
  Views/      main window, sidebar, reader, AI panel, recording bar, statistics, roadmap and Lectures windows
    Settings/ the Settings window, one file per page
Resources/Web/  answer renderer, figure preview, roadmap, Lectures window (third-party libraries bundled in vendor/)
Tests/          Swift Testing tests
scripts/        build, test, signing, vendor download, icon
```
