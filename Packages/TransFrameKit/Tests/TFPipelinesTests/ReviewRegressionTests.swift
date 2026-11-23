import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("Phase 4–7 review regressions")
struct ReviewRegressionTests {
    private func makeJob(_ text: String, route: EngineRouting, glossary: [GlossaryEntry] = [], context: TranslationContext? = nil) -> TranslationJob {
        TranslationJob(
            source: .plainText(purpose: .popup), units: [TranslationUnit(text: text)], from: .english, to: .simplifiedChinese,
            routing: route, glossary: GlossarySnapshot(version: 1, matched: glossary), context: context
        )
    }

    @Test func outboundFieldsAndGenerationUseGuardedText() async throws {
        let source = "Set password: ExampleSecret before continuing"
        let term = GlossaryEntry(source: "password: ExampleSecret", target: "ExampleSecret", to: .simplifiedChinese)
        let engine = FakeTranslationEngine(.openAICompatible, locality: .cloud, capabilities: [.batch, .glossary, .context], behavior: .translate { $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder())
        var settings = SettingsSnapshot()
        settings.privacy.sendContext = true
        let context = TranslationContext(appName: "Notes", windowTitle: "password: AnotherSecret")
        let request = makeJob(source, route: .ordered([.openAICompatible]), glossary: [term], context: context)
        let outcome = try await service.run(request, settings: settings) { _ in }
        let batch = try #require(engine.calls.calls.first)
        #expect(batch.glossary.isEmpty)
        #expect(batch.context?.appName == "Notes")
        #expect(batch.context?.windowTitle == nil)
        #expect(batch.units.first?.text.contains("ExampleSecret") == false)
        #expect(outcome.effectiveResult?.segments.first?.translated == source)
        let generator = FakeTextGenerator { "Edited: " + $0 }
        let rewritten = try await PrivacyGuard.generate(.polish, input: source, using: generator, settings: settings.privacy)
        #expect(rewritten == "Edited: " + source)
        #expect(generator.calls.calls.first?.input.contains("ExampleSecret") == false)
        settings.privacy.sendContext = false
        let session = DocumentSession(
            origin: .importedFile(name: "test"), baseImage: TestImages.pattern(width: 16, height: 16),
            context: CaptureContext(appBundleID: nil, appName: "Notes", windowTitle: "Private title")
        )
        #expect(PrivacyGuard.namingInput(session: session, settings: settings, locality: .cloud).isEmpty)
    }

    @Test func redactionCoversFullPEMBlockAndUploadMasksAreOpaque() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nsynthetic-body\n-----END PRIVATE KEY-----"
        let plan = PrivacyGuard.protect([TranslationUnit(text: pem)], settings: PrivacySettings())
        #expect(plan.units.isEmpty)
        #expect(plan.report.categories == [.privateKey])
        var session = DocumentSession(origin: .importedFile(name: "test"), baseImage: TestImages.pattern(width: 16, height: 16))
        let box = DocumentRect(x: 1, y: 1, width: 4, height: 4)
        session.annotations = [
            .mosaic(MosaicAnnotation(rect: box, blockSize: 2, isPrivacy: true)),
            .redaction(RedactionAnnotation(rect: box, fill: .black.withAlpha(0.25)))
        ]
        let rendered = try RenderPlanner(measurer: FakeTextMeasurer()).plan(for: session, purpose: .upload)
        guard case .redactions(let redactions) = rendered.layers.last else {
            Issue.record("Expected upload redactions")
            return
        }
        #expect(redactions.map(\.style) == [.solid(.black), .solid(.black)])
    }

    @Test func cachedReplyRebindsIDsAndRestoresOnlyThisRequestsSecret() async throws {
        let engine = FakeTranslationEngine(.openAICompatible, locality: .cloud, behavior: .translate { $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder())
        let first = makeJob("Please reset password: FirstSecret next", route: .ordered([.openAICompatible]))
        let second = makeJob("Please reset password: SecondSecret next", route: .ordered([.openAICompatible]))
        _ = try await service.run(first, settings: SettingsSnapshot()) { _ in }
        let secondOutcome = try await service.run(second, settings: SettingsSnapshot()) { _ in }
        let segment = try #require(secondOutcome.effectiveResult?.segments.first)
        #expect(segment.id == second.units[0].id)
        #expect(segment.translated == second.units[0].text)
        #expect(secondOutcome.effectiveResult?.fromCache == true)
        #expect(engine.calls.count == 1)
    }

    @Test func cancellingLastCacheSubscriberStopsWork() async {
        let cache = ResultCache<Int>(maxCount: 2, maxBytes: 100) { _ in 1 }
        let (started, start) = AsyncStream<Void>.makeStream()
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await cache.value(for: "key", force: false) {
                start.yield()
                do {
                    try await Task.sleep(for: .seconds(2))
                    stop.finish()
                    return 1
                } catch {
                    stop.yield()
                    stop.finish()
                    throw error
                }
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        var stops = stopped.makeAsyncIterator()
        #expect(await stops.next() != nil)
        #expect(await cache.isEmpty)
    }

    @Test func cancelledLimiterWaiterNeverStarts() async throws {
        let limiter = EngineLimiter(cloudLimit: 1)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await limiter.run(.mtran, local: true) {
                start.yield()
                var events = released.makeAsyncIterator()
                _ = await events.next()
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        let calls = CallLog<Int>()
        let waiter = Task { try await limiter.run(.mtran, local: true) { calls.append(1) } }
        waiter.cancel()
        release.yield()
        try await holder.value
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(calls.calls.isEmpty)
    }

    @Test func sourceEditRejectsTranslationForTheEarlierAnalysisRevision() async throws {
        let sessions = DocumentSessionStore(composer: FakeFrameComposer())
        var session = DocumentSession(origin: .importedFile(name: "test"), baseImage: TestImages.pattern(width: 16, height: 16))
        let segment = TextSegment(text: "Old", box: DocumentRect(x: 0, y: 0, width: 4, height: 4))
        let analysis = AnalysisResult(
            session: session.id, inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: session.imageBounds,
            segments: [segment], provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        session.analysis = analysis
        let id = await sessions.insert(session)
        let (operation, inputRevision) = try await sessions.beginOperation(.translation, on: id)
        let snapshot = try await sessions.analysisSnapshot(of: id)
        await sessions.update(id) { $0.analysis?.segments = [segment.with(revisedText: "New")] }
        let outcome = TranslationOutcome(operation: operation, routing: .ordered([.mtran]), results: [], effective: nil)
        await #expect(throws: AppError.cancelled) {
            try await sessions.writeTranslation(
                outcome, to: id, inputRevision: inputRevision, kind: .translation, operation: operation,
                analysisID: analysis.id, analysisRevision: snapshot.revision
            )
        }
    }

    @Test func allFailedEngineFallsBack() async throws {
        let empty = FakeTranslationEngine(.mtran, behavior: .translate { _ in nil })
        let successful = FakeTranslationEngine(.deepl, behavior: .translate { _ in "translated" })
        let service = TranslationService(engines: FakeTranslationEngines([empty, successful]), performance: FakePerformanceRecorder())
        let request = makeJob("Example", route: .ordered([.mtran, .deepl]))
        let outcome = try await service.run(request, settings: SettingsSnapshot()) { _ in }
        #expect(outcome.effective == .deepl)
        #expect(outcome.results.first?.succeeded == false)
    }

    @Test func unboundInsertionCopiesWithoutPasting() async throws {
        let input = FakeSelectedText(text: "Example")
        let clipboard = FakePasteboard()
        let history = FakeHistoryWorkflow()
        let sessions = DocumentSessionStore(composer: FakeFrameComposer())
        let render = RenderService(
            sessions: sessions, planner: RenderPlanner(measurer: FakeTextMeasurer()),
            executor: FakeRenderExecutor(), performance: FakePerformanceRecorder()
        )
        let recognition = RecognitionService(
            sessions: sessions, render: render, engines: EmptyRecognitionFactory(),
            guardian: PrivacyGuard(detector: nil), performance: FakePerformanceRecorder()
        )
        let engine = FakeTranslationEngine(.mtran, behavior: .translate { _ in "译文" })
        let translation = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder())
        let pipeline = DocumentPipelineService(
            sessions: sessions, recognition: recognition, translation: translation, history: history,
            thumbnails: FakeImageCodec(), glossary: nil, codes: nil, detector: nil
        )
        let service = TextTranslationService(
            capturer: input, inserter: input, pasteboard: clipboard, translation: translation,
            pipeline: pipeline, history: history, generators: nil, preferredLanguages: { ["zh-Hans"] }
        )
        var settings = SettingsSnapshot()
        settings.engines.orderedChain = [.mtran]
        var events: [InsertProgress] = []
        for try await event in service.translateAndInsert(tone: nil, polishOnly: false, settings: settings) { events.append(event) }
        #expect(events.last == .copiedToClipboard(.textInput(.targetChanged)))
        #expect(await clipboard.readString() == "译文")
        #expect(input.pasted.calls.isEmpty)
        #expect(input.inserted.calls.isEmpty)
    }

    @Test func cancellingPendingFirstStripInvalidatesTheRun() async throws {
        let capturer = FakeScrollCapturer()
        let sessions = DocumentSessionStore(composer: FakeFrameComposer())
        let scroll = ScrollCaptureService(capturer: capturer, sessions: sessions)
        let task = Task { try await scroll.begin(QuartzRect(x: 0, y: 0, width: 20, height: 20), excluding: []) }
        await capturer.waitForStripRequest()
        await scroll.cancel()
        await capturer.deliver(TestImages.pattern(width: 20, height: 20))
        await #expect(throws: AppError.cancelled) { try await task.value }
        await #expect(throws: AppError.capture(.timedOut)) { try await scroll.finish() }
        #expect(await sessions.sessionCount == 0)
    }

    @Test func invalidImportedTableCellCannotAllocateAnExportGrid() {
        let table = BlockID()
        let box = DocumentRect(x: 0, y: 0, width: 5, height: 5)
        let segment = TextSegment(
            kind: .tableCell(TableCellRef(table: table, row: Int.max, column: -1)), text: "cell", box: box, parent: table
        )
        let result = AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: box, segments: [segment],
            blocks: [ContentBlock(id: table, kind: .table(rows: 1, columns: 1), box: box, children: [.segment(segment.id)])],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        #expect(SmartActionDeriver().actions(for: result).isEmpty)
    }
}

private struct EmptyRecognitionFactory: RecognitionEngineProviding {
    func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] { [] }
    func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any RecognitionEngine)? { nil }
    func analysisEngine(_ provider: AnalysisProvider, settings: SettingsSnapshot) -> (any RecognitionEngine)? { nil }
}

extension ReviewRegressionTests {
    @Test func uploadRunsImageGuardAndUsesUniqueNamesIndependentOfContent() async throws {
        let sessions = DocumentSessionStore(composer: FakeFrameComposer())
        let id = await sessions.insert(DocumentSession(origin: .importedFile(name: "test"), baseImage: TestImages.pattern(width: 20, height: 20)))
        let executor = FakeRenderExecutor()
        let render = RenderService(
            sessions: sessions, planner: RenderPlanner(measurer: FakeTextMeasurer()), executor: executor, performance: FakePerformanceRecorder()
        )
        let detector = FakeSensitiveDetector([SensitiveFinding(category: .password, box: FrameRect(x: 0, y: 0, width: 4, height: 4), confidence: 1)])
        let uploader = FakeImageUploader()
        let export = ExportService(
            sessions: sessions, render: render, pasteboard: FakePasteboard(), encoder: FakeImageCodec(), files: FakeFileExporter(),
            sound: FakeSound(), uploader: uploader, history: nil, namer: FileNamer { _, _ in "Private filename" },
            guardian: PrivacyGuard(detector: detector), defaultDirectory: { URL(fileURLWithPath: "/tmp") }
        )
        var settings = SettingsSnapshot()
        settings.imageHost.provider = .hostOSS
        settings.ai.autoNaming = true
        _ = try await export.upload(id, settings: settings)
        _ = try await export.upload(id, settings: settings)
        let names = uploader.objectNames.calls
        #expect(detector.calls.count == 2)
        #expect(Set(names).count == 2)
        #expect(names.allSatisfy { $0.hasPrefix("screenshot-") && $0.hasSuffix(".png") })
    }
}
