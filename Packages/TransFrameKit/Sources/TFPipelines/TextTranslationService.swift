import Foundation
import TFDomain

/// Selected-text translation and translate-and-insert (TXT-01…TXT-16, N-05, AI-06).
public struct TextTranslationService: TextTranslationWorkflow {
    private let capturer: any SelectedTextCapturing
    private let inserter: any TextInserting
    private let pasteboard: any PasteboardAccessing
    private let translation: TranslationService
    private let pipeline: DocumentPipelineService
    private let history: any HistoryWorkflow
    private let generators: (any TextGeneratorProviding)?
    private let preferredLanguages: @Sendable () -> [String]

    public init(
        capturer: any SelectedTextCapturing, inserter: any TextInserting, pasteboard: any PasteboardAccessing, translation: TranslationService,
        pipeline: DocumentPipelineService, history: any HistoryWorkflow, generators: (any TextGeneratorProviding)?,
        preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) {
        self.capturer = capturer
        self.inserter = inserter
        self.pasteboard = pasteboard
        self.translation = translation
        self.pipeline = pipeline
        self.history = history
        self.generators = generators
        self.preferredLanguages = preferredLanguages
    }

    public func translateSelection(settings: SettingsSnapshot) async throws(AppError) -> TextTranslationResult {
        let selection = try await capturer.captureSelection(bindTarget: false)
        return try await translate(text: selection.text, anchor: selection.anchor, settings: settings)
    }

    public func translate(text: String, anchor: QuartzRect?, settings: SettingsSnapshot) async throws(AppError) -> TextTranslationResult {
        let pair = settings.languages.capture
        let to = pair.target.resolved(preferred: preferredLanguages())
        let outcome = try await run(text, from: pair.source, to: to, scene: .textSelection, purpose: .popup, tone: nil, settings: settings)
        await record(text, outcome: outcome, from: pair.source, to: to, kind: .textTranslation, settings: settings)
        return TextTranslationResult(source: text, outcome: outcome, from: pair.source, to: to, anchor: anchor)
    }

    public func translateAndInsert(tone: ToneStyle?, polishOnly: Bool, settings: SettingsSnapshot) -> AsyncThrowingStream<InsertProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var translated: String?
                do {
                    continuation.yield(.capturing)
                    let selection = try await capturer.captureSelection(bindTarget: true)
                    continuation.yield(.captured(anchor: selection.anchor))
                    continuation.yield(.translating)
                    let pair = settings.languages.insert
                    let to = pair.target.resolved(preferred: preferredLanguages())
                    let text = try await replacement(
                        selection.text, from: pair.source, to: to, tone: tone, polishOnly: polishOnly, settings: settings
                    )
                    if Task.isCancelled { throw AppError.cancelled }
                    translated = text
                    continuation.yield(.inserting)
                    guard let target = selection.target else { throw AppError.textInput(.targetChanged) }
                    let method = try await inserter.insert(text, into: target)
                    await history.record(
                        HistoryEntry(kind: .insertTranslation, source: selection.text, result: text, from: pair.source, to: to), settings: settings
                    )
                    continuation.yield(.inserted(method))
                    continuation.finish()
                } catch {
                    let appError = AppError.from(error)
                    // Insertion failed after translating: keep the result on the clipboard (TXT-09).
                    if let translated, appError != .cancelled {
                        do {
                            try await pasteboard.write(.string(translated))
                            continuation.yield(.copiedToClipboard(appError))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish(throwing: appError)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func canPolish(settings: SettingsSnapshot) async -> Bool {
        await generators?.generator(for: settings.ai.generationEngine, settings: settings) != nil
    }

    private func replacement(
        _ source: String, from: LanguageCode?, to: LanguageCode, tone: ToneStyle?, polishOnly: Bool, settings: SettingsSnapshot
    ) async throws(AppError) -> String {
        let text = if polishOnly { source } else { try await translatedText(source, from: from, to: to, tone: tone, settings: settings) }
        guard polishOnly || tone != nil else { return text }
        guard let generator = await generators?.generator(for: settings.ai.generationEngine, settings: settings) else {
            if polishOnly { throw .engine(.notConfigured(.appleFoundation)) }
            return text
        }
        do {
            return try await PrivacyGuard.generate(
                polishOnly ? .polish : .rewrite(tone ?? .formal), input: text, using: generator, settings: settings.privacy
            )
        } catch {
            if error == .cancelled || Task.isCancelled { throw .cancelled }
            if polishOnly { throw error }
            return text
        }
    }

    private func translatedText(_ text: String, from: LanguageCode?, to: LanguageCode, tone: ToneStyle?, settings: SettingsSnapshot)
        async throws(AppError) -> String
    {
        let outcome = try await run(text, from: from, to: to, scene: .translateAndInsert, purpose: .insert, tone: tone, settings: settings)
        guard let segments = outcome.effectiveResult?.segments, !segments.isEmpty else { throw .translation(.noTranslatableText) }
        guard segments.allSatisfy({ segment in
            switch segment.status {
            case .translated, .sameLanguageSkipped, .keptOriginal, .failed(.withheldByPrivacyGuard): true
            default: false
            }
        }) else { throw .translation(.noTranslatableText) }
        return segments.map(\.displayText).joined(separator: "\n\n")
    }

    private func run(
        _ text: String, from: LanguageCode?, to: LanguageCode, scene: TranslationScene, purpose: TextPurpose, tone: ToneStyle?, settings: SettingsSnapshot
    ) async throws(AppError) -> TranslationOutcome {
        let start = ContinuousClock.now
        let units = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { TranslationUnit(text: $0) }
        guard !units.isEmpty else { throw .textInput(.noSelection) }
        let job = try await pipeline.makeJob(
            operation: OperationID(), source: .plainText(purpose: purpose), units: units, from: from, to: to, settings: settings,
            scene: scene, context: nil, tone: tone
        )
        var outcome: TranslationOutcome?
        do {
            for try await event in translation.translate(job, settings: settings) {
                if case .finished(let finished) = event { outcome = finished }
            }
        } catch {
            throw AppError.from(error)
        }
        _ = start
        guard let outcome else { throw .cancelled }
        return outcome
    }

    private func record(
        _ text: String, outcome: TranslationOutcome, from: LanguageCode?, to: LanguageCode, kind: HistoryKind, settings: SettingsSnapshot
    ) async {
        guard let segments = outcome.effectiveResult?.segments else { return }
        await history.record(
            HistoryEntry(
                kind: kind, source: text, result: segments.map(\.displayText).joined(separator: "\n\n"), from: segments.first?.from ?? from, to: to,
                engine: outcome.effective),
            settings: settings
        )
    }
}
