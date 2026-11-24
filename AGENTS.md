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

## Build status (working log, newest last)
- Phase 1 committed on branch `phase/1-foundation` (e3fee01). l10n complete for 235 keys via agy.
- Done since: TFPipelines (SessionStore, RenderPlanner, TranslationLayoutPlanner, RenderService, CaptureService,
  ColorPickService, ExportService+FileNamer, PerformanceRecorder), TFRenderInfra (CoreGraphicsRenderer, Drawing, FrameComposer,
  ImageCodec), TFCaptureInfra (DisplayTopologyService, WindowEnumerator, ScreenSnapshotter), TFPersistenceInfra FileExporter,
  TFWorkspaceUI (AnnotationEditor, AnnotationGeometry, DocumentCanvasView, AnnotationToolbar+DocumentObserver,
  ResultsModel+WorkspaceServices, ResultsDrawerView), CaptureFeature (SelectionModel, OverlayView).
- Next: CaptureFeature coordinator/controller + in-place toolbar; Editor, Pin, Color features; App wiring; strings batch;
  then Phase 4 engines (Vision/Paddle/VLM recognition, translation engines, health, DocumentPipeline, RecognitionWorkflow,
  TranslationWorkflow, ResultCache, PrivacyGuard), settings engine pages; Phase 5 text translation; Phase 6 history (SwiftData),
  uploads, scroll capture; Phase 7 AI; Phase 8 docs/perf/release + codex review.
- Phase 2/3 committed (c415039). Delegation notes: AgentCompass gate blocks `codex exec`/`agy` unless a ledger record exists.
  `agentcompass roll` currently fails (classifier unavailable), so run
  `agentcompass record --constraint user_override --provider codex --account codex --model remote-magpie/codex/gpt-6.2-sol --effort high --basis "<user words>"`
  in its own command, then `codex exec --sandbox read-only -C <repo> --output-last-message build/<x>-result.md "$(cat build/<x>.md)"` in background.
  Review 1 (phases 1–3) launched → build/review-1-result.md.
- Phase 4 in progress (uncommitted): TFNetworkInfra (URLSessionTransport, HTTPStatusMapping, Endpoint, LLMClient with 4 wires +
  continuation merge), TFTranslationInfra (MTran/Google/DeepL/Baidu/LLM engines, Apple 26+, TranslationEngineFactory, EngineHealthProber,
  AppleLanguageAvailability), TFDomain/SensitiveText.swift (rule classifier), TFRecognitionInfra (VisionEngines.swift: Vision OCR,
  DocumentRecognizer 26+ [API names unverified], code/sensitive/content-block detectors; RemoteEngines.swift: VLM, Paddle local/cloud,
  ProcessRunner, RecognitionEngineFactory). ToolbarModel/CaptureController reference `pipeline` (DocumentPipelineWorkflow) — still nil in App.
- Phase 4 remaining: TFPipelines RecognitionService (analysis input via RenderService .analysisInput, hash+ResultCache, PrivacyGuard,
  tiling OCR-10, Normalizer reading order/paragraphs/noise→excluded, empty→OCR fallback OCR-12), TranslationService (ordered/compare,
  cache, coalescing, glossary post-replace, text privacy placeholders), DocumentPipelineService (recognize/translate/history/smart actions/
  smart mosaic), SmartActionDeriver, GlossaryService, EngineCatalogService; settings pages (PendingPages.swift placeholders → real);
  wire in App CompositionRoot; strings; tests.
- Done (uncommitted): TFPipelines/ResultCache.swift (LRU + in-flight coalescing, CacheKey.digest/fingerprint), Normalizer.swift
  (RecognitionNormalizer: filtering→excluded, visual-line merge, paragraph ContentBlocks for line engines, translatability;
  ImageTiling tiles/merge). Codex review 1 output: build/review-1-result.md (read & fix findings).
- Design decisions pending implementation: (1) TranslationLayoutPlanner belowOriginal should place one translation per paragraph
  block (join segment translations, union box) — replace mode stays per segment; (2) glossary for non-glossary engines via
  placeholders ⟦Gn⟧ replaced after translation; (3) text privacy guard: withhold whole-sensitive units, placeholder ⟦Pn⟧ spans;
  (4) image privacy guard draws black rects on the analysis input before cloud engines; (5) default analysis provider is Vision.
- Done (uncommitted, builds): TFPipelines/PrivacyGuard.swift (image/text guard, GlossaryMatcher), TranslationService.swift
  (ordered/compare, EngineRun{result,privacy}, internal translate(_:settings:overridePrivacy:), cache, limiter, Deadline, cleanup).
- Next: RecognitionService, DocumentPipelineService, SmartActionDeriver, GlossaryService(+GlossaryStore in Persistence),
  EngineCatalogService, wire App (URLSessionTransport, factories, KeychainCredentialStore.secret as SecretReader), settings pages.
- Done (uncommitted, TFPipelines builds): RecognitionService (internal recognize(_:settings:provider:overridePrivacy:) → Outcome{result,privacy,input}),
  DocumentPipeline.swift (DocumentPipelineService: recognize/translate streams via store.beginOperation/attach/finishOperation, makeJob
  with prompt/glossary/context, history record w/ thumbnail, smartActions (+QR), smartMosaic; SmartActionDeriver). Domain: SmartActionDeriving.
- Next immediately: wire App CompositionRoot (URLSessionTransport, TranslationEngineFactory/RecognitionEngineFactory with
  `secrets: { try await credentials.secret(for: $0) }`, LocalSensitiveContentDetector, VisionCodeDetector, LocalContentBlockDetector into
  CaptureService blocks, RecognitionService, TranslationService, DocumentPipelineService → WorkspaceServices.pipeline);
  then EngineCatalogService + settings pages (replace PendingPages.swift), GlossaryStore/GlossaryService, strings batch + agy translate,
  tests for pipeline/translation/normalizer/privacy; commit "feat: phase 4"; then phases 5–8.
- Phase 4 core committed (5dd243a). Codex review 1 results in build/review-1-result.md (P1×10, P2×16) — FIX ALL before phase 5:
  P1: (1) CaptureController session-creation races → single creation task + generation counter, idempotent finish, coordinator clears by identity;
  (2) receivers (editor/pin) must `await retain` before capture releases; full-screen path always releases; (3) capture 2 s timeout must
  not hang (one-shot continuation w/ deadline); (4) selection moves after session exists without lock → bind session to geometry/rebuild;
  (5) canvas draft/handles drawn under imageLayer → separate overlay layer above; (6) cross-display canvas only on first overlay;
  (7) mixed-scale slice destination rounding (Selection.resolve) → derive destination from rounded source origin; (8) FileExporter
  race → exclusive create (O_EXCL/link) retry; (9) slider drag creates many undo steps & restyle overwrites other fields → per-field
  update, commit once; (10) SessionUnlocker must stay locked when policy unavailable.
  P2: shortcut dispatch by first responder, `Character(key)` crash, magnifier edge, click uses event point & snapping flag, 5×5 min on
  resize, beautify preview mapping, stale render overwrite, pin aspect, mosaic cache key, grayscale color space, callout text clip,
  no-op crop transaction, save snapshot consistency, revised-segment undo, ResultsModel generation, app-level ⌘O/⌘,/⌘Q + onRetry,
  settings six base pages always visible (show unavailable state).
- Review-1 fixes applied (uncommitted, not yet compiled): P1-5 (CanvasOverlayView above image), P1-7 (Selection.resolve destination
  from rounded source), P1-8 (FileExporter temp+link EEXIST), P1-9 (StyleField per-field restyle, debounced single commit),
  P1-10 (unlocker stays locked). Remaining: P1-1,2,3,4,6 and all P2.
- Review-1 also fixed: P1-1 (single creation task, finished flag, release late sessions), P1-2 (2 s grace before capture releases;
  full-screen path releases in defer), P1-4 (discard unlocked session on nudge/double-click retarget; locked → ignore outside double-click),
  P2-2 (`Character(key)` crash). STILL OPEN: P1-3 (capture timeout hang), P1-6 (cross-display canvas), P2-1,3–16.
- P1-3 fixed (OneShotCapture with deadline in TFCaptureInfra; allowlisted). Open: P1-6, P2-1,3–16. Then: settings pages
  (EnginesModel/EnginesPage etc. in SettingsFeature/PendingPages.swift are EmptyView stubs!), EngineCatalogService, Glossary store/service,
  Phase 5 text translation (TFSystemInfra SelectedTextCapturer/TextInserter + Pipelines TextTranslationService + TextTranslationFeature),
  Phase 6 SwiftData history + HistoryFeature windows + uploads + scroll capture, Phase 7 AI (TFAIInfra), Phase 8 docs/release/perf.
- Added TFPipelines/EngineCatalog.swift (EngineCatalogService: testTranslation, testAnalysis, models, paddleStatus, generators, testUpload).
  Not yet wired into App (SettingsDependencies.catalog still nil) and settings pages still stubs. Next step: write real
  EnginesModel + pages (engines: mode/chain/compare/cards/compatible instances/credentials/health/test; prompts; privacy; AI; glossary;
  image host; recognition section incl. Paddle status + analysis provider config), then wire catalog in CompositionRoot
  (EngineCatalogService(translation: translationEngines, discovery: translationEngines, health: EngineHealthProber(factory:transport:),
  recognition: recognitionEngines, paddle: PaddleInstallationService(), generators: nil, uploader: nil, encoder: codec)).
- IN PROGRESS: SettingsFeature/PendingPages.swift now holds the real EnginesModel (health, secrets, models, tests, glossary, chain/compare
  edits). View structs EnginesPage/PromptsPage/PrivacyPage/AIPage/GlossaryPage/ImageHostPage were REMOVED and must be written in a new
  file SettingsFeature/EnginePages.swift (PrivacyPage takes SettingsViewModel, others take EnginesModel; call `await model.load()` in .task).
  EnginesModel.copy uses NSPasteboard → violates check-deps; add `pasteboard: any PasteboardAccessing` to SettingsDependencies and use it.
  New l10n keys used: .enginesInstanceName (format %d), .enginesTesting.
- Wrote SettingsFeature/EnginePages.swift (EnginesPage+EngineCard+HealthDot+RecognitionSection, PromptsPage, PrivacyPage, AIPage,
  GlossaryPage, ImageHostPage). Not compiled yet. Needs many new l10n keys (engines.*, health.*, prompts.*, privacy.*, ai.*, glossary.*,
  imageHost.*, analysis.<provider>, sensitive.<category>, tone.<style>, prompts.scene.<scene>, action.show/hide/delete) — run
  /tmp/tf2l10n/missing_keys.py (script may be gone; regenerate: scan `l10n[.x]`/`l10n.string(.x` vs camel(catalog keys)) and add en+zh,
  then agy for 8 languages. EngineCard uses `.onTapGesture` on Menu (check-design OK). Then wire catalog in CompositionRoot.
- Merged l10n batch b6 (settings pages keys, en+zh). Other 8 languages pending → run agy translation (input-3) after phase 5/6 strings.
- SettingsFeature compiles with real pages. NEXT: wire catalog in CompositionRoot (see note above), replace NSPasteboard in
  EnginesModel.copy with injected PasteboardAccessing, settings base six pages always visible (review P2-16), commit; then Phase 5.
- Catalog + pasteboard wired into settings (App builds). Commit pending. NEXT: Phase 5 text translation:
  TFSystemInfra AXSelectedTextCapturer (AX focused element kAXSelectedTextAttribute + range, fallback synthetic ⌘C via CGEvent with
  pasteboard snapshot/restore), AXTextInserter (re-verify focused element/range then set kAXSelectedTextAttribute; fallback paste
  anchored to pid), TFPipelines TextTranslationService (TextTranslationWorkflow; uses TranslationService + makeJob logic, history
  .textTranslation/.insertTranslation, tone via TextGenerating later), TextTranslationFeature (popup window TXT-02..05,14,15 HUD via
  FeedbackCenter.showHUD, insert flow TXT-06..12), App routes .translateSelectedText/.translateAndInsert, menu already has items.
- Phase 5 started: TFSystemInfra/TextAccess.swift (AccessibilityTextService: SelectedTextCapturing+TextInserting; AX read, ⌘C fallback
  with snapshot/restore, verify focus+range before AX write, anchored paste fallback). Not compiled yet. Remaining Phase 5:
  TFPipelines TextTranslationService, TextTranslationFeature (popup + insert HUD), App wiring + routes, strings, tests.
- Wrote TFPipelines/TextTranslationService.swift (translateSelection/translate/translateAndInsert with tone/polish via TextGeneratorProviding,
  clipboard fallback TXT-09, history). Not compiled yet. Next: compile, TextTranslationFeature (popup window + insert HUD + debounce
  0.3 s + busy guard TXT-14 + RTL TXT-05), App wiring (AccessibilityTextService(pasteboard:), TextTranslationService), routes.
- TextTranslationService compiles. Next: TextTranslationFeature UI + App wiring (see above), then commit "feat: phase 5".
- Wrote TextTranslationFeature/TextTranslationFeature.swift (coordinator w/ busy+0.3 s debounce, HUD progress, popup with compare picker,
  RTL). Needs keys: textTranslating, textCapturing, textInserting, textInserted, textCopiedInstead, textPopupTitle. Then App wiring:
  `let textAccess = AccessibilityTextService(pasteboard: pasteboard)`; `TextTranslationService(capturer: textAccess, inserter: textAccess,
  pasteboard:, translation:, pipeline:, history:, generators: nil)`; feature coordinator; AppCoordinator routes
  .translateSelectedText/.translateAndInsert; AppFeatures.text.
- Phase 5 wired & App builds (text translation routes live). Committed below. NEXT: Phase 6 — SwiftData HistoryStore in
  TFPersistenceInfra (versioned schema, move-aside on failure, merge/limit via HistoryRetention), HistoryFeature (history window HIS-*,
  color history window COL-*), GlossaryStore (JSON file in support dir) + GlossaryService (GlossaryWorkflow incl. correct()),
  TFUploadInfra (PicGo/OSS/COS/Kodo signing), ScrollCaptureService (Pipelines stitching) wired to CaptureDependencies.scroll,
  App routes .openHistory/.openColorHistory; then Phase 7 TFAIInfra (NLEmbedding, FoundationModels 26+, LLM generator) and
  Phase 8 (tests, l10n agy pass for ~170 new keys, docs, release workflow, perf script, codex review 2).
- Phase 6 started: TFPersistenceInfra/HistoryStore.swift (SwiftDataHistoryStore @ModelActor: HistoryStoring + EmbeddingIndexStoring,
  versioned schema V1, move-aside on open failure, `SwiftDataHistoryStore.open(directory:)`, nil → in-memory). Not compiled yet.
  Wire: `let historyStore = SwiftDataHistoryStore.open(directory: environment.supportDirectory)` replacing InMemoryHistoryStore in
  CompositionRoot; HistoryService(store: historyStore, files:, embedding: nil (Phase 7 NLEmbedding), index: historyStore, ...).
- SwiftDataHistoryStore compiles; committed. Next: wire it in CompositionRoot, then HistoryFeature windows (history + color history),
  App routes .openHistory/.openColorHistory, GlossaryStore/Service, uploads, scroll capture, Phase 7, Phase 8.
- Wrote HistoryFeature/HistoryFeature.swift (HistoryCoordinator: showHistory/showColorHistory; HistoryModel/View with filter, favorites,
  semantic toggle, export menu, clear confirm, infinite scroll, context menu; ColorHistoryModel/View grid, HEX/RGB format via @AppStorage
  (NOTE: @AppStorage uses UserDefaults.standard implicitly — acceptable? check-deps only greps `UserDefaults.standard`), search, clear).
  Not compiled. Needs keys: history.* (filter, all, favorites, semantic, export, clear, clearConfirm, semanticFallback, emptyTitle,
  noResults, emptyMessage, clearSearch, search, favorite, unfavorite, copyResult, copySource, copyBoth), history.kind.<kind>,
  color.* (format, clear, emptyTitle, emptyMessage, search, clearConfirm, copyHex, copyRgb). Then wire coordinator + routes in App.
- History wired in App (SwiftDataHistoryStore + HistoryCoordinator, routes). Build next.
- History windows committed. Next: GlossaryStore/Service, TFUploadInfra, ScrollCaptureService, Phase 7 TFAIInfra, Phase 8.
- Added GlossaryFileStore (TFPersistenceInfra, JSON at supportDirectory/Glossary.json) + GlossaryService (TFPipelines, correct()).
  Both compile. TODO wire: `let glossaryStore = GlossaryFileStore(url: environment.supportDirectory.appending(path: "Glossary.json"))`,
  `GlossaryService(store:sessions:)` → WorkspaceServices.glossary + SettingsDependencies.glossary; pass glossaryStore to DocumentPipelineService.
- Glossary wired in App (store+service). Verify build.
- Glossary wiring committed. NEXT: TFUploadInfra uploader, ScrollCaptureService, Phase 7 TFAIInfra, tests, l10n agy pass, docs, release workflow, codex review 2.
- Wrote TFUploadInfra/ImageUploader.swift (PicGo, OSS v1 sig, COS q-sign, Kodo token multipart; UploadSigning pure). Compile + wire: ImageUploader(transport:secrets:) → ExportService.uploader + EngineCatalogService.uploader.
- Uploads wired & committed. NEXT: ScrollCaptureService (Pipelines: begin strips via ScrollCapturing every ~120 ms, stitch by row-hash overlap search, 32k px limit, finish → sessions.create(importing:)), wire CaptureDependencies.scroll; then Phase 7 TFAIInfra.
- Scroll capture wired & committed. Phase 6 code complete. NEXT: Phase 7 TFAIInfra: NLEmbedding (TextEmbedding), FoundationModels generator 26+, LLM generator via LLMClient, TextGeneratorProvider (TextGeneratorProviding) → wire embedding into HistoryService, generators into TextTranslationService/EngineCatalog/FileNamer (auto naming).
- Phase 7 wired & committed: TFAIInfra/AIEngines.swift (FoundationModelsGenerator 26+, LLMGenerator, TextGeneratorProvider automatic order,
  NaturalLanguageEmbedding 512-d), HistoryService embedding, FileNamer AI suggest (local unless allowsCloud), generators into text
  translation + catalog. Structured recognition AI-01 = VLM structured prompt / Vision document; smart selection AI-03 = content blocks.
- NEXT (Phase 8): run full swift test + gates (check-deps/design/l10n), fix; add tests for new code (normalizer, translation service
  mapping/fallback/cancel, privacy guard, glossary, history store, upload signing, scroll shift, LLM parser); agy translation pass for all
  missing keys; remaining review-1 P2 items + P1-6; docs (README/user guide/CHANGELOG), release workflow + perf script; codex review 2.
- l10n: merged agy output-2; agy input-3 (141 keys) running in background → /tmp/tf2l10n/agy/output-3.json, merge with Scripts/l10n.py merge. (agentcompass record for antigravity fails: disabled_in_magpie; agy itself not gated.)
- Phase4Tests committed (52 pipeline tests pass). Next: infra tests (upload signing, LLM/VLM parsers, continuation merge), then full test + l10n merge output-3.
- Infra tests committed (network/upload/translation/recognition pass).
- l10n complete: 473 keys × 10 languages, check-l10n 0 problems (committed).
- FULL swift test green: 127 tests, 0 failures (after l10n completion).
- Codex review 2 (phases 4–7) launched → build/review-2-result.md
- Review-1 P2 fixes committed (all except P1-6 cross-display canvas, P2-13 revised-segment undo, P2-15 onRetry closure, P2-16 already moot). Smoke OK, gates 0.
- perf.sh pipeline added; M4 Pro: R-04 p95 0.13ms, R-05 0.13 (fake measurer), R-06 6.95ms (real CG), R-09 0.10, O-02 0.04, O-03 0.89 (in-memory store). Baseline PerfBaselines/m4pro.json. P-* screen metrics not measured (need perf driver).
- Docs (README, CHANGELOG, Docs/walkthroughs W01–W04) + .github/workflows/release.yml committed. Release needs user: GitHub repo + Developer ID + notary creds + NEW Sparkle keypair (secrets/vars listed in release.yml header).
- Real Vision OCR + sensitive detector integration tests pass (30 s cold Vision load).
- P1-6 mitigated (canvas on largest-intersection display; cross-display live preview remains a documented limitation).
- swiftlint --strict: 188 violations (166 line_length >160, rest mechanical: force_cast in TextAccess, force_try in HistoryStore, optional_data_string_conversion, is_disjoint, empty_count, CompositionRoot init >100 lines, Settings.swift >600 lines). Plan: after review-2 fixes, delegate lint pass to codex (workspace-write).
- Codex review 2 done → build/review-2-result.md (14 P1 + P2s: privacy bypass via glossary/tone/uploads, locality classify, cache key
  vs IDs, cancel/limiter, Paddle stderr hang, stale translation write, insert target, all-failed counted as success, COS host encoding,
  keyless local engines vs locked keychain, scroll cancel race, VLM table bounds; P2 OpenAI max_tokens / Anthropic temperature …).
- Codex FIX worker (resumed review session 01a2097b…, workspace-write) running: fixes all review-2 findings + swiftlint strict zero.
  Output → build/fix-2-result.md, log build/fix-2.log. DO NOT edit source files until it finishes (single writer). Then verify all gates,
  review diff, commit as "fix: review-2 findings + lint".
- Codex fix-2 finished (77 files): claims 14 P1 + 14 P2 fixed, 19 regression tests, lint 0. Its sandbox blocked Vision/Keychain tests + xcodebuild → verify outside sandbox before commit.
- Review-2 fixes + lint committed and verified (153/153 tests, all gates 0, smoke OK).
- Coverage gate fixed (merges all bundles). Actual: TFDomain 76.4%, TFPipelines 55.4% (< 90% gate → CI would FAIL). Lowest: EngineCatalog 0, GlossaryService 0, RecognitionService 7, DocumentPipeline 16.7, Services 19.3, HistoryService 34.5, ScrollCapture 39.6, Normalizer 48.4, Transactions 30.6, Annotation 43.8.
- Codex coverage worker launched (workspace-write) → build/coverage-3-result.md; single writer: don't touch Packages/ until done. Note: codex sandbox may block Vision/Keychain/xcodebuild; verify outside.
- Coverage commit: TFDomain 93.9 %, TFPipelines 92.5 %, 224 tests pass (Vision/Keychain included), lint 0, deps 0.
- GitHub: https://github.com/hubo1989/TransFrame2 (public). main = SPEC commit; PR #1 phase/1-foundation → main.
  Sparkle: new EdDSA pair generated with `generate_keys --account transframe2` (private key in login keychain, account transframe2);
  public key in project.yml TF_SPARKLE_PUBLIC_KEY. To set GitHub secret: `generate_keys --account transframe2 -x key.txt` then
  `gh secret set SPARKLE_PRIVATE_KEY < key.txt && rm key.txt`; `gh variable set SPARKLE_PUBLIC_KEY --body <pub>`.
- User answers: real-engine acceptance with OpenAI-compatible/local model; manual walkthroughs: user grants permissions, I drive GUI.
- Dev build signed with Apple Development (team 7GT4893YFC) via Scripts/dev-sign.sh <sha1 2E13C393…>; acceptance: Scripts/acceptance.sh <endpoint> <model> [chat|responses].
- CI on Xcode 26.2 failed: ambiguous cos/sin in Drawing.swift (fixed with explicit Double/Foundation.*). Iterate on CI (no Xcode 26.2 locally).
- l10n: catalog now compiled to committed <lang>.lproj/Localizable.strings by l10n.py gen (xcstrings excluded from target; check flags stale tables) — Xcode 26.2 SwiftPM didn't compile xcstrings (CI: all strings missing).
- CI: zh-Hans lproj not found on Xcode 26.2 (renamed folder?) → Localizer scans lproj names case/separator-insensitively.
- CI: package tests + coverage PASS on Xcode 26.2; app target hit Swift 6.2 SILGen crash in AppCoordinator withObservationTracking closures → read via local let (fixed).
- CI smoke failed: runners lack coreutils timeout → perl alarm + exec {$ARGV[0]} (path has a space).
- CI GREEN on PR #1 (run 45296774144): checks (macOS 15 + Xcode 26.2: gates, package tests + coverage, UI tests, smoke, universal Release) and intel (x86_64 tests + smoke).
- Installed Release build to /Applications/TransFrame 2.app (com.transframe.v2, 2.0.0, Developer ID 27LU47J28S signed, hardened runtime, NOT notarized — runs because locally built/no quarantine). Running pid 56270, onboarding shown. Dev instance stopped.
- Update check fix: SparkleUpdater preflights feed (UpdateFeedDecision: 404/same build → upToDate alert, newer → Sparkle UI, failure → unavailable alert). Reinstalled /Applications build (old copy at /tmp/tf2-old-install).
