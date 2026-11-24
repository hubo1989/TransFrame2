import CoreGraphics
import Foundation
import TFDomain

/// Read-only engine information and connection tests for the settings pages (OCR-06, OCR-14, TRN-11, TRN-12, N-08, AI-08).
public struct EngineCatalogService: EngineCatalogProviding {
    private let translation: any TranslationEngineProviding
    private let discovery: any ModelDiscovering
    private let health: any EngineHealthProbing
    private let recognition: any RecognitionEngineProviding
    private let paddle: any PaddleInstallationChecking
    private let generators: (any TextGeneratorProviding)?
    private let uploader: (any ImageUploading)?
    private let encoder: any ImageEncoding

    public init(
        translation: any TranslationEngineProviding, discovery: any ModelDiscovering, health: any EngineHealthProbing,
        recognition: any RecognitionEngineProviding, paddle: any PaddleInstallationChecking, generators: (any TextGeneratorProviding)?,
        uploader: (any ImageUploading)?, encoder: any ImageEncoding
    ) {
        self.translation = translation
        self.discovery = discovery
        self.health = health
        self.recognition = recognition
        self.paddle = paddle
        self.generators = generators
        self.uploader = uploader
        self.encoder = encoder
    }

    public func translationEngines(settings: SettingsSnapshot) -> [EngineDescriptor] { translation.descriptors(for: settings) }

    public func health(of id: EngineID, settings: SettingsSnapshot, forceRefresh: Bool) async -> EngineHealth {
        await health.health(of: id, settings: settings, forceRefresh: forceRefresh)
    }

    /// Explicit user action: may use a metered engine once (TRN-12 "测试翻译").
    public func testTranslation(_ id: EngineID, settings: SettingsSnapshot) async throws(AppError) -> String {
        if let skip = await translation.skipReason(id, settings: settings) {
            throw skip == .unavailableOnThisOS ? .engine(.unavailableOnThisOS(id, minimum: OSVersion(26))) : .engine(.notConfigured(id))
        }
        guard let engine = translation.engine(id, settings: settings) else { throw .engine(.notConfigured(id)) }
        let target = settings.languages.capture.target.resolved(preferred: Locale.preferredLanguages)
        let unit = TranslationUnit(text: target.isSameLanguage(as: .english) ? "你好，世界" : "Hello, world")
        let batch = TranslationBatch(units: [unit], from: nil, to: target)
        // A hung model must not leave the settings page "testing" forever.
        let results: [TranslatedUnit]
        do {
            results = try await Deadline.run(Self.testTimeout, engine: id) { try await engine.translate(batch) }
        } catch {
            throw AppError.from(error)
        }
        guard let text = results.first?.text, !text.isEmpty else { throw .engine(.invalidResponse(id, detail: "empty")) }
        return text
    }

    public static let testTimeout: Duration = .seconds(20)
    public static let speedTestConcurrency = 3
    static let speedSample = ["Good morning.", "The meeting moved to Friday at 3 pm.", "Open Settings to change the shortcut."]

    public func benchmarkModels(_ id: EngineID, models: [String], settings: SettingsSnapshot) -> AsyncStream<ModelSpeedResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: ModelSpeedResult.self) { group in
                    var pending = models[...]
                    for _ in 0..<min(Self.speedTestConcurrency, pending.count) {
                        let next = pending.removeFirst()
                        group.addTask { await measure(id, model: next, settings: settings) }
                    }
                    for await result in group {
                        continuation.yield(result)
                        if Task.isCancelled { group.cancelAll(); break }
                        if let next = pending.first {
                            pending.removeFirst()
                            group.addTask { await measure(id, model: next, settings: settings) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Full response time of a fixed three-sentence translation through the same engine path the app uses.
    func measure(_ id: EngineID, model: String, settings: SettingsSnapshot) async -> ModelSpeedResult {
        var settings = settings
        if let index = settings.engines.compatibleInstances.firstIndex(where: { $0.engineID == id }) {
            settings.engines.compatibleInstances[index].config.model = model
        } else {
            var config = settings.engines.config(for: id)
            config.model = model
            settings.engines.builtins[id] = config
        }
        guard let engine = translation.engine(id, settings: settings) else {
            return ModelSpeedResult(model: model, outcome: .failure(.engine(.notConfigured(id))))
        }
        let resolved = settings.languages.capture.target.resolved(preferred: Locale.preferredLanguages)
        let target = resolved.isSameLanguage(as: .english) ? LanguageCode.simplifiedChinese : resolved
        let units = Self.speedSample.map { TranslationUnit(text: $0) }
        let batch = TranslationBatch(units: units, from: .english, to: target)
        let start = ContinuousClock.now
        do {
            let output = try await Deadline.run(Self.testTimeout, engine: id) { try await engine.translate(batch) }
            let elapsed = ContinuousClock.now - start
            let texts = output.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard texts.count == units.count, zip(texts, Self.speedSample).contains(where: { $0 != $1 }) else {
                return ModelSpeedResult(model: model, outcome: .failure(.engine(.invalidResponse(id, detail: "incomplete"))))
            }
            return ModelSpeedResult(model: model, outcome: .success(duration: elapsed, sample: texts[1]))
        } catch {
            return ModelSpeedResult(model: model, outcome: .failure(AppError.from(error)))
        }
    }

    /// Explicit image request to verify the configured model supports screenshot recognition.
    public func testAnalysis(_ provider: AnalysisProvider, settings: SettingsSnapshot) async throws(AppError) -> String {
        guard let engine = recognition.analysisEngine(provider, settings: settings) else { throw .engine(.notConfigured(provider.engineID)) }
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = {
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32)); return context.makeImage()
            }()
        else { throw .render(.contextUnavailable) }
        let probe = PixelImage(cgImage: image, scale: 1)
        do {
            _ = try await Deadline.run(engine.descriptor.limits.timeout, engine: engine.descriptor.id) {
                try await engine.recognize(probe, hints: [], detail: .lines)
            }
        } catch {
            throw AppError.from(error)
        }
        return settings.recognition.config(for: provider)?.model ?? engine.descriptor.id.raw
    }

    public func models(for id: EngineID, endpoint: String, credential: CredentialRef?) async throws(AppError) -> [String] {
        try await discovery.models(endpoint: endpoint, credential: credential, engine: id)
    }

    public func paddleStatus(settings: SettingsSnapshot) async -> PaddleInstallation {
        await paddle.check(executablePath: settings.recognition.paddle.executablePath)
    }

    public func generators(settings: SettingsSnapshot) async -> [EngineDescriptor] {
        await generators?.availableGenerators(settings: settings) ?? []
    }

    /// Uploads a 1 × 1 PNG to verify the image host settings (N-08).
    public func testUpload(settings: SettingsSnapshot) async throws(AppError) -> UploadReceipt {
        guard let uploader, settings.imageHost.provider != nil else { throw .upload(.notConfigured) }
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixel = context.makeImage() else { throw .render(.contextUnavailable) }
        let data = try encoder.encode(PixelImage(cgImage: pixel, scale: 1), format: .png, quality: 1)
        return try await uploader.upload(
            data, fileName: "transframe-test-\(Int(Date().timeIntervalSince1970)).png", contentType: "image/png", settings: settings.imageHost)
    }
}
