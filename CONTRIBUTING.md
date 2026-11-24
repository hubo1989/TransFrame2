# Contributing to TransFrame 2

Thanks for helping. This guide covers setup, the rules the codebase enforces, how to test, and how changes get merged and
released. [`SPEC.md`](SPEC.md) is the authoritative specification — read the section for the module you are changing first.

## Setup

- macOS 15 or later, Xcode 26.2 or later, Homebrew.
- `brew install xcodegen swiftlint` (`create-dmg` too if you want to build release disk images locally).

```sh
xcodegen generate                         # after any change to project.yml; commit the regenerated project
Scripts/build.sh Debug                    # build/Products/Debug/TransFrame 2.app (bundle ID com.transframe.v2.dev)
Scripts/dev-sign.sh                       # optional: sign with your Apple Development identity so privacy grants persist
cd Packages/TransFrameKit && swift test   # package tests
```

The app lives in the local Swift package `Packages/TransFrameKit`; `App/` is only the composition root
(`CompositionRoot.swift`), routing (`AppCoordinator`) and resources.

## Architecture rules (enforced)

| Rule | Checked by |
|---|---|
| Module dependencies follow the whitelist in SPEC §01 §2.1 (Domain ← Pipelines ← Infra / UI ← Features ← App). | `Scripts/check-deps.sh` |
| No singletons outside `App/` (`static let shared`), no `UserDefaults.standard`, `DispatchQueue`, `Task.detached`, `print(` or `NotificationCenter.default.post` in the package. | `Scripts/check-deps.sh` |
| The system pasteboard is touched only in `TFSystemInfra`; `@unchecked Sendable` / `nonisolated(unsafe)` need an entry with a reason in `Scripts/unsafe-allowlist.txt`. | `Scripts/check-deps.sh` |
| macOS 26 availability checks only in `TFDesignSystem`, `TFTranslationInfra`, `TFRecognitionInfra`, `TFAIInfra`. | `Scripts/check-deps.sh` |
| UI code uses design tokens (`DS.*`, `.chrome(...)`) — no literal colors, font sizes, corner radii, animation durations or direct material/glass APIs. | `Scripts/check-design.sh` |
| Every string is localized in all ten languages; no orphan or missing keys. | `Scripts/check-l10n.sh` |
| `swiftlint lint --strict` is clean (160-column lines, 600-line files). | CI |

Conventions that are not machine-checked:

- Features see only Domain protocols plus `TFDesignSystem`, `TFLocalization` and `TFWorkspaceUI`; dependencies are injected
  from `CompositionRoot`.
- UI modules use `.defaultIsolation(MainActor.self)`; `TFDomain` and `TFPipelines` treat warnings as errors.
- Every edit to a document is one `EditTransaction` through `SessionManaging` (one undo step per gesture).
- Screen, clipboard, files, pins and thumbnails all render through the single executor (ADR-0006) — never draw an export
  differently from the preview.
- Nothing leaves the Mac without passing the privacy guard; user redactions are always burned in.
- Keep hot paths cheap: the capture overlay and canvas redraw only dirty regions, and nothing heavy runs on the main thread.
- Do not add or remove comments unrelated to your change; comments explain *why*.

## Localization

The catalog is `Packages/TransFrameKit/Sources/TFLocalization/Resources/Localizable.xcstrings`; code uses typed keys
(`l10n[.toolRectangle]`, generated from `"tool.rectangle"`).

```sh
python3 Scripts/l10n.py add some.new.key "English text"   # or merge a JSON file: l10n.py merge strings.json
python3 Scripts/l10n.py missing /tmp/missing.json          # what still needs translating
python3 Scripts/l10n.py merge /tmp/translated.json         # {"key": {"zh-Hans": "…", "de": "…", …}}
python3 Scripts/l10n.py gen                                # regenerate typed keys and the per-language .strings tables
Scripts/check-l10n.sh
```

All ten languages (`en`, `zh-Hans`, `de`, `es`, `fr`, `it`, `ja`, `ko`, `pt`, `ru`) are required before merge. Keys built at
runtime from a prefix (`tool.`, `error.`, `engine.name.`, `color.`, …) are exempt from the orphan check.

## Tests

```sh
cd Packages/TransFrameKit
swift test                                   # everything (~250 tests)
swift test --filter AnnotationEditorTests    # one suite
cd ../.. && Scripts/test.sh package          # tests + 90 % line-coverage gate for TFDomain and TFPipelines
Scripts/test.sh smoke                        # launch smoke (expects TF2_MENU_READY)
Scripts/perf.sh pipeline                     # performance suite → PerfReports/<date>-<commit>.json
```

- Tests use Swift Testing. Fakes live in `TFDomainTestSupport`.
- Tests never touch real preferences or the keychain: use a random `UserDefaults` suite and a random keychain service.
- Behavior changes come with tests. Bug fixes start with a failing test.
- Interactive canvas code can be driven with `Tests/TFWorkspaceUITests/CanvasHarness.swift` (real store, planner and renderer in
  an off-screen window).
- Performance tests record samples only when `TF_PERF_OUT` is set; run them one at a time in release mode, e.g.
  `TF_PERF_OUT=/tmp/perf swift test -c release --filter "AnnotationPerfTests/dragFramesAndCommitLatency"`.

## Before you open a pull request

```sh
Scripts/check-deps.sh && Scripts/check-l10n.sh && Scripts/check-design.sh
swiftlint lint --strict --quiet
Scripts/test.sh package
Scripts/build.sh Debug && Scripts/test.sh smoke
```

For UI changes, also look at the result: run the Debug build, and check both light and dark appearance and the capture overlay.
Manual walkthroughs live in [`Docs/walkthroughs`](Docs/walkthroughs).

## Commits and pull requests

- Branch from `main`; never push to `main` directly. Every change lands through a pull request with green CI and a review.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `feat(capture): …`, `fix(render): …`,
  `perf(canvas): …`, `docs: …`, `chore(release): …`. Explain *why* in the body.
- Keep pull requests focused. Describe what changed, how it affects users, and how you tested it (the template asks for this).
- Public types and API changes stay backward compatible; deprecate before removing.
- Update [`CHANGELOG.md`](CHANGELOG.md) under "Unreleased" for anything a user would notice, and `SPEC.md` when behavior in its
  tables changes.

CI (`.github/workflows/macos-ci.yml`) runs the gates, the package tests with the coverage gate, the app UI test and launch smoke
on macOS 15, a universal Release build, and the package tests plus smoke on Intel.

## Releases

Maintainers release by pushing a tag `v0.*` or `v2.*` on `main`. `.github/workflows/release.yml` then runs the gates, builds a
universal app signed with the Developer ID and Hardened Runtime, packs and notarizes a DMG, signs the Sparkle appcast and
publishes both to GitHub Releases as the latest release (never a pre-release: the app's update feed is
`releases/latest/download/appcast.xml`, which skips pre-releases). Release notes come from the matching section of
`CHANGELOG.md`.

Repository configuration it needs (one-time; `Scripts/setup-release-secrets.sh` sets all of them with the GitHub CLI):

| Name | Kind | Content |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | secret | the "Developer ID Application" certificate exported as .p12 |
| `APPLE_TEAM_ID` | secret | Apple developer team ID |
| `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` | secret | Apple ID and an app-specific password for `notarytool` |
| `SPARKLE_PRIVATE_KEY` | secret | TransFrame 2's Sparkle EdDSA private key |
| `SPARKLE_PUBLIC_KEY` | variable | the matching public key (also in `project.yml`) |

## Reporting bugs and ideas

Use the issue templates. For bugs include the macOS version, the app version (About window), the steps, and what you expected.
Security issues go through [SECURITY.md](SECURITY.md), not public issues.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
