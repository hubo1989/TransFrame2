# TransFrame 2 — agent notes

`SPEC.md` is the only authoritative specification (architecture freeze). Read the relevant section before changing a module.

## Layout
- `Packages/TransFrameKit` — local Swift package, 25 targets (whitelist in `Scripts/check_deps.py`, SPEC §01 §2.1).
- `App/` — composition root (`CompositionRoot.swift`), `AppCoordinator` (routing), Info.plist, assets.
- `project.yml` → `TransFrame2.xcodeproj` (XcodeGen; regenerate with `xcodegen generate`, commit the result).

## Commands
- Build app: `Scripts/build.sh [Debug|Release]` (explicit SYMROOT/OBJROOT under `build/`).
- Package tests: `cd Packages/TransFrameKit && swift test` (or `Scripts/test.sh package` with coverage gate).
- Launch smoke: `Scripts/test.sh smoke` (expects `TF2_MENU_READY` with `TF_SMOKE_TEST=1`).
- Gates: `Scripts/check-deps.sh`, `Scripts/check-l10n.sh`, `Scripts/check-design.sh` (each has `--self-test`), `swiftlint lint --strict`.
- Localization: catalog `Sources/TFLocalization/Resources/Localizable.xcstrings`; `python3 Scripts/l10n.py add|merge|missing|gen|check`.
  After adding keys run `python3 Scripts/l10n.py gen` (typed keys in `L10nKeys.generated.swift`, `"a.b.c"` → `.aBC`).
  Keys with dynamic prefixes (`error.`, `engine.name.`, `settings.page.`, `hotkey.`, `color.`, …) are exempt from the orphan check.

## Conventions
- No singletons outside `App/`; Features only see Domain protocols, `TFDesignSystem`, `TFLocalization`, `TFWorkspaceUI`.
- UI modules use `.defaultIsolation(MainActor.self)`; TFDomain/TFPipelines treat warnings as errors.
- macOS 26 availability checks only in TFDesignSystem, TFTranslationInfra, TFRecognitionInfra, TFAIInfra.
- Domain shortcut type is `GlobalShortcut` (avoids clash with SwiftUI.KeyboardShortcut).
- Tests never touch real preferences/keychain: random `UserDefaults` suite, random keychain service, fakes in `TFDomainTestSupport`.
- BSD `sed` has no `\b`; use `perl -pi -e` for word-boundary replacements.
- Translations of new keys: export with `l10n.py missing`, delegate de/es/fr/it/ja/ko/pt/ru to `agy -p ... --model gemini-4-hydrogen-high`
  (prompt template in git history / `/tmp/tf2l10n/agy/PROMPT.md`), then `l10n.py merge` and `l10n.py check`.
