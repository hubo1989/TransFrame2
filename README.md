# TransFrame 2

A macOS menu-bar app for screenshots, annotation, text recognition and translation — rebuilt from scratch.
TransFrame 2 is a new app (`com.transframe.v2`) that runs side by side with TransFrame 1.x; it does not import 1.x settings,
keys or history.

**Requirements:** macOS 15 or later (Apple Silicon and Intel). Some features need macOS 26: Apple Translation, structured
document recognition and Apple Foundation Models.

## Features

- **Capture** — region, window (hover to snap, Tab to cycle, Space for free selection), full screen of the display under the
  pointer, and scrolling capture. All displays are frozen at the moment you press the shortcut. Arrow keys nudge the selection
  (Shift = 10 pt, Option = resize), `C` copies the HEX color under the pointer, double-click copies.
- **Annotate** — rectangle, ellipse, line, arrow, freehand, highlight, mosaic, text, numbered labels, privacy redaction and callouts,
  right on the frozen screen or in the editor. Letter keys pick tools; digits 1–9 follow the toolbar order. ⌘ keeps squares,
  circles and 45° lines. 50-step undo.
- **Act on the selection** — `Enter` copies and closes, `⌘S` saves, `P` pins, `T` translates; upload to PicGo, OSS, COS or Kodo;
  beautify with a gradient background; smart mosaic for sensitive content.
- **Recognize and translate** — Apple Vision, PaddleOCR (local or cloud) or a vision model (OpenAI-compatible, Claude, Gemini,
  local). Translate with Apple Translation, MTranServer, OpenAI-compatible engines (up to five instances), Claude, Gemini, Google,
  DeepL or Baidu — in a fallback chain of up to five engines or side by side with 2–4 engines. Show the translation in a drawer or
  drawn on the image (below the original or replacing it).
- **Text translation** — `⌘⇧T` translates the selected text in any app; `⌘⇧Y` translates and inserts it back, verifying the
  target first and falling back to paste with clipboard restore.
- **Editor and pins** — crop (non-destructive), PNG/JPEG/HEIC export, pins with scroll zoom (25–400 %), ⌥-scroll opacity,
  click-through and keep-on-top.
- **History** — searchable translation history with favorites, export to JSON/CSV/Markdown, optional on-device semantic search;
  a separate color history.
- **AI** — structure-preserving recognition (tables, formulas, code), smart actions (copy table as Markdown/CSV, open links,
  add events), glossary with "correct and remember", tone rewrite, content-aware file names. Everything optional.
- **Privacy** — before anything is sent to a cloud engine, sensitive content (keys, card numbers, ID numbers, passwords…) is
  detected on this Mac and masked; your own redactions are always burned in. No telemetry.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture full screen | ⌘⇧3 |
| Capture region | ⌘⇧4 |
| Translate selected text | ⌘⇧T |
| Translate and insert | ⌘⇧Y |
| Region then translate | ⌘⇧I |
| Pick color | ⌃⌘C |

In the editor: `Enter` copies and closes, `⌘S` saves, `C` crops, `P` pins, `Esc` steps back (text → selection → tool → close).

## Permissions

Screen Recording (capture) and Accessibility (text translation, global shortcuts) — the onboarding window guides you through both.

## Build

```sh
brew install xcodegen swiftlint
xcodegen generate
Scripts/build.sh Debug          # build/Products/Debug/TransFrame 2.app
cd Packages/TransFrameKit && swift test
Scripts/check-deps.sh && Scripts/check-l10n.sh && Scripts/check-design.sh
Scripts/perf.sh pipeline        # PerfReports/<date>-<commit>.json
```

Architecture and acceptance criteria: [`SPEC.md`](SPEC.md). Agent notes: [`AGENTS.md`](AGENTS.md).

## License

MIT
