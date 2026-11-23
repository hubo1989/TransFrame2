import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

struct DocumentWorkflowFixture {
    let sessions = DocumentSessionStore(composer: FakeFrameComposer())
    let executor = FakeRenderExecutor()
    let performance = FakePerformanceRecorder()
    let history = FakeHistoryWorkflow()

    var render: RenderService {
        RenderService(sessions: sessions, planner: RenderPlanner(measurer: FakeTextMeasurer()), executor: executor, performance: performance)
    }

    func recognition(_ engines: [FakeRecognitionEngine], detector: (any SensitiveContentDetecting)? = nil) -> RecognitionService {
        RecognitionService(
            sessions: sessions, render: render, engines: FakeRecognitionEngines(engines),
            guardian: PrivacyGuard(detector: detector), performance: performance
        )
    }

    func pipeline(
        recognition: RecognitionService, translators: [FakeTranslationEngine] = [], glossary: (any GlossaryStoring)? = nil,
        codes: (any CodeDetecting)? = nil, detector: (any SensitiveContentDetecting)? = nil
    ) -> DocumentPipelineService {
        DocumentPipelineService(
            sessions: sessions, recognition: recognition,
            translation: TranslationService(engines: FakeTranslationEngines(translators), performance: performance),
            history: history, thumbnails: FakeImageCodec(), glossary: glossary, codes: codes, detector: detector, preferredLanguages: { ["fr-FR"] }
        )
    }

    func session(segments: [TextSegment]? = nil, context: CaptureContext? = nil) -> DocumentSession {
        var session = DocumentSession(origin: .importedFile(name: "fixture"), baseImage: TestImages.solid(width: 100, height: 80), context: context)
        if let segments {
            session.analysis = AnalysisResult(
                session: session.id, inputRevision: 0, inputFingerprint: CacheKey.fingerprint(session.baseImage),
                region: session.imageBounds, segments: segments,
                provenance: Provenance(engine: .visionText, configDigest: "fixture", locality: .onDevice, duration: .zero, sent: .nothing)
            )
        }
        return session
    }
}

private func line(_ text: String, y: Double = 10) -> RawObservation {
    RawObservation(text: text, box: FrameRect(x: 4, y: y, width: 32, height: 12), language: .english)
}

private func collect(_ stream: AsyncThrowingStream<DocumentPipelineEvent, any Error>) async throws -> [DocumentPipelineEvent] {
    var events: [DocumentPipelineEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

@Suite("Document recognition and translation stages")
struct DocumentWorkflowTests {
    private let fixture = DocumentWorkflowFixture()

    @Test func recognizesPersistsResultsAndRestoresExcludedNoise() async throws {
        let engine = FakeRecognitionEngine(.visionText) { _ in RawRecognition(observations: [line("Welcome"), line("!", y: 36)]) }
        let id = await fixture.sessions.insert(fixture.session())
        let pipeline = fixture.pipeline(recognition: fixture.recognition([engine]))
        var settings = SettingsSnapshot()
        settings.languages.capture.source = .english
        let events = try await collect(pipeline.recognize(id, options: DocumentPipelineOptions(settings: settings, overridePrivacyGuard: true)))
        guard case .stage(.preparing) = events.first, case .finished = events.last else {
            Issue.record("Recognition events did not bracket the operation")
            return
        }
        let snapshot = try await fixture.sessions.snapshot(of: id)
        let result = try #require(snapshot.analysis)
        #expect(result.plainText == "Welcome")
        #expect(events.contains { if case .recognized(result) = $0 { true } else { false } })
        #expect(events.contains { if case .privacy(let report) = $0 { report.overriddenByUser } else { false } })
        #expect(engine.calls.calls.first?.hints == [.english])
        let excluded = try #require(result.excluded.first)
        try await pipeline.restoreExcluded(excluded.segment.id, in: id)
        let restored = try await fixture.sessions.snapshot(of: id)
        #expect(restored.analysis?.excluded.isEmpty == true)
        #expect(restored.analysis?.segments.contains { $0.id == excluded.segment.id } == true)
        await #expect(throws: AppError.invariant("not excluded")) { try await pipeline.restoreExcluded(SegmentID(), in: SessionID()) }
    }

    @Test func translationPublishesStagesUsesTargetOverrideAndWritesHistory() async throws {
        let engine = FakeRecognitionEngine(.openAICompatible, locality: .cloud) { _ in
            RawRecognition(observations: [line("Welcome")], sent: .image)
        }
        let primary = FakeTranslationEngine(.mtran, behavior: .translate { _ in "Bienvenue" })
        let secondary = FakeTranslationEngine(.deepl, behavior: .translate { _ in "Salut" })
        let pipeline = fixture.pipeline(recognition: fixture.recognition([engine]), translators: [primary, secondary])
        var session = fixture.session()
        session.suggestedName = "Release notes"
        let id = await fixture.sessions.insert(session)
        var settings = SettingsSnapshot()
        settings.recognition.analysisProvider = .openAI
        settings.engines.mode = .compare
        settings.engines.compareGroup = [.mtran, .deepl]
        settings.presentation.overlayMode = .replaceOriginal

        let options = DocumentPipelineOptions(settings: settings, target: LanguageCode("fr"), overridePrivacyGuard: true)
        let events = try await collect(pipeline.translate(id, options: options))
        let stages = events.compactMap { event in if case .stage(let stage) = event { stage } else { nil } }
        #expect(stages == [.preparing, .recognizing, .translating])
        #expect(events.contains { if case .translation(.finished) = $0 { true } else { false } })
        #expect(engine.calls.calls.first?.detail == .structured)
        #expect(primary.calls.calls.first?.to == LanguageCode("fr"))
        let translated = try await fixture.sessions.snapshot(of: id)
        #expect(translated.translation?.effective == .mtran)
        #expect(translated.translation?.privacy?.overriddenByUser == true)
        #expect(translated.presentation.showsTranslationOverlay)
        #expect(translated.presentation.overlayMode == .replaceOriginal)
        #expect(translated.editRevision == 0)
        let entry = try #require(fixture.history.recorded.calls.first)
        #expect(entry.kind == .screenshotTranslation)
        #expect(entry.source == "Welcome")
        #expect(entry.result == "Bienvenue")
        #expect(entry.tags == ["Release notes"])
        #expect(entry.thumbnail?.isEmpty == false)

        try await pipeline.selectEffectiveEngine(.deepl, in: id)
        #expect(try await fixture.sessions.snapshot(of: id).translation?.effectiveResult?.segments.first?.displayText == "Salut")
        #expect(primary.calls.count == 1)
        #expect(secondary.calls.count == 1)
        await #expect(throws: AppError.invariant("engine has no result")) {
            try await pipeline.selectEffectiveEngine(.google, in: id)
        }
    }

    @Test func translationReusesRevisedAnalysisAndScopesGlossaryAndContext() async throws {
        let translation = FakeTranslationEngine(.openAICompatible, capabilities: [.context, .glossary, .segmentIDs], behavior: .translate { _ in "OK" })
        let scoped = GlossaryEntry(source: "Release notes", target: "Notes", from: .english, to: LanguageCode("fr"), scope: .app(bundleID: "fixture.app"))
        let unrelated = GlossaryEntry(source: "Release", target: "Never", to: LanguageCode("fr"), scope: .app(bundleID: "other.app"))
        let glossary = FakeGlossaryStore([scoped, unrelated])
        let pipeline = fixture.pipeline(recognition: fixture.recognition([]), translators: [translation], glossary: glossary)
        let box = DocumentRect(x: 4, y: 4, width: 50, height: 16)
        let revised = TextSegment(text: "Notes", revisedText: "Release notes", box: box)
        let code = TextSegment(kind: .code(language: nil), text: "let a = 1", box: box, translatability: .keepOriginal(.code))
        let context = CaptureContext(appBundleID: "fixture.app", appName: "Notes", windowTitle: "Changelog")
        let id = await fixture.sessions.insert(fixture.session(segments: [revised, code], context: context))
        var settings = SettingsSnapshot()
        settings.languages.capture.source = .english
        settings.languages.capture.target = .specific(LanguageCode("fr"))
        settings.engines.orderedChain = [.openAICompatible]
        settings.prompts.custom[PromptKey(engine: .openAICompatible, scene: .screenshot)] = "Use concise translations"
        settings.presentation.defaultDisplay = .textDrawer
        let events = try await collect(pipeline.translate(id, options: DocumentPipelineOptions(settings: settings)))
        #expect(!events.contains { if case .stage(.recognizing) = $0 { true } else { false } })
        let batch = try #require(translation.calls.calls.first)
        #expect(batch.units.map(\.id) == [revised.id])
        #expect(batch.units.map(\.text) == ["Release notes"])
        #expect(batch.prompt?.template == "Use concise translations")
        #expect(batch.glossary == [scoped])
        #expect(batch.context?.windowTitle == "Changelog")
        #expect(try await fixture.sessions.snapshot(of: id).presentation.showsTranslationOverlay == false)
        #expect(fixture.history.recorded.calls.first?.thumbnail == nil)
    }

    @Test func noTranslatableUnitsFailWithoutHistory() async throws {
        let id = await fixture.sessions.insert(fixture.session(segments: []))
        let pipeline = fixture.pipeline(recognition: fixture.recognition([]))
        await #expect(throws: AppError.translation(.noTranslatableText)) {
            _ = try await collect(pipeline.translate(id, options: DocumentPipelineOptions(settings: SettingsSnapshot())))
        }
        #expect(fixture.history.recorded.calls.isEmpty)
        #expect(try await fixture.sessions.snapshot(of: id).translation == nil)
        await #expect(throws: AppError.cancelled) {
            _ = try await collect(pipeline.recognize(SessionID(), options: DocumentPipelineOptions(settings: SettingsSnapshot())))
        }
    }

    @Test func cancellationDiscardsAnInFlightRecognition() async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = FakeRecognitionEngine(.visionText) { _ throws(AppError) in
            signal.yield()
            signal.finish()
            do { try await Task.sleep(for: .seconds(30)) } catch { throw .cancelled }
            return RawRecognition(observations: [line("Unwanted")])
        }
        let id = await fixture.sessions.insert(fixture.session())
        let pipeline = fixture.pipeline(recognition: fixture.recognition([engine]))
        let stream = pipeline.recognize(id, options: DocumentPipelineOptions(settings: SettingsSnapshot()))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        await pipeline.cancel(id)
        await #expect(throws: AppError.cancelled) { _ = try await collect(stream) }
        #expect(try await fixture.sessions.snapshot(of: id).analysis == nil)
    }

    @Test func mosaicClipsFindingsAndUndoesAsOnePrivacyEdit() async throws {
        let findings = [
            SensitiveFinding(category: .email, box: FrameRect(x: 0, y: 10, width: 12, height: 10), confidence: 0.9),
            SensitiveFinding(category: .apiKey, box: FrameRect(x: 40, y: 20, width: 10, height: 12), confidence: 1),
            SensitiveFinding(category: .password, box: FrameRect(x: 20, y: 20, width: 10, height: 10), confidence: 0.2),
            SensitiveFinding(category: .phone, box: FrameRect(x: 0, y: 30, width: 2, height: 5), confidence: 1),
        ]
        var session = fixture.session(segments: [])
        session.crop = DocumentRect(x: 8, y: 8, width: 62, height: 52)
        let id = await fixture.sessions.insert(session)
        let detector = FakeSensitiveDetector(findings)
        let pipeline = fixture.pipeline(recognition: fixture.recognition([]), detector: detector)
        #expect(try await pipeline.smartMosaic(id, settings: SettingsSnapshot()) == 2)
        let after = try await fixture.sessions.snapshot(of: id)
        #expect(after.annotations.map(\.bounds) == [
            DocumentRect(x: 8, y: 10, width: 4, height: 10), DocumentRect(x: 40, y: 20, width: 10, height: 12),
        ])
        #expect(after.annotations.allSatisfy { $0.role == .redaction })
        #expect(after.analysis == nil)
        #expect(after.analysisInputRevision == 1)
        #expect(detector.calls.calls.first?.pixelSize == session.baseImage.pixelSize)
        #expect(await fixture.sessions.undo(id))
        #expect(try await fixture.sessions.snapshot(of: id).annotations.isEmpty)
        #expect(await fixture.sessions.undo(id) == false)
        let noFindings = fixture.pipeline(recognition: fixture.recognition([]), detector: FakeSensitiveDetector([]))
        #expect(try await noFindings.smartMosaic(id, settings: SettingsSnapshot()) == 0)
        #expect(try await fixture.pipeline(recognition: fixture.recognition([])).smartMosaic(id, settings: SettingsSnapshot()) == 0)
    }
}
