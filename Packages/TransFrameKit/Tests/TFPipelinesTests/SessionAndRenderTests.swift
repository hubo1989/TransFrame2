import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

private func makeSession(width: Int = 200, height: Int = 100, scale: Double = 2) -> DocumentSession {
    DocumentSession(origin: .importedFile(name: "x"), baseImage: TestImages.pattern(width: width, height: height, scale: scale))
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DocumentRect { DocumentRect(x: x, y: y, width: w, height: h) }

private let decoration = Annotation.rectangle(ShapeAnnotation(rect: rect(10, 10, 20, 20), strokeColor: .black, lineWidth: 2))
private let redaction = Annotation.redaction(RedactionAnnotation(rect: rect(40, 10, 20, 20)))

@Suite("Session revisions (SPEC §02 §5 table)")
struct SessionRevisionTests {
    let store = DocumentSessionStore(composer: FakeFrameComposer())

    private func withAnalysis(_ session: DocumentSession) -> DocumentSession {
        var s = session
        s.analysis = AnalysisResult(
            session: s.id, inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: s.imageBounds,
            segments: [TextSegment(text: "Hello", box: rect(0, 0, 10, 10))],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        let segment = s.analysis!.segments[0]
        s.translation = TranslationOutcome(
            operation: OperationID(), routing: .ordered([.mtran]),
            results: [
                EngineResult(
                    id: .mtran,
                    segments: [
                        BilingualSegment(
                            id: segment.id, source: "Hello", translated: "你好", status: .translated, from: .english, to: .simplifiedChinese)
                    ])
            ],
            effective: .mtran
        )
        return s
    }

    @Test func decorationEditKeepsResults() async throws {
        let id = await store.insert(withAnalysis(makeSession()))
        let s = try await store.snapshot(of: id)
        try await store.apply(.insert(decoration, into: s, label: "add"), to: id)
        let after = try await store.snapshot(of: id)
        #expect(after.editRevision == 1)
        #expect(after.analysisInputRevision == 0)
        #expect(after.analysis != nil)
        #expect(after.translation != nil)
    }

    @Test func redactionEditInvalidatesResults() async throws {
        let id = await store.insert(withAnalysis(makeSession()))
        let s = try await store.snapshot(of: id)
        try await store.apply(.insert(redaction, into: s, label: "add"), to: id)
        let after = try await store.snapshot(of: id)
        #expect(after.editRevision == 1)
        #expect(after.analysisInputRevision == 1)
        #expect(after.analysis == nil)
        #expect(after.translation == nil)
    }

    @Test func cropInvalidatesAndIsNonDestructive() async throws {
        let id = await store.insert(withAnalysis(makeSession()))
        var s = try await store.snapshot(of: id)
        try await store.apply(.insert(decoration, into: s, label: "add"), to: id)
        s = try await store.snapshot(of: id)
        try await store.apply(try #require(.setCrop(rect(50, 50, 50, 40), in: s, label: "crop")), to: id)
        let cropped = try await store.snapshot(of: id)
        #expect(cropped.crop == rect(50, 50, 50, 40))
        #expect(cropped.annotations.count == 1)
        #expect(cropped.analysisInputRevision == 1)
        #expect(cropped.analysis == nil)
        #expect(await store.undo(id))
        let undone = try await store.snapshot(of: id)
        #expect(undone.crop == nil)
        #expect(undone.editRevision == 3)
        #expect(undone.analysisInputRevision == 2)
    }

    @Test func cropOutsideImageIsAnError() async throws {
        let id = await store.insert(makeSession())
        let s = try await store.snapshot(of: id)
        await #expect(throws: AppError.recognition(.regionOutOfBounds)) {
            try await store.apply(EditTransaction.setCrop(rect(150, 0, 100, 50), in: s, label: "crop")!, to: id)
        }
    }

    @Test func reviseSegmentInvalidatesOnlyThatSegment() async throws {
        let id = await store.insert(withAnalysis(makeSession()))
        let s = try await store.snapshot(of: id)
        let segment = try #require(s.analysis?.segments.first)
        try await store.apply(try #require(.reviseSegment(segment.id, text: "Hallo", in: s, label: "revise")), to: id)
        let after = try await store.snapshot(of: id)
        #expect(after.analysis?.segments.first?.effectiveText == "Hallo")
        #expect(after.analysisInputRevision == 0)
        #expect(after.translation?.results.first?.segments.first?.status == .cancelled)
    }

    @Test func undoRedoAreInverseAndBumpRevision() async throws {
        let id = await store.insert(makeSession())
        let s = try await store.snapshot(of: id)
        try await store.apply(.insert(decoration, into: s, label: "add"), to: id)
        #expect(await store.canUndo(id))
        #expect(await store.undo(id))
        #expect(try await store.snapshot(of: id).annotations.isEmpty)
        #expect(await store.redo(id))
        let redone = try await store.snapshot(of: id)
        #expect(redone.annotations == [decoration])
        #expect(redone.editRevision == 3)
        #expect(await store.redo(id) == false)
    }

    @Test func undoDepthIsFifty() async throws {
        let id = await store.insert(makeSession())
        for i in 0..<60 {
            let s = try await store.snapshot(of: id)
            let a = Annotation.line(LineAnnotation(start: DocumentPoint(x: 0, y: Double(i)), end: DocumentPoint(x: 5, y: 5), color: .black, lineWidth: 1))
            try await store.apply(.insert(a, into: s, label: "add"), to: id)
        }
        var undone = 0
        while await store.undo(id) { undone += 1 }
        #expect(undone == DocumentSessionStore.undoDepth)
        #expect(try await store.snapshot(of: id).annotations.count == 10)
    }

    @Test func staleResultsAreRejected() async throws {
        let id = await store.insert(makeSession())
        let (operation, revision) = try await store.beginOperation(.recognition, on: id)
        let s = try await store.snapshot(of: id)
        try await store.apply(.insert(redaction, into: s, label: "add"), to: id)
        let result = AnalysisResult(
            session: id, inputRevision: revision, inputFingerprint: ContentHash(sha256: Data()), region: s.imageBounds, segments: [],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        await #expect(throws: AppError.cancelled) { try await store.writeAnalysis(result, kind: .recognition, operation: operation) }
    }

    @Test func newOperationSupersedesOld() async throws {
        let id = await store.insert(makeSession())
        let (first, revision) = try await store.beginOperation(.translation, on: id)
        let (second, _) = try await store.beginOperation(.translation, on: id)
        #expect(await store.isCurrent(.translation, operation: second, on: id))
        #expect(await !store.isCurrent(.translation, operation: first, on: id))
        let outcome = TranslationOutcome(operation: first, routing: .ordered([.mtran]), results: [], effective: nil)
        await #expect(throws: AppError.cancelled) {
            try await store.writeTranslation(outcome, to: id, inputRevision: revision, kind: .translation, operation: first)
        }
    }

    @Test func lastReleaseFreesSessionAndFinishesStreams() async throws {
        let id = await store.insert(makeSession())
        let editor = SessionOwner.editor(UUID())
        let pin = SessionOwner.pin(UUID())
        await store.retain(id, by: editor)
        await store.retain(id, by: pin)
        let stream = await store.snapshots(of: id)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        await store.release(id, by: pin)
        #expect(try await store.snapshot(of: id).id == id)
        await store.release(id, by: editor)
        await #expect(throws: AppError.cancelled) { try await store.snapshot(of: id) }
        #expect(await iterator.next() == nil)
    }

    @Test func createFromFramesUsesFrozenPixelsOnly() async throws {
        let composer = FakeFrameComposer()
        let store = DocumentSessionStore(composer: composer)
        let frames = TestImages.frozen([TestImages.display(1, x: 0, y: 0, width: 100, height: 80, scale: 2)])
        let id = try await store.create(
            from: frames, selection: SelectionGeometry(rect: QuartzRect(x: 10, y: 10, width: 30, height: 20), source: .freeform, topologyVersion: 1))
        let session = try await store.snapshot(of: id)
        #expect(session.baseImage.pixelSize == PixelSize(width: 60, height: 40))
        #expect(composer.calls.count == 1)
        guard case .capture(let provenance) = session.origin else { Issue.record("origin"); return }
        #expect(provenance.intent == .region)
    }
}

@Suite("Render planner")
struct RenderPlannerTests {
    let planner = RenderPlanner(measurer: FakeTextMeasurer())

    @Test func layerOrderAndRedactionLast() throws {
        var s = makeSession()
        s.annotations = [redaction, decoration]
        let plan = try planner.plan(for: s, purpose: .screen)
        #expect(plan.hasValidLayerOrder)
        guard case .redactions = plan.layers.last else { Issue.record("redactions must be last"); return }
        #expect(plan.canvas == PixelSize(width: 200, height: 100))
    }

    @Test func cropOffsetsCanvas() throws {
        var s = makeSession()
        s.crop = rect(50, 20, 100, 60)
        s.annotations = [decoration]
        let plan = try planner.plan(for: s, purpose: .clipboard)
        #expect(plan.canvas == PixelSize(width: 100, height: 60))
        guard case .decorations(let items) = plan.layers[1] else { Issue.record("decorations"); return }
        #expect(items[0].offsetX == -50)
        #expect(items[0].offsetY == -20)
    }

    @Test func analysisInputBurnsRedactionsSolidAndDropsDecorations() throws {
        var s = makeSession()
        let mosaic = Annotation.mosaic(MosaicAnnotation(rect: rect(0, 0, 20, 20), blockSize: 8, isPrivacy: true))
        s.annotations = [decoration, mosaic, redaction]
        let safe = try planner.plan(for: s, purpose: .analysisInput(.safe))
        #expect(!safe.layers.contains { if case .decorations = $0 { true } else { false } })
        guard case .redactions(let items) = safe.layers.last else { Issue.record("redactions"); return }
        #expect(items.count == 2)
        #expect(items.allSatisfy { if case .solid = $0.style { true } else { false } })
        let screen = try planner.plan(for: s, purpose: .screen)
        guard case .redactions(let shown) = screen.layers.last else { Issue.record("redactions"); return }
        #expect(shown.contains { if case .mosaic = $0.style { true } else { false } })
        let original = try planner.plan(for: s, purpose: .analysisInput(.original))
        #expect(original.layers.count == 1)
    }

    @Test func jpegGetsWhiteBackgroundAndBeautifyAddsPadding() throws {
        var s = makeSession(scale: 2)
        #expect(try planner.plan(for: s, purpose: .file(.jpeg)).background == .white)
        #expect(try planner.plan(for: s, purpose: .file(.png)).background == .transparent)
        s.presentation.beautify = true
        let plan = try planner.plan(for: s, purpose: .file(.png))
        #expect(plan.canvas == PixelSize(width: 200 + 144, height: 100 + 144))
        #expect(plan.contentFrame == CanvasRect(x: 72, y: 72, width: 200, height: 100))
        #expect(try planner.plan(for: s, purpose: .analysisInput(.safe)).canvas == PixelSize(width: 200, height: 100))
    }

    @Test func excludedAnnotationsAreLeftOut() throws {
        var s = makeSession()
        s.annotations = [decoration]
        let plan = try planner.plan(for: s, purpose: .screen, excluding: [decoration.id])
        #expect(plan.layers.count == 1)
    }

    @Test func samePlanForSameSnapshot() throws {
        var s = makeSession()
        s.annotations = [decoration, redaction]
        #expect(try planner.plan(for: s, purpose: .screen) == planner.plan(for: s, purpose: .screen))
    }
}

@Suite("In-place translation layout")
struct LayoutTests {
    let layout = TranslationLayoutPlanner(measurer: FakeTextMeasurer())

    private func analysis(_ segments: [TextSegment]) -> AnalysisResult {
        AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: rect(0, 0, 400, 300),
            segments: segments, provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
    }

    private func translated(_ segment: TextSegment, _ text: String) -> BilingualSegment {
        BilingualSegment(id: segment.id, source: segment.text, translated: text, status: .translated, from: .english, to: .simplifiedChinese)
    }

    @Test func belowOriginalFitsUnderTheBox() {
        let s = TextSegment(text: "Hello", box: rect(10, 10, 100, 20), style: SegmentStyleHint(fontSize: 16))
        let placements = layout.layout(
            analysis: analysis([s]), translations: [translated(s, "你好")], mode: .belowOriginal, offsetX: 0, offsetY: 0,
            canvas: CanvasRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        #expect(placements.count == 1)
        #expect(placements[0].fit == .fits)
        #expect(placements[0].frame.minY >= 30)
        #expect(placements[0].fontSize == 16)
    }

    @Test func wrapsThenShrinksThenOmits() {
        let canvas = CanvasRect(x: 0, y: 0, width: 400, height: 300)
        let narrow = TextSegment(text: "A", box: rect(0, 0, 40, 30), style: SegmentStyleHint(fontSize: 20))
        let wrapped = layout.layout(
            analysis: analysis([narrow]), translations: [translated(narrow, "abcdef")], mode: .replaceOriginal, offsetX: 0, offsetY: 0,
            canvas: canvas, scale: 1)
        #expect(wrapped[0].fit == .shrunk || wrapped[0].fit == .wrapped)
        #expect(wrapped[0].fontSize >= 12)
        let tiny = TextSegment(text: "A", box: rect(0, 0, 20, 10), style: SegmentStyleHint(fontSize: 10))
        let omitted = layout.layout(
            analysis: analysis([tiny]), translations: [translated(tiny, String(repeating: "x", count: 80))], mode: .replaceOriginal, offsetX: 0,
            offsetY: 0, canvas: canvas, scale: 1)
        #expect(omitted[0].fit == .omitted)
        #expect(omitted[0].backdropFrame == nil)
    }

    @Test func belowOriginalStopsAtNextBlock() {
        let a = TextSegment(text: "A", box: rect(0, 0, 100, 20), style: SegmentStyleHint(fontSize: 16))
        let b = TextSegment(text: "B", box: rect(0, 24, 100, 20), style: SegmentStyleHint(fontSize: 16))
        let placements = layout.layout(
            analysis: analysis([a, b]), translations: [translated(a, "long translation text here"), translated(b, "b")], mode: .belowOriginal,
            offsetX: 0, offsetY: 0, canvas: CanvasRect(x: 0, y: 0, width: 100, height: 300), scale: 1)
        #expect(placements[0].fit == .omitted)
        #expect(placements[1].fit != .omitted)
    }

    @Test func formulasAndCodeAreNeverPlaced() {
        let code = TextSegment(kind: .code(language: "swift"), text: "let x = 1", box: rect(0, 0, 100, 20), translatability: .keepOriginal(.code))
        let placements = layout.layout(
            analysis: analysis([code]), translations: [translated(code, "x")], mode: .replaceOriginal, offsetX: 0, offsetY: 0,
            canvas: CanvasRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        #expect(placements.isEmpty)
    }

    @Test func minimumFontSizeRespected() {
        let s = TextSegment(text: "A", box: rect(0, 0, 60, 30), style: SegmentStyleHint(fontSize: 30))
        let placements = layout.layout(
            analysis: analysis([s]), translations: [translated(s, "abcdefghijk")], mode: .replaceOriginal, offsetX: 0, offsetY: 0,
            canvas: CanvasRect(x: 0, y: 0, width: 400, height: 300), scale: 2)
        for p in placements where p.fit != .omitted { #expect(p.fontSize >= max(18, 18)) }
    }
}

@Suite("Naming")
struct NamingTests {
    @Test func defaultScreenshotName() {
        let date = Date(timeIntervalSince1970: 1_764_000_000)
        let name = ScreenshotNaming.baseName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "Screenshot 2025-11-24 at 16.00.00")
    }

    @Test(arguments: [
        ("a/b:c", "a b c"), ("  ..hidden  ", "hidden"), ("line\nbreak", "line break"), ("", nil as String?), ("???", nil),
    ])
    func sanitize(raw: String, expected: String?) {
        #expect(ScreenshotNaming.sanitize(raw) == expected)
    }

    @Test func sanitizeTrimsLength() {
        #expect(ScreenshotNaming.sanitize(String(repeating: "word ", count: 40), maxLength: 30)?.count ?? 0 <= 30)
    }

    @Test func fallbackUsesAppAndKeywords() async {
        var session = makeSession()
        session = DocumentSession(
            origin: session.origin, baseImage: session.baseImage,
            context: CaptureContext(appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: nil))
        var settings = SettingsSnapshot()
        settings.ai.autoNaming = true
        let name = await FileNamer().name(for: session, settings: settings, date: Date(timeIntervalSince1970: 0))
        #expect(name.suggested)
        #expect(name.base.hasPrefix("Safari - "))
        settings.ai.autoNaming = false
        #expect(await FileNamer().name(for: session, settings: settings, date: Date(timeIntervalSince1970: 0)).base.hasPrefix("Screenshot "))
    }
}
