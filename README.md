# TransFrame 2

**Screenshot, annotate, recognize and translate — in one keystroke, on macOS.**

TransFrame 2 is a menu-bar app that freezes your screen the moment you press the shortcut, lets you select, mark up and
redact right on the frozen pixels, and recognizes or translates the text in place. It is a ground-up rebuild of TransFrame 1.x
and installs as a separate app (`com.transframe.v2`) that runs side by side with 1.x; it does not import 1.x settings, keys or
history.

[简体中文](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

> **Status: 0.0.1 preview.** Feature-complete against the 1.x parity list in [`SPEC.md`](SPEC.md), but young. Please report what
> breaks.

## Requirements

- macOS 15 Sequoia or later, Apple Silicon or Intel (universal build).
- macOS 26 adds Apple Translation, structured document recognition and Apple Foundation Models; everything else works on 15.
- Permissions: **Screen Recording** (capture) and **Accessibility** (text translation and global shortcuts). The first-run guide
  walks you through both.

## Install

1. Download `TransFrame-2-<version>.dmg` from [Releases](https://github.com/hubo1989/TransFrame2/releases).
2. Open it and drag **TransFrame 2** into **Applications**.
3. Start it from Applications. A menu-bar icon appears and the guide asks for the two permissions.

Builds are signed with a Developer ID and notarized. Updates arrive through Sparkle (menu bar › About › Check for Updates).

## What it does

### Capture
- **Region** (⌘⇧4), **full screen of the display under the pointer** (⌘⇧3), **region then translate** (⌘⇧T) and **scrolling
  capture**. Every display freezes at the shortcut, so videos and menus hold still.
- **Window detection** — the window under the pointer is highlighted; click to select it, double-click to capture it at once.
  Tab cycles overlapping windows, Space switches to a free selection. Can be turned off in Settings › General › Capture.
- Arrow keys move the selection (Shift = 10 pt, Option resizes), `C` copies the HEX color under the pointer, `Enter` or ⌘C copies
  and closes, ⌘S saves, `P` pins, `T` translates, `Esc` steps back.

### Annotate
- Eleven tools: rectangle, ellipse, line, arrow, freehand, highlight, mosaic, text, numbered labels, privacy redaction and callouts —
  directly on the frozen screen or in the editor. Letter keys pick tools, digits 1–9 follow the toolbar order, ⌘ keeps squares,
  circles and 45° lines.
- **Every button explains itself**: hover for its name, shortcut and a one-line how-to — also over the full-screen capture overlay.
- **Style bar** for the current tool or selection: palette, screen color picker, system colors, line width, text size, mosaic
  strength, fill and fill color. A new annotation stays selected, so you can adjust it straight away; changing a style touches only
  that property, and one slider drag is one undo step.
- Move, resize and re-aim (callout pointers too), nudge with the arrow keys, delete with ⌫, 50-step undo.
- **Beautify** frames the image with rounded corners and a soft shadow inside a transparent margin.
- **Smart mosaic** scans the image on this Mac, lights up what it found, pixelates it in one undoable step and tells you how many
  areas it covered — or that nothing private was found.

### Recognize and translate
- Recognition with Apple Vision, PaddleOCR (local or cloud) or a vision model (OpenAI-compatible, Claude, Gemini or local).
- Translation with Apple Translation, MTranServer, OpenAI-compatible engines (several instances), Claude, Gemini, Google, DeepL
  or Baidu — as a fallback chain of up to five engines, or 2–4 engines side by side without re-translating.
- Results in a drawer next to the selection, or drawn on the image below or in place of the original (automatic by default).
- Lines already in the target language are left alone: they are not sent to any engine and no duplicate "translation" is drawn.

### Text anywhere
- ⌘⇧Y translates the selected text in any app; ⌘⇧I translates it and writes it back, verifying the target first and falling back to
  paste with the clipboard restored.

### Editor, pins and history
- Non-destructive crop, PNG / JPEG / HEIC export, upload to PicGo, Aliyun OSS, Tencent COS or Qiniu Kodo.
- Pins float above other windows with scroll zoom (25–400 %), ⌥-scroll opacity, click-through and keep-on-top.
- Searchable translation history with favorites, JSON / CSV / Markdown export and optional on-device semantic search; a separate
  color history (⌃⌘C picks a color anywhere).

### AI, optional
- Structure-preserving recognition (tables, formulas, code), smart actions (copy a table as Markdown/CSV, open links, add events),
  glossary with "correct and remember", tone rewrite and content-aware file names — on-device with Foundation Models where
  available.

### Privacy
- Before anything goes to a cloud engine, sensitive content (keys, card and ID numbers, passwords, …) is detected on this Mac and
  masked. Your own redactions are always burned in. No telemetry, no accounts.

### Interface
- Ten languages (English, 简体中文, Deutsch, Español, Français, Italiano, 日本語, 한국어, Português, Русский), switchable instantly.
  Light and dark appearance, Liquid Glass on macOS 26, VoiceOver labels throughout.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture region | ⌘⇧4 |
| Capture full screen (display under the pointer) | ⌘⇧3 |
| Region, then translate | ⌘⇧T |
| Translate selected text | ⌘⇧Y |
| Translate and insert | ⌘⇧I |
| Pick a color | ⌃⌘C |

All of them can be changed in Settings › Shortcuts. If TransFrame 1.x or macOS already uses a shortcut, the app tells you and
offers to change it.

| While capturing or editing | |
|---|---|
| Copy and close | `Enter`, ⌘C |
| Save | ⌘S |
| Pin | `P` |
| Translate (capture) / crop (editor) | `T` / `C` |
| Tools | `R O L A D H M T N X B`, `1`–`9` |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Step back (text → selection → tool → close) | `Esc` |

## Build from source

You need Xcode 26.2 or later and Homebrew.

```sh
brew install xcodegen swiftlint
git clone git@github.com:hubo1989/TransFrame2.git && cd TransFrame2
xcodegen generate                      # TransFrame2.xcodeproj (committed; regenerate after editing project.yml)
Scripts/build.sh Debug                 # → build/Products/Debug/TransFrame 2.app
open "build/Products/Debug/TransFrame 2.app"
```

Debug builds use the bundle ID `com.transframe.v2.dev`, so they never touch an installed release. To keep macOS privacy
permissions across rebuilds, sign the Debug build with your Apple Development identity: `Scripts/dev-sign.sh`.

Tests and quality gates are described in [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

```
App/                     composition root, routing, Info.plist, assets
Packages/TransFrameKit/  the app as a local Swift package (25 targets)
  TFDomain               models, protocols, errors — no framework dependencies
  TFPipelines            sessions, rendering plans, recognition / translation / export workflows
  TF*Infra               adapters: capture, recognition, translation, AI, rendering, persistence, system, network, upload
  TFDesignSystem         tokens, controls, hover hints, toasts
  TFWorkspaceUI          canvas, annotation editor and toolbars, results drawer
  *Feature               capture, editor, pins, text translation, history, settings, onboarding, menu bar, about, color
AppUITests/              launch smoke
Scripts/                 build, tests, gates, localization, performance, signing
Docs/                    parity status and manual walkthroughs
SPEC.md                  the architecture and acceptance specification (authoritative)
```

## License

[MIT](LICENSE)
