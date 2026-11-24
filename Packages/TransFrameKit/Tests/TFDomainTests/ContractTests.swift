import CoreGraphics
import Foundation
import Testing
@testable import TFDomain
import TFDomainTestSupport

@Suite("Coordinates")
struct CoordinateTests {
    /// Fixed example from SPEC §06 §4.1: primary 900 pt tall, secondary 1080 pt at Cocoa y=0;
    /// a selection at secondary-local Cocoa y=100, height 200 has its local top at 780.
    @Test func secondaryDisplayExample() {
        let primaryHeight = 900.0
        let secondaryCocoa = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let selectionCocoa = CGRect(x: 1540, y: 100, width: 300, height: 200)
        let secondary = QuartzConversion.quartzRect(fromCocoa: secondaryCocoa, primaryHeight: primaryHeight)
        let selection = QuartzConversion.quartzRect(fromCocoa: selectionCocoa, primaryHeight: primaryHeight)
        #expect(secondary.minY == -180)
        #expect(selection.minY == 600)
        #expect(selection.minY - secondary.minY == 780)
        let back = QuartzConversion.cocoaRect(fromQuartz: selection, primaryHeight: primaryHeight)
        #expect(back == selectionCocoa)
    }

    @Test(arguments: [1.0, 1.5, 2.0, 3.0])
    func pointsToPixelsRoundsOutward(scale: Double) {
        let rect = QuartzRect(x: 10.3, y: 4.6, width: 20.2, height: 7.1)
        let px = rect.scaledOutward(by: scale, to: FramePixel.self)
        #expect(px.minX == (10.3 * scale).rounded(.down))
        #expect(px.minY == (4.6 * scale).rounded(.down))
        #expect(px.maxX == ((10.3 + 20.2) * scale).rounded(.up))
        #expect(px.maxY == ((4.6 + 7.1) * scale).rounded(.up))
    }

    @Test func spaceRectCodableRoundTrip() throws {
        let rect = DocumentRect(x: 1.5, y: 2, width: 3, height: 4.25)
        let data = try JSONEncoder().encode(rect)
        #expect(try JSONDecoder().decode(DocumentRect.self, from: data) == rect)
    }

    @Test func topologyFindsDisplayForPointAndNearestFallback() {
        let a = TestImages.display(1, x: 0, y: 0, width: 1440, height: 900)
        let b = TestImages.display(2, x: 1440, y: -180, width: 1920, height: 1080, scale: 1)
        let topology = DisplayTopology(version: 1, displays: [a, b], primary: a.id)
        #expect(topology.display(containing: QuartzPoint(x: 2000, y: 0))?.id == b.id)
        #expect(topology.display(containing: QuartzPoint(x: 100, y: 100))?.id == a.id)
        #expect(topology.display(containing: QuartzPoint(x: 100, y: 5000))?.id == a.id)
    }
}

@Suite("Selection resolve")
struct SelectionResolveTests {
    let primary = TestImages.display(1, x: 0, y: 0, width: 100, height: 80, scale: 2)
    let secondary = TestImages.display(2, x: 100, y: -20, width: 120, height: 100, scale: 1)

    @Test func singleDisplay() throws {
        let frames = TestImages.frozen([primary])
        let geometry = SelectionGeometry(rect: QuartzRect(x: 10, y: 10, width: 20, height: 30), source: .freeform, topologyVersion: 1)
        let resolved = try geometry.resolve(in: frames)
        #expect(resolved.outputScale == 2)
        #expect(resolved.outputSize == PixelSize(width: 40, height: 60))
        #expect(resolved.slices.count == 1)
        #expect(resolved.slices[0].pixels == FrameRect(x: 20, y: 20, width: 40, height: 60))
        #expect(resolved.slices[0].destination == CanvasRect(x: 0, y: 0, width: 40, height: 60))
    }

    @Test func crossDisplayUsesHighestScaleAndNegativeOrigin() throws {
        let frames = TestImages.frozen([primary, secondary])
        let geometry = SelectionGeometry(rect: QuartzRect(x: 90, y: -10, width: 20, height: 40), source: .freeform, topologyVersion: 1)
        let resolved = try geometry.resolve(in: frames)
        #expect(resolved.outputScale == 2)
        #expect(resolved.outputSize == PixelSize(width: 40, height: 80))
        let bySlice = Dictionary(uniqueKeysWithValues: resolved.slices.map { ($0.display, $0) })
        // Primary covers x 90..100, y 0..30 (the part above y=0 is outside the primary).
        #expect(bySlice[primary.id]?.local == DisplayLocalRect(x: 90, y: 0, width: 10, height: 30))
        #expect(bySlice[primary.id]?.destination == CanvasRect(x: 0, y: 20, width: 20, height: 60))
        // Secondary (origin y=-20) covers x 100..110, y -10..30 → local y 10..50 at scale 1.
        #expect(bySlice[secondary.id]?.pixels == FrameRect(x: 0, y: 10, width: 10, height: 40))
        #expect(bySlice[secondary.id]?.destination == CanvasRect(x: 20, y: 0, width: 20, height: 80))
    }

    @Test func errors() {
        let frames = TestImages.frozen([primary])
        #expect(throws: AppError.capture(.selectionTooSmall)) {
            try SelectionGeometry(rect: QuartzRect(x: 0, y: 0, width: 4, height: 50), source: .freeform, topologyVersion: 1).resolve(in: frames)
        }
        #expect(throws: AppError.capture(.selectionOutOfBounds)) {
            try SelectionGeometry(rect: QuartzRect(x: 500, y: 500, width: 50, height: 50), source: .freeform, topologyVersion: 1).resolve(in: frames)
        }
        #expect(throws: AppError.capture(.topologyChanged)) {
            try SelectionGeometry(rect: QuartzRect(x: 0, y: 0, width: 50, height: 50), source: .freeform, topologyVersion: 2).resolve(in: frames)
        }
    }

    @Test func outputTooLarge() {
        let big = DisplayDescriptor(
            id: DisplayID(9), localizedName: "Huge", frame: QuartzRect(x: 0, y: 0, width: 15_000, height: 15_000),
            pixelSize: PixelSize(width: 15_000, height: 15_000), scale: 1
        )
        let frames = FrozenFrameSet(
            request: CaptureRequest(intent: .region, trigger: .programmatic, pointer: QuartzPoint(x: 0, y: 0)),
            topology: DisplayTopology(version: 1, displays: [big], primary: big.id),
            frames: [CapturedFrame(display: big, image: TestImages.virtual(width: 15_000, height: 15_000), requestedAt: .now, completedAt: .now)],
            windows: []
        )
        #expect(throws: AppError.capture(.outputTooLarge)) {
            try SelectionGeometry(rect: QuartzRect(x: 0, y: 0, width: 15_000, height: 15_000), source: .freeform, topologyVersion: 1)
                .resolve(in: frames)
        }
        #expect(throws: Never.self) {
            try SelectionGeometry(rect: QuartzRect(x: 0, y: 0, width: 10_000, height: 10_000), source: .freeform, topologyVersion: 1)
                .resolve(in: frames)
        }
    }

    @Test func resolveIsPure() throws {
        let frames = TestImages.frozen([primary, secondary])
        let geometry = SelectionGeometry(rect: QuartzRect(x: 50, y: 0, width: 100, height: 60), source: .freeform, topologyVersion: 1)
        #expect(try geometry.resolve(in: frames) == geometry.resolve(in: frames))
    }
}

@Suite("AppError")
struct AppErrorTests {
    @Test func everyLeafHasUniqueMessageKeys() {
        let keys = AppError.allLeafSamples.map(\.userMessage.titleKey)
        #expect(Set(keys).count == keys.count)
        #expect(AppError.allLeafSamples.allSatisfy { $0.userMessage.suggestionKey.hasSuffix(".suggestion") })
    }

    @Test func cancellationIsSilent() {
        #expect(AppError.cancelled.userMessage.presentation == .silent)
        #expect(AppError.from(CancellationError()) == .cancelled)
    }

    @Test func retryability() {
        #expect(AppError.engine(.timedOut(.mtran)).isRetryable)
        #expect(AppError.engine(.rateLimited(.mtran, retryAfter: .seconds(1))).isRetryable)
        #expect(!AppError.engine(.authenticationFailed(.mtran)).isRetryable)
        #expect(!AppError.engine(.notConfigured(.mtran)).isRetryable)
    }

    @Test func permissionErrorsOfferSystemSettings() {
        #expect(AppError.permission(.screenRecordingDenied).userMessage.recovery == .openSystemSettings(.screenRecording))
        #expect(AppError.permission(.accessibilityDenied).userMessage.recovery == .openSystemSettings(.accessibility))
    }
}

@Suite("Settings segments")
struct SettingsCodableTests {
    @Test func defaultsRoundTrip() throws {
        let snapshot = SettingsSnapshot()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(GeneralSettings.self, from: encoder.encode(snapshot.general)) == snapshot.general)
        #expect(try decoder.decode(ExportSettings.self, from: encoder.encode(snapshot.export)) == snapshot.export)
        #expect(try decoder.decode(ShortcutSettings.self, from: encoder.encode(snapshot.shortcuts)) == snapshot.shortcuts)
        #expect(try decoder.decode(AnnotationDefaults.self, from: encoder.encode(snapshot.annotationDefaults)) == snapshot.annotationDefaults)
        #expect(try decoder.decode(LanguageSettings.self, from: encoder.encode(snapshot.languages)) == snapshot.languages)
        #expect(try decoder.decode(RecognitionSettings.self, from: encoder.encode(snapshot.recognition)) == snapshot.recognition)
        #expect(try decoder.decode(EngineSettings.self, from: encoder.encode(snapshot.engines)) == snapshot.engines)
        #expect(try decoder.decode(PromptSettings.self, from: encoder.encode(snapshot.prompts)) == snapshot.prompts)
        #expect(try decoder.decode(PresentationSettings.self, from: encoder.encode(snapshot.presentation)) == snapshot.presentation)
        #expect(try decoder.decode(PrivacySettings.self, from: encoder.encode(snapshot.privacy)) == snapshot.privacy)
        #expect(try decoder.decode(AISettings.self, from: encoder.encode(snapshot.ai)) == snapshot.ai)
        #expect(try decoder.decode(HistorySettings.self, from: encoder.encode(snapshot.history)) == snapshot.history)
        #expect(try decoder.decode(ImageHostSettings.self, from: encoder.encode(snapshot.imageHost)) == snapshot.imageHost)
        #expect(try decoder.decode(OnboardingSettings.self, from: encoder.encode(snapshot.onboarding)) == snapshot.onboarding)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let empty = Data("{}".utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(GeneralSettings.self, from: empty) == GeneralSettings())
        #expect(try decoder.decode(ShortcutSettings.self, from: empty) == ShortcutSettings())
        #expect(try decoder.decode(EngineSettings.self, from: empty) == EngineSettings())
        #expect(try decoder.decode(HistorySettings.self, from: empty).limit == 500)
        #expect(try decoder.decode(PrivacySettings.self, from: empty).redactedCategories == SensitiveCategory.defaultRedacted)
    }

    @Test func customValuesRoundTrip() throws {
        var engines = EngineSettings()
        engines.mode = .compare
        engines.compareGroup = [.deepl, .google, .baidu]
        engines.builtins[.deepl] = EngineConfig(endpoint: "https://api.deepl.com/v2", options: ["plan": "pro"])
        engines.compatibleInstances = [CompatibleInstance(name: "Local")]
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(engines))
        #expect(decoded == engines)
        #expect(decoded.routing == .compare([.deepl, .google, .baidu]))

        var prompts = PromptSettings()
        prompts.custom[PromptKey(engine: .claude, scene: .screenshot)] = "T {text}"
        #expect(try JSONDecoder().decode(PromptSettings.self, from: JSONEncoder().encode(prompts)) == prompts)
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func defaultsMatch1x() {
        let s = ShortcutSettings()
        #expect(s[.fullScreen].displayString == "⇧⌘3")
        #expect(s[.selection].displayString == "⇧⌘4")
        #expect(s[.translationMode].displayString == "⇧⌘T")
        #expect(s[.textSelectionTranslation].displayString == "⇧⌘Y")
        #expect(s[.translateAndInsert].displayString == "⇧⌘I")
        #expect(s[.pickColor].displayString == "⌃⌘C")
    }

    @Test func validation() {
        let s = ShortcutSettings()
        #expect(ShortcutValidation.validate(HotkeyAction.selection.defaultShortcut, for: .fullScreen, in: s) == .conflict(.selection))
        #expect(ShortcutValidation.validate(GlobalShortcut(keyCode: 0x00, modifiers: [.shift]), for: .fullScreen, in: s) == .missingModifier)
        #expect(ShortcutValidation.validate(GlobalShortcut(keyCode: 0x00, modifiers: [.option, .command]), for: .fullScreen, in: s) == .ok)
    }

    @Test func routes() {
        #expect(HotkeyAction.translationMode.route == .capture(.regionThenTranslate))
        #expect(HotkeyAction.pickColor.route == .pickColor)
    }
}

@Suite("Engines and languages")
struct EngineTests {
    @Test(arguments: [
        ("localhost", EngineLocality.onDevice), ("127.0.0.1", .onDevice), ("::1", .onDevice), ("[::1]", .onDevice),
        ("192.168.1.4", .localNetwork), ("10.0.0.2", .localNetwork), ("172.20.1.1", .localNetwork), ("nas.local", .localNetwork),
        ("172.40.1.1", .cloud), ("api.openai.com", .cloud),
    ])
    func locality(host: String, expected: EngineLocality) {
        #expect(EngineLocality.classify(host: host) == expected)
    }

    @Test func compatibleIDs() {
        let uuid = UUID()
        let id = EngineID.compatible(uuid)
        #expect(id.compatibleInstanceID == uuid)
        #expect(EngineID.deepl.compatibleInstanceID == nil)
    }

    @Test func routingValidity() {
        #expect(EngineRouting.ordered([.deepl]).isValid)
        #expect(!EngineRouting.ordered([]).isValid)
        #expect(!EngineRouting.ordered(Array(repeating: .deepl, count: 2)).isValid)
        #expect(!EngineRouting.compare([.deepl]).isValid)
        #expect(EngineRouting.compare([.deepl, .google, .baidu, .mtran]).isValid)
        #expect(!EngineRouting.compare([.deepl, .google, .baidu, .mtran, .claude]).isValid)
    }

    @Test func languagesAndTargets() {
        #expect(TranslationLanguages.all.count == 29)
        #expect(TargetLanguage.followSystem.resolved(preferred: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(TargetLanguage.followSystem.resolved(preferred: ["xx"]) == .english)
        #expect(LanguageCode("zh-Hant").isSameLanguage(as: LanguageCode("zh-Hans")) == false)
        #expect(LanguageCode("en-US").isSameLanguage(as: .english))
    }

    @Test func colors() {
        #expect(RGBA(hex: "#ff8000")?.hexString == "#FF8000")
        #expect(RGBA(hex: "abc")?.hexString == "#AABBCC")
        #expect(RGBA(hex: "zz") == nil)
        #expect(RGBA.contrastRatio(.black, .white) > 20)
    }
}

@Suite("Structure")
struct StructureTests {
    @Test func consistentTreePasses() {
        let s1 = SegmentID(), s2 = SegmentID()
        let cell = BlockID(), table = BlockID()
        let segments = [
            TextSegment(id: s1, text: "a", box: .zero, parent: table),
            TextSegment(id: s2, text: "b", box: .zero, parent: cell),
        ]
        let blocks = [
            ContentBlock(id: table, kind: .table(rows: 1, columns: 2), box: .zero, children: [.segment(s1), .block(cell)]),
            ContentBlock(id: cell, kind: .paragraph, box: .zero, parent: table, children: [.segment(s2)]),
        ]
        #expect(StructureValidation.issues(segments: segments, blocks: blocks).isEmpty)
    }

    @Test func mismatchesAreReported() {
        let s1 = SegmentID(), s2 = SegmentID(), block = BlockID()
        let segments = [
            TextSegment(id: s1, text: "a", box: .zero, parent: block),
            TextSegment(id: s2, text: "b", box: .zero, parent: block),
        ]
        let blocks = [ContentBlock(id: block, kind: .paragraph, box: .zero, children: [.segment(s2), .segment(s1)])]
        #expect(StructureValidation.issues(segments: segments, blocks: blocks) == [.readingOrderMismatch])
        #expect(StructureValidation.issues(segments: segments, blocks: []) == [.missingParent(s1), .missingParent(s2)])
    }

    @Test func analysisResultCodableRoundTrip() throws {
        let result = AnalysisResult(
            session: SessionID(), inputRevision: 3, inputFingerprint: ContentHash(sha256: Data(repeating: 1, count: 32)),
            region: DocumentRect(x: 0, y: 0, width: 10, height: 10),
            segments: [TextSegment(kind: .tableCell(TableCellRef(table: BlockID(), row: 1, column: 2)), text: "x", box: .zero, confidence: 0.5)],
            excluded: [ExcludedSegment(segment: TextSegment(text: "noise", box: .zero), reason: .noise)],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .milliseconds(12), sent: .nothing)
        )
        let decoded = try JSONDecoder().decode(AnalysisResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    @Test func historyEntryDecodesOlderSample() throws {
        let json = ##"{"id":{"raw":"6F9619FF-8B86-D011-B42D-00C04FC964FF"},"kind":"color","createdAt":0,"result":"#FFFFFF"}"##
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.schemaVersion == 1)
        #expect(entry.source.isEmpty)
        #expect(entry.isFavorite == false)
    }

    @Test func bilingualSegmentDropsTranslationUnlessTranslated() {
        let s = BilingualSegment(id: SegmentID(), source: "a", translated: "b", status: .failed(.emptyOutput), from: nil, to: .english)
        #expect(s.translated == nil)
        #expect(s.displayText == "a")
    }
}

@Suite("Annotations and plans")
struct AnnotationTests {
    @Test func rolesAndTranslation() {
        let mosaic = Annotation.mosaic(MosaicAnnotation(rect: DocumentRect(x: 0, y: 0, width: 10, height: 10), blockSize: 4, isPrivacy: true))
        #expect(mosaic.role == .redaction)
        #expect(Annotation.redaction(RedactionAnnotation(rect: .zero)).affectsAnalysisInput)
        let line = Annotation.arrow(LineAnnotation(start: DocumentPoint(x: 0, y: 0), end: DocumentPoint(x: 10, y: 5), color: .black, lineWidth: 2))
        guard case .arrow(let moved) = line.translated(dx: 5, dy: 1) else { Issue.record("kind changed"); return }
        #expect(moved.start == DocumentPoint(x: 5, y: 1))
        #expect(moved.end == DocumentPoint(x: 15, y: 6))
    }

    @Test func layerOrderValidation() {
        let ok = RenderPlan(
            session: SessionID(), editRevision: 0, canvas: PixelSize(width: 1, height: 1), scale: 1, background: .transparent,
            layers: [.base(source: .zero, destination: .zero), .decorations([]), .redactions([])], contentFrame: .zero
        )
        #expect(ok.hasValidLayerOrder)
        let bad = RenderPlan(
            session: SessionID(), editRevision: 0, canvas: PixelSize(width: 1, height: 1), scale: 1, background: .transparent,
            layers: [.base(source: .zero, destination: .zero), .redactions([]), .decorations([])], contentFrame: .zero
        )
        #expect(!bad.hasValidLayerOrder)
    }

    @Test func historyQueryMatching() {
        let entry = HistoryEntry(kind: .textTranslation, source: "Hello World", result: "你好世界", tags: ["greeting"])
        #expect(HistoryQuery(text: "world").matches(entry))
        #expect(HistoryQuery(text: "你好").matches(entry))
        #expect(HistoryQuery(text: "greet").matches(entry))
        #expect(!HistoryQuery(text: "zzz").matches(entry))
        #expect(!HistoryQuery(favoritesOnly: true).matches(entry))
        let color = HistoryEntry(kind: .color, source: "", result: "#A1B2C3")
        #expect(HistoryQuery(text: "b2c", kinds: [.color]).matches(color))
    }
}
