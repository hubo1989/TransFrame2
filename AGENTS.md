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
