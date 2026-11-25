# PPTReader

A lightweight macOS app for studying course slides with an AI tutor that has read the whole deck.

**English** · [中文](README.zh-CN.md)

## Features

- **Read and ask side by side** — PDF, PowerPoint and Word (PPT/Word are converted by your installed Office; originals are never touched).
- **Context-aware** — every question includes the whole deck's text, the page you're on, your selection and a screenshot of the page.
- **Ways to ask** — explain this page · explain / translate / give examples for a selection · free questions · auto-explain on page turn.
- **Box selection** — Shift-drag to draw a box around a figure, formula or any part of a slide, then explain, translate or ask about it: a sharp screenshot of the box (rendered from the PDF) and its text are sent together. Make boxing the default drag in Settings → Tutor; the question's bubble shows a thumbnail that jumps back to the page.
- **Rich answers** — Markdown, LaTeX, code, tables, SVG, Mermaid and inline HTML. Click any diagram to open it in a zoomable preview (pinch / ⌘-scroll, drag to pan) and copy or save it as PNG. Move the preview by its top edge or by ⌥-dragging anywhere, and make it translucent to compare it with the slides.
- **Explanation style** — choose how long answers are and how many diagrams and worked examples they include, and add your own instructions (e.g. "write out full derivations"). Open it from the AI panel's More menu.
- **Statistics** — reading time, pages read, questions and token usage by day, deck, course and model (7 days / 30 days / all time), plus a GitHub-style heatmap of the past year. Each deck shows the course folder it belongs to; earlier chats are counted automatically.
- **Cache-friendly requests** — a fixed system prompt (deck-independent instructions first, the deck last), append-only history and block-wise trimming with stable boundaries keep the provider's prefix cache hitting across a conversation, while text is still being OCR'd and when you page through a long deck.
- **Study notes and study record** — write *About me* (applies to every deck) and *Course notes* (per course folder) under Settings → Study notes; both go into the system prompt. When a chat outgrows the context limit, the earlier messages are condensed into a study record instead of being dropped, so the tutor still knows what was covered, where you got stuck and which examples it used. The course folder itself is never modified.
- **Context meter** — the ring at the top of the AI panel shows how much of the context window the last request used. Click it for a breakdown (instructions, notes, deck, study record, history, question, screenshot), the cache hit rate and cache writes, and a warning when the provider's cache has probably expired.
- **Custom shortcuts** — rebind every menu command in Settings → Shortcuts.
- **Any OpenAI-compatible API**, tuned for DeepSeek (`deepseek-flash` with vision, `deepseek-v4-pro`, thinking on/off), with support for the Kimi Code membership API (adjustable thinking effort) and OpenRouter (many providers with one key, adjustable thinking effort).
- **Multiple providers** — save up to 5 API configurations and switch between them in Settings or from the AI panel's model menu. With long model lists (such as OpenRouter's), just type in the model menu to search; recently used models come first.
- Chinese / English UI, light and dark mode, ~7 MB native app.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools: `xcode-select --install`
- Microsoft PowerPoint / Word — only for `.ppt(x)` / `.doc(x)` files

## Build

For a prebuilt app, download `PPTReader-v1.8-macOS-arm64.zip` from the [v1.8 release](https://github.com/XYoungSky/PPTReader/releases/tag/v1.8), unzip it, and move `PPTReader.app` to Applications. This build requires an Apple Silicon Mac and macOS 14 or later. It uses an ad-hoc signature and is not notarized by Apple; macOS may block the first launch.

To build from source:

```bash
./scripts/build-app.sh            # → build/Products.noindex/PPTReader.app
./scripts/build-app.sh --install  # also copy to /Applications
```

## Setup

Open **Settings** (⌘,) → **Model**. Use **Add Provider** to create one from a template (up to 5), and click a provider in the list to switch to it. The fields below edit the provider in use:

| Field | Value |
|---|---|
| Name | any label |
| Base URL | e.g. `https://api.deepseek.com` |
| API type | set from the template or recognised URL; decides whether DeepSeek thinking or Kimi Code / OpenRouter effort is sent. Pick it yourself when going through a proxy |
| API Key | your key (stored per provider in the Keychain); optional for local servers such as Ollama or LM Studio |
| Model | Click **Test connection**, then choose a returned model, or enter a model ID supported by your provider |
| Context window | taken from the API when it reports one, otherwise 128K is assumed; you can also pick it to match the provider's model docs |

The model list combines the API results with your current selection. No model names are preset, and a model must be selected or entered before chatting. With several providers saved, you can also switch from the model menu at the top of the AI panel.

For the Kimi Platform, **Keep cache for 1 hour** (on by default) asks Kimi to keep the prompt cache for an hour instead of five minutes; the first write costs more, but questions within the hour hit the cache.

**Settings → Tutor → Context limit** is a slider for the largest share of the model's context window a request may use (20%–90%, default 80%); the rest is left for the answer. When the deck or chat is too long, the pages around the current one and the latest messages are kept.

| Template | Base URL | Notes |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | thinking on/off |
| Kimi Code (membership) | `https://api.kimi.com/coding/v1` (international: `https://api.kimi.ai/coding/v1`) | create the key in the Kimi Code console; default model `kimi-for-coding`; adjustable thinking effort |
| Kimi Platform (pay-as-you-go) | `https://api.moonshot.cn/v1` | |
| OpenRouter | `https://openrouter.ai/api/v1` | create the key at openrouter.ai/settings/keys; model names carry a provider prefix (e.g. `anthropic/…`); adjustable thinking effort; requests for the same deck go to the same upstream provider so the cache keeps hitting |
| Other OpenAI-compatible API | your own | |

> Kimi Code membership benefits are meant for coding, and Kimi may only accept requests from coding tools. If requests are refused (HTTP 403), use a Kimi Platform key instead.

When a request is refused, PPTReader works out why and retries: models that reject images get no more screenshots, a context-length error records the real limit, and an out-of-range `max_tokens` or an unsupported option is remembered and left out. Rate limits, temporary server errors and dropped connections are retried automatically before any output arrives. What was detected is shown under **Settings → Model → Detected limits**, where it can be reset.

## Shortcuts

Defaults below; change them in **Settings → Shortcuts** (click a shortcut and press the new keys; ⌫ clears it, esc cancels).

| Action | Shortcut |
|---|---|
| Open course folder | ⌘O |
| Explain current page | ⌘E |
| Ask a question (focus the input) | ⌘L |
| Previous / next page | ⌥⌘↑ / ⌥⌘↓ |
| Zoom in / out / fit | ⌘= / ⌘- / ⌘0 |
| Stop generating | ⌘. |
| Toggle sidebar / AI panel | ⌃⌘S / ⌥⌘0 |
| Statistics | ⇧⌘S |
| Settings | ⌘, |

Summarize, concept map, quiz, auto-explain, deep thinking and continuous scrolling have no default shortcut and can be assigned one.

Select text in a slide to get a toolbar (Explain · Translate · Examples · Ask). Click "page N" in an answer to jump there.

## Privacy

- Course folders are read-only.
- Sent to your API provider: the deck's text, the current page number and screenshot, your selection and recent messages.
- API key: macOS Keychain · Chats and statistics: `~/Library/Application Support/PPTReader` · Cache: `~/Library/Caches/PPTReader`
- Statistics never leave your Mac; clear them in Settings → Data.

## Project layout

```
Sources/PPTReader/
  App/        entry point, menu commands
  Models/     app state, current document, chat logic
  Services/   API client, prompts, Office conversion, text extraction / OCR, settings, shortcuts, statistics, localization
  Views/      window layout, sidebar, reader, AI panel, menus, settings, statistics, figure preview
Resources/Web/  answer renderer and figure preview (markdown-it, KaTeX, highlight.js, DOMPurify, Mermaid — bundled offline)
scripts/        build-app.sh · fetch-vendor.sh · make-icon.swift
```
