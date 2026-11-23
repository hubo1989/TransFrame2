import CoreGraphics
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("Recognition input, privacy, cache and fallback")
struct RecognitionWorkflowTests {
    private let fixture = DocumentWorkflowFixture()

    @Test func cloudUsesSafeCroppedInputAndRefreshBypassesCache() async throws {
        let engine = FakeRecognitionEngine(.paddleCloud, locality: .cloud) { _ in
            RawRecognition(
                observations: [RawObservation(text: "Document", box: FrameRect(x: 3, y: 7, width: 12, height: 8))],
                languages: [.english], sent: .image
            )
        }
        let finding = SensitiveFinding(category: .apiKey, box: FrameRect(x: 0, y: 0, width: 10, height: 10), confidence: 1)
        let detector = FakeSensitiveDetector([finding])
        let service = fixture.recognition([engine], detector: detector)
        var session = fixture.session()
        session.crop = DocumentRect(x: 10, y: 10, width: 60, height: 60)
        session.annotations = [
            .mosaic(MosaicAnnotation(rect: DocumentRect(x: 14, y: 14, width: 12, height: 12), blockSize: 4, isPrivacy: true)),
            .rectangle(ShapeAnnotation(rect: session.visibleRect, strokeColor: .black, lineWidth: 2)),
        ]
        let id = await fixture.sessions.insert(session)
        let region = DocumentRect(x: 18, y: 22, width: 32, height: 24)
        let settings = SettingsSnapshot()
        let request = AnalysisRequest(session: id, inputRevision: 0, region: region, input: .original, engine: .paddleCloud, languageHints: [.english])
        let first = try await service.recognize(request, settings: settings)
        let cached = try await service.recognize(request, settings: settings)
        #expect(engine.calls.count == 1)
        let call = try #require(engine.calls.calls.first)
        #expect(call.image.pixelSize == PixelSize(width: 32, height: 24))
        #expect(TestImages.pixel(call.image, x: 3, y: 3).r == 0)
        #expect(TestImages.pixel(call.image, x: 20, y: 20).r == 255)
        #expect(first.segments.first?.box == DocumentRect(x: 21, y: 29, width: 12, height: 8))
        #expect(first.provenance.sent == .image)
        #expect(first.provenance.privacy?.categories == [.apiKey])
        #expect(cached.provenance.fromCache)
        #expect(cached.provenance.sent == .nothing)
        #expect(cached.inputFingerprint == first.inputFingerprint)
        let plan = try #require(fixture.executor.plans.calls.first)
        #expect(plan.layers.count == 2)
        guard case .redactions(let masks) = plan.layers.last else { Issue.record("Cloud needs solid redactions"); return }
        #expect(masks.first?.style == .solid(.black))

        let refresh = AnalysisRequest(
            session: id, inputRevision: 0, region: region, engine: .paddleCloud, languageHints: [.english], cache: .forceRefresh)
        #expect(try await service.recognize(refresh, settings: settings).provenance.fromCache == false)
        #expect(engine.calls.count == 2)
        #expect(fixture.performance.samples(Budget.cacheHit).count == 1)
        #expect(fixture.performance.samples(Budget.privacyGuard).count == 3)
    }

    @Test func malformedModelOutputFallsBackToVisionWithProvenance() async throws {
        let model = FakeRecognitionEngine(.openAICompatible, locality: .cloud) { _ throws(AppError) in
            throw .engine(.invalidResponse(.openAICompatible, detail: "invalid OCR output"))
        }
        let vision = FakeRecognitionEngine(.visionText) { _ in
            RawRecognition(observations: [RawObservation(text: "Local recovery", box: FrameRect(x: 0, y: 0, width: 20, height: 10))])
        }
        let service = fixture.recognition([model, vision])
        let id = await fixture.sessions.insert(fixture.session())
        let request = AnalysisRequest(session: id, inputRevision: 0, engine: .openAICompatible, languageHints: [.english], detail: .structured)
        let result = try await service.recognize(request, settings: SettingsSnapshot(), provider: .openAI, overridePrivacy: false).result
        #expect(result.plainText == "Local recovery")
        #expect(result.provenance.engine == .visionText)
        #expect(result.provenance.fallbackFrom == .openAICompatible)
        #expect(result.provenance.sent == .image)
        #expect(vision.calls.calls.first?.hints == [.english])
        #expect(vision.calls.calls.first?.detail == .lines)
        #expect(model.calls.calls.first?.detail == .structured)
    }

    @Test func staleOrInvalidRequestsDoNotRenderOrInvokeEngine() async {
        let service = fixture.recognition([])
        let id = await fixture.sessions.insert(fixture.session())
        let settings = SettingsSnapshot()
        let outside = AnalysisRequest(
            session: id, inputRevision: 0, region: DocumentRect(x: -1, y: 0, width: 20, height: 10), engine: .visionText)
        await #expect(throws: AppError.recognition(.regionOutOfBounds)) { _ = try await service.recognize(outside, settings: settings) }
        let stale = AnalysisRequest(session: id, inputRevision: 3, engine: .visionText)
        await #expect(throws: AppError.cancelled) { _ = try await service.recognize(stale, settings: settings) }
        let unavailable = AnalysisRequest(session: id, inputRevision: 0, engine: .visionDocument)
        await #expect(throws: AppError.engine(.unavailableOnThisOS(.visionDocument, minimum: OSVersion(26)))) {
            _ = try await service.recognize(unavailable, settings: settings)
        }
        let missing = AnalysisRequest(session: id, inputRevision: 0, engine: .paddleLocal)
        await #expect(throws: AppError.engine(.notConfigured(.paddleLocal))) { _ = try await service.recognize(missing, settings: settings) }
        #expect(fixture.executor.plans.calls.isEmpty)
    }

    @Test func sizeLimitedEngineReceivesOverlappingTilesAndRestoresOutputOffsets() async throws {
        let engine = FakeRecognitionEngine(.paddleLocal, maxImageEdge: 100) { call in
            let label = call.image.pixelSize.width == 100 ? "First tile" : "Last tile"
            return RawRecognition(observations: [RawObservation(text: label, box: FrameRect(x: 1, y: 2, width: 12, height: 6))])
        }
        let session = DocumentSession(origin: .importedFile(name: "wide"), baseImage: TestImages.pattern(width: 143, height: 40))
        let id = await fixture.sessions.insert(session)
        let request = AnalysisRequest(session: id, inputRevision: 0, input: .original, engine: .paddleLocal)
        let result = try await fixture.recognition([engine]).recognize(request, settings: SettingsSnapshot())
        #expect(engine.calls.calls.map { $0.image.pixelSize.width } == [100, 91])
        #expect(result.segments.map(\.text) == ["First tile", "Last tile"])
        #expect(result.segments.map { $0.box.minX } == [1, 53])
        #expect(result.provenance.sent == .nothing)
    }

    @Test func transportFailureIsNotMistakenForEmptyModelOutput() async {
        let error = AppError.engine(.invalidResponse(.openAICompatible, detail: "network unavailable"))
        let model = FakeRecognitionEngine(.openAICompatible, locality: .cloud) { _ throws(AppError) in throw error }
        let vision = FakeRecognitionEngine(.visionText) { _ in RawRecognition(observations: []) }
        let id = await fixture.sessions.insert(fixture.session())
        let request = AnalysisRequest(session: id, inputRevision: 0, engine: .openAICompatible)
        await #expect(throws: error) {
            _ = try await fixture.recognition([model, vision]).recognize(request, settings: SettingsSnapshot(), provider: .openAI, overridePrivacy: false)
        }
        #expect(vision.calls.calls.isEmpty)
    }
}
