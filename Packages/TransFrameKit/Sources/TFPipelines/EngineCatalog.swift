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
        let results = try await engine.translate(TranslationBatch(units: [unit], from: nil, to: target))
        guard let text = results.first?.text, !text.isEmpty else { throw .engine(.invalidResponse(id, detail: "empty")) }
        return text
    }

    /// Connection test for the screenshot analysis engine (OCR-14): lists models for model endpoints, recognizes a blank
    /// probe image for local engines.
    public func testAnalysis(_ provider: AnalysisProvider, settings: SettingsSnapshot) async throws(AppError) -> String {
        if provider.isLanguageModel, let config = settings.recognition.config(for: provider) {
            let models = try await discovery.models(endpoint: config.endpoint, credential: config.credential, engine: provider.engineID)
            return models.contains(config.model) || models.isEmpty ? config.model : "\(config.model) (\(models.count))"
        }
        guard let engine = recognition.analysisEngine(provider, settings: settings) else { throw .engine(.notConfigured(provider.engineID)) }
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32)); return context.makeImage() }()
        else { throw .render(.contextUnavailable) }
        _ = try await engine.recognize(PixelImage(cgImage: image, scale: 1), hints: [], detail: .lines)
        return engine.descriptor.id.raw
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
        return try await uploader.upload(data, fileName: "transframe-test-\(Int(Date().timeIntervalSince1970)).png", contentType: "image/png", settings: settings.imageHost)
    }
}
