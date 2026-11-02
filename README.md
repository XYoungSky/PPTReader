# PPTReader

A lightweight macOS app for studying course slides with an AI tutor that has read the whole deck.

**English** · [中文](README.zh-CN.md)

## Features

- **Read and ask side by side** — PDF, PowerPoint and Word (PPT/Word are converted by your installed Office; originals are never touched).
- **Context-aware** — every question includes the whole deck's text, the page you're on, your selection and a screenshot of the page.
- **Ways to ask** — explain this page · explain / translate / give examples for a selection · free questions · auto-explain on page turn.
- **Rich answers** — Markdown, LaTeX, code, tables, SVG, Mermaid and inline HTML. Click any diagram to open it in a zoomable preview (pinch / ⌘-scroll, drag to pan) and copy or save it as PNG.
- **Statistics** — reading time, pages read, questions and token usage by day, deck and model (7 days / 30 days / all time), plus a GitHub-style heatmap of the past year. Earlier chats are counted automatically.
- **Custom shortcuts** — rebind every menu command in Settings → Shortcuts.
- **Any OpenAI-compatible API**, tuned for DeepSeek (`deepseek-flash` with vision, `deepseek-v4-pro`, thinking on/off), with support for the Kimi Code membership API (adjustable thinking effort).
- **Multiple providers** — save up to 5 API configurations and switch between them in Settings or from the AI panel's model menu.
- Chinese / English UI, light and dark mode, ~7 MB native app.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools: `xcode-select --install`
- Microsoft PowerPoint / Word — only for `.ppt(x)` / `.doc(x)` files

## Build

For a prebuilt app, download `PPTReader-v1.4-macOS-arm64.zip` from the [v1.4 release](https://github.com/XYoungSky/PPTReader/releases/tag/v1.4), unzip it, and move `PPTReader.app` to Applications. This build requires an Apple Silicon Mac and macOS 14 or later. It uses an ad-hoc signature and is not notarized by Apple; macOS may block the first launch.

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
| API Key | your key (stored per provider in the Keychain) |
| Model | Click **Test connection**, then choose a returned model, or enter a model ID supported by your provider |

The model list combines the API results with your current selection. No model names are preset, and a model must be selected or entered before chatting. With several providers saved, you can also switch from the model menu at the top of the AI panel.

| Template | Base URL | Notes |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | thinking on/off |
| Kimi Code (membership) | `https://api.kimi.com/coding/v1` (international: `https://api.kimi.ai/coding/v1`) | create the key in the Kimi Code console; default model `kimi-for-coding`; adjustable thinking effort |
| Kimi Platform (pay-as-you-go) | `https://api.moonshot.cn/v1` | |
| Other OpenAI-compatible API | your own | |

> Kimi Code membership benefits are meant for coding, and Kimi may only accept requests from coding tools. If requests are refused (HTTP 403), use a Kimi Platform key instead.

Models that reject images are detected automatically; the request is retried without the screenshot.

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
