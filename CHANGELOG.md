# Changelog

All notable changes to TransFrame 2.

## Unreleased

- Prefer the top app window under the pointer when a floating system window covers the display.
- Copy the captured image to the clipboard on double-click.

## 0.0.002 — 2026-11-24

- Make the window under the pointer easier to see in region capture and use ScreenCaptureKit when Quartz returns no candidates.
- Double-click to save a capture. Click outside the selected area or press Esc to close it.
- Give a double-click priority over automatic translation or scrolling when the first click selects a window.

## 0.0.1 — 2026-11-24

First preview of the rebuilt app. TransFrame 2 is a separate app (`com.transframe.v2`) that runs next to TransFrame 1.x and does
not migrate 1.x data. Requires macOS 15 or later (Apple Silicon and Intel).

### Capture
- Region, full screen of the display under the pointer, region-then-translate and scrolling capture; all displays freeze at the
  shortcut.
- Window detection: hover highlights the window, click selects it, double-click captures it; Tab cycles, Space frees the
  selection. New setting to turn it off (on by default).

### Annotation
- Eleven tools on the frozen screen and in the editor, letter and digit shortcuts, ⌘ constraints, 50-step undo.
- Hover hints with name, shortcut and a how-to on every toolbar control, including over the capture overlay.
- Inline style bar for the current tool or selection (palette, screen color picker, system colors, line width, text size, mosaic
  strength, fill and fill color, delete). New annotations stay selected; style changes touch only the edited property and one
  slider drag is one undo step.
- Arrow-key nudging, callout pointer handle, resize and move cursors, text editing without a ghost of the old text.
- Beautify draws rounded corners and a shadow inside a transparent margin (a white matte for JPEG).
- Smart mosaic shows a scan, lights up each area it found and reports "pixelated N areas" or "no private information found".

### Recognition and translation
- Apple Vision, PaddleOCR and vision models for recognition; Apple Translation, MTranServer, OpenAI-compatible, Claude, Gemini,
  Google, DeepL and Baidu for translation, as a fallback chain or side by side.
- Translations drawn on the image (below or replacing the original, automatic by default) or listed in the drawer.
- Lines already in the target language are not sent to engines and get no duplicate translation.
- Text translation and translate-and-insert in any app.

### Everything else
- Editor with non-destructive crop, PNG/JPEG/HEIC export, uploads to PicGo, OSS, COS and Kodo, pins, translation and color
  history with export and semantic search.
- Optional AI: structured recognition, smart actions, glossary "correct and remember", tone rewrite, content-aware file names.
- Local privacy guard before any cloud request; no telemetry.
- Interface in ten languages with instant switching; VoiceOver labels; Liquid Glass on macOS 26.

### Performance
- The canvas renders off the main thread into reused IOSurfaces: committing an annotation on a 4K capture no longer blocks the
  main thread for ~22 ms, drag frames redraw only the changed region, and long freehand strokes stay at a constant cost.
