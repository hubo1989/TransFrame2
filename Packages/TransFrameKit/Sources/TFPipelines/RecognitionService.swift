import CoreGraphics
import Foundation
import os
import TFDomain

/// Recognition (SPEC §02 §7): safe input → privacy guard (cloud) → cache → tiling → engine → normalize.
/// Falls back to on-device OCR when a model returns nothing usable (OCR-12).
public struct RecognitionService: RecognitionWorkflow {
    private let sessions: DocumentSessionStore
    private let render: RenderService
    private let engines: any RecognitionEngineProviding
    private let guardian: PrivacyGuard
    private let cache: ResultCache<AnalysisResult>
    private let performance: any PerformanceRecording

    public init(sessions: DocumentSessionStore, render: RenderService, engines: any RecognitionEngineProviding, guardian: PrivacyGuard, performance: any PerformanceRecording) {
        self.sessions = sessions
        self.render = render
        self.engines = engines
        self.guardian = guardian
        cache = ResultCache(maxCount: 64, maxBytes: 8 * 1024 * 1024) { $0.segments.reduce(512) { $0 + $1.text.utf8.count + 160 } }
        self.performance = performance
    }

    public func recognize(_ request: AnalysisRequest, settings: SettingsSnapshot) async throws(AppError) -> AnalysisResult {
        try await recognize(request, settings: settings, provider: nil, overridePrivacy: false).result
    }

    struct Outcome: Sendable {
        let result: AnalysisResult
        let privacy: PrivacyReport?
        let input: PixelImage
    }

    func recognize(_ request: AnalysisRequest, settings: SettingsSnapshot, provider: AnalysisProvider?, overridePrivacy: Bool) async throws(AppError) -> Outcome {
        let session = try await sessions.snapshot(of: request.session)
        guard session.analysisInputRevision == request.inputRevision else { throw .cancelled }
        let visible = session.visibleRect
        let region = (request.region ?? visible).integralOutward
        guard visible.contains(region) || region == visible else { throw .recognition(.regionOutOfBounds) }

        guard let engine = provider.map({ engines.analysisEngine($0, settings: settings) }) ?? engines.engine(request.engine, settings: settings) else {
            throw .engine(request.engine == .visionDocument ? .unavailableOnThisOS(request.engine, minimum: OSVersion(26)) : .notConfigured(request.engine))
        }
        let descriptor = engine.descriptor
        // Outbound requests always use the safe input (user redactions burned in, SPEC §01 §9.1).
        let policy: AnalysisInputPolicy = descriptor.locality == .onDevice ? request.input : .safe
        var input = try await render.image(for: request.session, purpose: .analysisInput(policy))
        if region != visible {
            let crop = CGRect(x: region.minX - visible.minX, y: region.minY - visible.minY, width: region.width, height: region.height)
            guard let cropped = input.cgImage.cropping(to: crop) else { throw .recognition(.regionOutOfBounds) }
            input = PixelImage(cgImage: cropped, scale: input.scale)
        }
        var privacy: PrivacyReport?
        if PrivacyGuard.applies(to: descriptor.locality, settings: settings.privacy, overridden: overridePrivacy) {
            let start = ContinuousClock.now
            let (masked, report) = try await guardian.protect(input, settings: settings.privacy)
            performance.record(PerformanceSample(budget: Budget.privacyGuard, duration: .now - start))
            input = masked
            privacy = report
        } else if overridePrivacy {
            privacy = PrivacyReport(applied: false, redactedCount: 0, categories: [], overriddenByUser: true)
        }

        let fingerprint = CacheKey.fingerprint(input)
        let key = CacheKey.digest([
            fingerprint.hex, descriptor.id.raw, descriptor.configDigest, request.languageHints.map(\.bcp47).joined(separator: ","),
            request.detail.rawValue, "\(RecognitionNormalizer.preprocessingVersion)", "\(AnalysisResult.currentSchemaVersion)", "\(Contracts.version)",
        ])
        let start = ContinuousClock.now
        let frozenInput = input
        let frozenPrivacy = privacy
        do {
            var (result, fromCache) = try await cache.value(for: key, force: request.cache == .forceRefresh) {
                let raw = try await Self.run(engine, image: frozenInput, hints: request.languageHints, detail: request.detail)
                let provenance = Provenance(
                    engine: descriptor.id, configDigest: descriptor.configDigest, locality: descriptor.locality,
                    duration: ContinuousClock.now - start, sent: descriptor.locality == .onDevice ? .nothing : raw.sent, privacy: frozenPrivacy
                )
                return RecognitionNormalizer.normalize(
                    raw, region: region, session: request.session, inputRevision: request.inputRevision, fingerprint: fingerprint, provenance: provenance
                )
            }
            result = AnalysisResult(
                id: AnalysisResultID(), session: request.session, inputRevision: request.inputRevision, inputFingerprint: result.inputFingerprint,
                region: result.region, segments: result.segments, blocks: result.blocks, excluded: result.excluded, languages: result.languages,
                provenance: Provenance(
                    engine: result.provenance.engine, configDigest: result.provenance.configDigest, locality: result.provenance.locality,
                    fromCache: fromCache, fallbackFrom: result.provenance.fallbackFrom, duration: fromCache ? ContinuousClock.now - start : result.provenance.duration,
                    sent: fromCache ? .nothing : result.provenance.sent, privacy: privacy
                )
            )
            performance.record(PerformanceSample(
                budget: fromCache ? Budget.cacheHit : (descriptor.id == .visionText ? Budget.visionRecognition : Budget.recognitionEngine),
                duration: ContinuousClock.now - start, engine: descriptor.id.raw, fromCache: fromCache
            ))
            // OCR-12: an empty or prompt-only model result falls back to on-device OCR.
            if result.segments.isEmpty, descriptor.id != .visionText, provider?.isLanguageModel == true,
               let vision = engines.engine(.visionText, settings: settings) {
                let raw = try await Self.run(vision, image: frozenInput, hints: request.languageHints, detail: .lines)
                let provenance = Provenance(engine: .visionText, configDigest: vision.descriptor.configDigest, locality: .onDevice, fallbackFrom: descriptor.id, duration: .now - start, sent: result.provenance.sent, privacy: privacy)
                result = RecognitionNormalizer.normalize(raw, region: region, session: request.session, inputRevision: request.inputRevision, fingerprint: fingerprint, provenance: provenance)
            }
            return Outcome(result: result, privacy: privacy, input: frozenInput)
        } catch {
            throw AppError.from(error)
        }
    }

    /// Large inputs to size-limited engines are split into tiles with overlap and merged (OCR-10).
    static func run(_ engine: any RecognitionEngine, image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws -> RawRecognition {
        let maxEdge = engine.descriptor.limits.maxImageEdge
        guard let maxEdge, max(image.cgImage.width, image.cgImage.height) > maxEdge else {
            return try await engine.recognize(image, hints: hints, detail: detail)
        }
        var parts: [(CGRect, RawRecognition)] = []
        for tile in ImageTiling.tiles(width: image.cgImage.width, height: image.cgImage.height, maxEdge: maxEdge) {
            try Task.checkCancellation()
            guard let crop = image.cgImage.cropping(to: tile) else { continue }
            parts.append((tile, try await engine.recognize(PixelImage(cgImage: crop, scale: image.scale), hints: hints, detail: detail)))
        }
        return ImageTiling.merge(parts)
    }
}
