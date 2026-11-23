import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

private struct CatalogDependencies: ModelDiscovering, EngineHealthProbing, PaddleInstallationChecking {
    let discovery = CallLog<(String, CredentialRef?, EngineID)>()
    let probes = CallLog<(EngineID, Bool)>()
    let paths = CallLog<String?>()

    func models(endpoint: String, credential: CredentialRef?, engine: EngineID) async throws(AppError) -> [String] {
        discovery.append((endpoint, credential, engine))
        return ["fixture-model"]
    }

    func health(of id: EngineID, settings: SettingsSnapshot, forceRefresh: Bool) async -> EngineHealth {
        probes.append((id, forceRefresh))
        return .available
    }

    func cachedHealth(of id: EngineID) async -> EngineHealth? { nil }

    func check(executablePath: String?) async -> PaddleInstallation {
        paths.append(executablePath)
        return PaddleInstallation(isInstalled: true, version: "1.2", executablePath: executablePath, installCommand: "install fixture")
    }
}

@Suite("Engine settings probes")
struct CatalogWorkflowTests {
    private let dependencies = CatalogDependencies()

    private func catalog(
        engines: [FakeTranslationEngine] = [], skipped: [EngineID: SkipReason] = [:], recognition: [FakeRecognitionEngine] = [],
        generators: FakeTextGenerators? = nil, uploader: FakeImageUploader? = nil, codec: FakeImageCodec = FakeImageCodec()
    ) -> any EngineCatalogProviding {
        EngineCatalogService(
            translation: FakeTranslationEngines(engines, skipped: skipped), discovery: dependencies, health: dependencies,
            recognition: FakeRecognitionEngines(recognition), paddle: dependencies, generators: generators, uploader: uploader, encoder: codec
        )
    }

    @Test(arguments: [(LanguageCode.english, "你好，世界"), (LanguageCode("fr"), "Hello, world")])
    func probesTranslationWithTextInADifferentLanguage(target: LanguageCode, input: String) async throws {
        var settings = SettingsSnapshot()
        settings.languages.capture.target = .specific(target)
        let engine = FakeTranslationEngine(.mtran, behavior: .translate { _ in "translated" })
        let service = catalog(engines: [engine])
        #expect(service.translationEngines(settings: settings).map(\.id) == [.mtran])
        #expect(try await service.testTranslation(.mtran, settings: settings) == "translated")
        let batch = try #require(engine.calls.calls.first)
        #expect(batch.units.map(\.text) == [input])
        #expect(batch.from == nil)
        #expect(batch.to == target)
    }

    @Test func rejectedTranslationProbesReturnActionableErrors() async {
        let unavailable = FakeTranslationEngine(.appleTranslation, behavior: .translate { $0 })
        let invalid = FakeTranslationEngine(.mtran, behavior: .translate { _ in "" })
        let service = catalog(engines: [unavailable, invalid], skipped: [.appleTranslation: .unavailableOnThisOS])
        let settings = SettingsSnapshot()
        await #expect(throws: AppError.engine(.unavailableOnThisOS(.appleTranslation, minimum: OSVersion(26)))) {
            _ = try await service.testTranslation(.appleTranslation, settings: settings)
        }
        await #expect(throws: AppError.engine(.notConfigured(.deepl))) { _ = try await service.testTranslation(.deepl, settings: settings) }
        await #expect(throws: AppError.engine(.invalidResponse(.mtran, detail: "empty"))) {
            _ = try await service.testTranslation(.mtran, settings: settings)
        }
        #expect(unavailable.calls.calls.isEmpty)
        #expect(invalid.calls.count == 1)
    }

    @Test func analysisTestSendsSyntheticImageAndReturnsConfiguredModel() async throws {
        let model = FakeRecognitionEngine(.openAICompatible) { _ in RawRecognition(observations: []) }
        let error = AppError.recognition(.imageUnreadable)
        let failing = FakeRecognitionEngine(.visionText) { _ throws(AppError) in throw error }
        let service = catalog(recognition: [model, failing])
        var settings = SettingsSnapshot()
        settings.recognition.analysisConfigs[.openAI]?.model = "fixture-model"
        #expect(try await service.testAnalysis(.openAI, settings: settings) == "fixture-model")
        let probe = try #require(model.calls.calls.first)
        #expect(probe.image.pixelSize == PixelSize(width: 64, height: 32))
        #expect(TestImages.pixel(probe.image, x: 0, y: 0).r == 255)
        #expect(probe.hints.isEmpty && probe.detail == .lines)
        let snapshot = settings
        await #expect(throws: error) { _ = try await service.testAnalysis(.vision, settings: snapshot) }
        await #expect(throws: AppError.engine(.notConfigured(.gemini))) { _ = try await service.testAnalysis(.gemini, settings: snapshot) }
    }

    @Test func discoveryHealthAndInstallationUseSelectedConfiguration() async throws {
        let generator = FakeTextGenerator { $0 }
        let service = catalog(generators: FakeTextGenerators(generator))
        var settings = SettingsSnapshot()
        settings.recognition.paddle.executablePath = "/fixture/paddle"
        let endpoint = "https://models.example.invalid/v1"
        let credential = CredentialRef.engine(.openAICompatible)
        #expect(try await service.models(for: .openAICompatible, endpoint: endpoint, credential: credential) == ["fixture-model"])
        let discovery = try #require(dependencies.discovery.calls.first)
        #expect(discovery.0 == endpoint && discovery.1 == credential && discovery.2 == .openAICompatible)
        #expect(await service.health(of: .mtran, settings: settings, forceRefresh: true) == .available)
        #expect(dependencies.probes.calls.first?.0 == .mtran && dependencies.probes.calls.first?.1 == true)
        #expect(await service.paddleStatus(settings: settings).version == "1.2")
        #expect(dependencies.paths.calls == ["/fixture/paddle"])
        #expect(await service.generators(settings: settings) == [generator.descriptor])
        #expect(await catalog().generators(settings: settings).isEmpty)
        #expect(generator.calls.calls.isEmpty)
    }

    @Test func uploadProbeEncodesOnePixelAndRequiresProvider() async throws {
        let uploader = FakeImageUploader()
        let codec = FakeImageCodec()
        let service = catalog(uploader: uploader, codec: codec)
        let defaults = SettingsSnapshot()
        await #expect(throws: AppError.upload(.notConfigured)) { _ = try await service.testUpload(settings: defaults) }
        #expect(codec.encoded.calls.isEmpty)
        var settings = defaults
        settings.imageHost.provider = .hostPicGo
        let receipt = try await service.testUpload(settings: settings)
        #expect(receipt.provider == .hostPicGo)
        let name = try #require(uploader.objectNames.calls.first)
        #expect(name.hasPrefix("transframe-test-") && name.hasSuffix(".png"))
        #expect(receipt.url.lastPathComponent == name)
        #expect(codec.encoded.calls.first?.0 == .png && codec.encoded.calls.first?.1 == 1)
        #expect(codec.encodedSizes.calls == [PixelSize(width: 1, height: 1)])
    }
}

@Suite("Glossary correction")
struct GlossaryWorkflowTests {
    @Test func correctsOnlyTheEffectiveEngineAndRemembersInTheSourceApp() async throws {
        let fixture = DocumentWorkflowFixture()
        let box = DocumentRect(x: 0, y: 0, width: 20, height: 10)
        let segment = TextSegment(text: "Draft", revisedText: "Release", box: box)
        let second = TextSegment(text: "Other", box: box)
        var session = fixture.session(
            segments: [segment, second], context: CaptureContext(appBundleID: "fixture.editor", appName: "Editor", windowTitle: nil)
        )
        let operation = OperationID()
        let to = LanguageCode("fr")
        let stored = BilingualSegment(id: segment.id, source: "Draft", translated: "Brouillon", status: .translated, from: .english, to: to)
        let untouched = BilingualSegment(id: second.id, source: "Other", translated: "Autre", status: .translated, from: .english, to: to)
        session.translation = TranslationOutcome(
            operation: operation, routing: .compare([.mtran, .claude]),
            results: [EngineResult(id: .mtran, segments: [stored, untouched]), EngineResult(id: .claude, segments: [stored, untouched])],
            effective: .mtran
        )
        let id = await fixture.sessions.insert(session)
        let store = FakeGlossaryStore()
        let glossary = GlossaryService(store: store, sessions: fixture.sessions)
        try await glossary.correct(segment.id, in: id, expectedOperation: operation, translation: "Version", remember: false)
        #expect(try await glossary.entries().isEmpty)
        try await glossary.correct(segment.id, in: id, expectedOperation: operation, translation: "Publication", remember: true)
        let snapshot = try await fixture.sessions.snapshot(of: id)
        let segments = try #require(snapshot.translation?.effectiveResult?.segments)
        #expect(segments.first?.source == "Release" && segments.first?.translated == "Publication")
        #expect(segments.last == untouched)
        #expect(snapshot.translation?.results.last?.segments == [stored, untouched])
        #expect(snapshot.editRevision == 0)
        let entry = try #require(try await glossary.entries().first)
        #expect(entry.source == "Release" && entry.target == "Publication")
        #expect(entry.scope == .app(bundleID: "fixture.editor"))
        #expect(entry.from == .english && entry.to == to)
        await #expect(throws: AppError.cancelled) {
            try await glossary.correct(segment.id, in: id, expectedOperation: OperationID(), translation: "Stale", remember: true)
        }
        #expect(try await glossary.entries() == [entry])
        try await glossary.remove(entry.id)
        #expect(try await glossary.entries().isEmpty)
        try await glossary.save(entry)
        #expect(try await glossary.entries() == [entry])
        #expect(await store.version() == 3)
    }
}
