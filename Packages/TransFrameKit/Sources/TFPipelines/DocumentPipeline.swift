import CoreGraphics
import Foundation
import os
import TFDomain

/// Recognize / translate actions on a session (INP-05/06, EDT-10…13, CAP-21, N-01…N-05, N-16, N-17, AI-01/02/04).
/// Orchestration lives here, never in views; history is written after success (ADR-0009 §4).
public struct DocumentPipelineService: DocumentPipelineWorkflow {
    private let sessions: DocumentSessionStore
    private let recognition: RecognitionService
    private let translation: TranslationService
    private let history: any HistoryWorkflow
    private let thumbnails: any Thumbnailing
    private let glossary: (any GlossaryStoring)?
    private let codes: (any CodeDetecting)?
    private let detector: (any SensitiveContentDetecting)?
    private let preferredLanguages: @Sendable () -> [String]

    public init(
        sessions: DocumentSessionStore, recognition: RecognitionService, translation: TranslationService, history: any HistoryWorkflow,
        thumbnails: any Thumbnailing, glossary: (any GlossaryStoring)?, codes: (any CodeDetecting)?, detector: (any SensitiveContentDetecting)?,
        preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) {
        self.sessions = sessions
        self.recognition = recognition
        self.translation = translation
        self.history = history
        self.thumbnails = thumbnails
        self.glossary = glossary
        self.codes = codes
        self.detector = detector
        self.preferredLanguages = preferredLanguages
    }

    // MARK: Recognize

    public func recognize(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error> {
        stream(id, kind: .recognition) { operation, revision, emit in
            emit(.stage(.recognizing))
            let settings = options.settings
            let request = AnalysisRequest(
                operation: operation, session: id, inputRevision: revision, engine: settings.recognition.ocrEngine,
                languageHints: settings.languages.capture.source.map { [$0] } ?? [], detail: .lines, cache: options.cache
            )
            let outcome = try await recognition.recognize(request, settings: settings, provider: nil, overridePrivacy: options.overridePrivacyGuard)
            try await sessions.writeAnalysis(outcome.result, kind: .recognition, operation: operation)
            if let privacy = outcome.privacy { emit(.privacy(privacy)) }
            emit(.recognized(outcome.result))
        }
    }

    // MARK: Translate

    public func translate(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error> {
        stream(id, kind: .translation) { operation, revision, emit in
            let settings = options.settings
            var session = try await sessions.snapshot(of: id)
            var analysisInput: PixelImage?
            var privacy: PrivacyReport?
            if session.analysis == nil || options.cache == .forceRefresh {
                emit(.stage(.recognizing))
                let provider = settings.recognition.analysisProvider
                let structured = settings.ai.structuredRecognition && (provider == .visionDocument || provider.isLanguageModel)
                let request = AnalysisRequest(
                    operation: operation, session: id, inputRevision: revision, engine: provider.engineID,
                    languageHints: settings.languages.capture.source.map { [$0] } ?? [], detail: structured ? .structured : .lines, cache: options.cache
                )
                let outcome = try await recognition.recognize(request, settings: settings, provider: provider, overridePrivacy: options.overridePrivacyGuard)
                try await sessions.writeAnalysis(outcome.result, kind: .translation, operation: operation)
                analysisInput = outcome.input
                privacy = outcome.privacy
                if let privacy { emit(.privacy(privacy)) }
                emit(.recognized(outcome.result))
                session = try await sessions.snapshot(of: id)
            }
            guard let analysis = session.analysis else { throw AppError.cancelled }
            let units = analysis.segments.filter { $0.translatability.isTranslatable }
                .map { TranslationUnit(id: $0.id, text: $0.effectiveText, kind: $0.kind) }
            guard !units.isEmpty else { throw AppError.translation(.noTranslatableText) }
            emit(.stage(.translating))
            let target = options.target ?? settings.languages.capture.target.resolved(preferred: preferredLanguages())
            let job = try await makeJob(operation: operation, source: .analysis(id, analysis.id), units: units, from: settings.languages.capture.source,
                                        to: target, settings: settings, scene: .screenshot, context: session.context)
            var outcome: TranslationOutcome?
            for try await event in translation.translate(job, settings: settings, overridePrivacy: options.overridePrivacyGuard) {
                emit(.translation(event))
                if case .finished(let finished) = event { outcome = finished }
            }
            guard var outcome else { throw AppError.cancelled }
            if outcome.privacy == nil { outcome.privacy = privacy }
            try await sessions.writeTranslation(outcome, to: id, inputRevision: revision, kind: .translation, operation: operation)
            if settings.presentation.defaultDisplay == .inPlace, !session.presentation.showsTranslationOverlay {
                var presentation = session.presentation
                presentation.showsTranslationOverlay = true
                presentation.overlayMode = settings.presentation.overlayMode
                let updated = presentation
                await sessions.update(id) { $0.presentation = updated }
            }
            await recordHistory(session: session, analysis: analysis, outcome: outcome, input: analysisInput, settings: settings)
        }
    }

    func makeJob(
        operation: OperationID, source: TranslationSource, units: [TranslationUnit], from: LanguageCode?, to: LanguageCode,
        settings: SettingsSnapshot, scene: TranslationScene, context: CaptureContext?, tone: ToneStyle? = nil, routing: EngineRouting? = nil
    ) async throws(AppError) -> TranslationJob {
        let routing = routing ?? settings.engines.routing
        let template = settings.prompts.template(for: routing.engines.first ?? .openAICompatible, scene: scene)
        let prompt = PromptSnapshot(template: template, digest: CacheKey.digest([template]))
        var glossarySnapshot: GlossarySnapshot?
        if let glossary {
            let entries = (try? await glossary.entries()) ?? []
            let matched = GlossaryMatcher.matches(entries, in: units.map(\.text), from: from, to: to, app: context?.appBundleID)
            glossarySnapshot = GlossarySnapshot(version: await glossary.version(), matched: matched)
        }
        let translationContext = settings.privacy.sendContext ? context.map { TranslationContext(appName: $0.appName, windowTitle: $0.windowTitle) } : nil
        return TranslationJob(
            operation: operation, source: source, units: units, from: from, to: to, routing: routing, prompt: prompt,
            glossary: glossarySnapshot, context: translationContext, tone: tone, cache: .normal
        )
    }

    private func recordHistory(session: DocumentSession, analysis: AnalysisResult, outcome: TranslationOutcome, input: PixelImage?, settings: SettingsSnapshot) async {
        guard let segments = outcome.effectiveResult?.segments else { return }
        let source = segments.map(\.source).joined(separator: "\n")
        let result = segments.map(\.displayText).joined(separator: "\n")
        let thumbnail = input.flatMap { thumbnails.thumbnail(of: $0, maxEdge: HistoryEntry.thumbnailMaxEdge, maxBytes: HistoryEntry.thumbnailMaxBytes) }
        let entry = HistoryEntry(
            kind: .screenshotTranslation, source: source, result: result, from: segments.first?.from ?? settings.languages.capture.source,
            to: outcome.target, engine: outcome.effective, thumbnail: thumbnail, tags: session.suggestedName.map { [$0] } ?? []
        )
        await history.record(entry, settings: settings)
    }

    // MARK: Other actions

    public func cancel(_ id: SessionID) async {
        await sessions.cancelOperations(on: id, kinds: [.recognition, .translation, .privacyScan])
    }

    public func selectEffectiveEngine(_ engine: EngineID, in id: SessionID) async throws(AppError) {
        try await sessions.setEffectiveEngine(engine, in: id)
    }

    public func restoreExcluded(_ segment: SegmentID, in id: SessionID) async throws(AppError) {
        try await sessions.restoreExcluded(segment, in: id)
    }

    /// Local derivation from the result, plus QR codes from the analysis input (AI-02).
    public func smartActions(for id: SessionID) async -> [SmartAction] {
        guard let session = try? await sessions.snapshot(of: id), let analysis = session.analysis else { return [] }
        var actions = SmartActionDeriver().actions(for: analysis)
        if let codes {
            for code in await codes.codes(in: session.baseImage) {
                if let url = URL(string: code.payload), url.scheme != nil {
                    actions.append(SmartAction(id: "qr-\(code.payload.hashValue)", kind: .openQRCode(url), target: .session))
                }
            }
        }
        return actions
    }

    /// Smart mosaic: local detection on the safe input; findings become privacy mosaics in one transaction (INP-08).
    public func smartMosaic(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> Int {
        guard let detector else { return 0 }
        let session = try await sessions.snapshot(of: id)
        let visible = session.visibleRect
        let findings = try await detector.detect(in: session.baseImage)
        let block = max(12 * session.baseImage.scale, 8)
        let mosaics = findings.filter { $0.confidence >= 0.5 }.compactMap { finding -> Annotation? in
            let rect = DocumentRect(finding.box.raw).intersection(visible)
            return rect.map { .mosaic(MosaicAnnotation(rect: $0, blockSize: block, isPrivacy: true)) }
        }
        guard let transaction = EditTransaction.insertAll(mosaics, into: session, label: "undo.smartMosaic") else { return 0 }
        try await sessions.apply(transaction, to: id)
        return mosaics.count
    }

    // MARK: Plumbing

    private func stream(
        _ id: SessionID, kind: SessionTaskKind,
        body: @escaping @Sendable (OperationID, Int, @escaping @Sendable (DocumentPipelineEvent) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<DocumentPipelineEvent, any Error> {
        AsyncThrowingStream { continuation in
            let sessions = sessions
            let starter = Task {
                do {
                    let (operation, revision) = try await sessions.beginOperation(kind, on: id)
                    let work = Task {
                        do {
                            continuation.yield(.stage(.preparing))
                            try await body(operation, revision) { continuation.yield($0) }
                            continuation.yield(.finished)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: AppError.from(error))
                        }
                        await sessions.finishOperation(kind, operation: operation, on: id)
                    }
                    await sessions.attach(work, kind: kind, operation: operation, on: id)
                    continuation.onTermination = { _ in work.cancel() }
                } catch {
                    continuation.finish(throwing: AppError.from(error))
                }
            }
            continuation.onTermination = { _ in starter.cancel() }
        }
    }
}

/// Pure smart-action derivation (AI-02): tables, formulas, code, links, emails, dates.
public struct SmartActionDeriver: SmartActionDeriving {
    public init() {}

    public func actions(for result: AnalysisResult) -> [SmartAction] {
        var actions: [SmartAction] = []
        for block in result.blocks {
            if case .table = block.kind {
                let cells = result.segments.filter { $0.parent == block.id }.compactMap { s in s.kind.tableCell.map { (s, $0) } }
                guard !cells.isEmpty else { continue }
                let rows = (cells.map { $0.1.row }.max() ?? 0) + 1, cols = (cells.map { $0.1.column }.max() ?? 0) + 1
                var grid = Array(repeating: Array(repeating: "", count: cols), count: rows)
                for (segment, ref) in cells { grid[ref.row][ref.column] = segment.effectiveText.replacingOccurrences(of: "\n", with: " ") }
                let markdown = ([ "| " + grid[0].joined(separator: " | ") + " |", "|" + String(repeating: " --- |", count: cols)]
                    + grid.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }).joined(separator: "\n")
                let csv = grid.map { $0.map(HistoryExporter.csvField).joined(separator: ",") }.joined(separator: "\n")
                actions.append(SmartAction(id: "table-md-\(block.id)", kind: .copyTableAsMarkdown, target: .block(block.id), payload: markdown))
                actions.append(SmartAction(id: "table-csv-\(block.id)", kind: .copyTableAsCSV, target: .block(block.id), payload: csv))
            }
        }
        for segment in result.segments {
            switch segment.kind {
            case .formula(let latex):
                actions.append(SmartAction(id: "latex-\(segment.id)", kind: .copyFormulaAsLaTeX, target: .segments([segment.id]), payload: latex ?? segment.text))
            case .code:
                actions.append(SmartAction(id: "code-\(segment.id)", kind: .copyCode, target: .segments([segment.id]), payload: Self.stripLineNumbers(segment.text)))
            default: break
            }
        }
        let text = result.plainText
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.date.rawValue) {
            var seen = Set<String>()
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url {
                    if url.scheme == "mailto" {
                        let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                        if seen.insert("m:" + address).inserted { actions.append(SmartAction(id: "mail-\(address)", kind: .composeEmail(address), target: .session)) }
                    } else if seen.insert("u:" + url.absoluteString).inserted {
                        actions.append(SmartAction(id: "link-\(url.absoluteString)", kind: .openLink(url), target: .session))
                    }
                } else if let date = match.date, seen.insert("d:\(date.timeIntervalSince1970)").inserted {
                    let duration = match.duration > 0 ? match.duration : 3600
                    let title = Range(match.range, in: text).map { String(text[$0]) } ?? ""
                    actions.append(SmartAction(id: "event-\(date.timeIntervalSince1970)", kind: .addEvent(DateInterval(start: date, duration: duration)), target: .session, payload: title))
                }
            }
        }
        return actions
    }

    static func stripLineNumbers(_ code: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let numbered = lines.filter { $0.range(of: #"^\s*\d+[\s:|.]"#, options: .regularExpression) != nil }.count
        guard numbered * 2 > lines.count else { return code }
        return lines.map { $0.replacingOccurrences(of: #"^\s*\d+[\s:|.]\s?"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }
}
