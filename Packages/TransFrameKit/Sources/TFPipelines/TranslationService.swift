import Foundation
import os
import TFDomain

/// Translation routing (SPEC §02 §8): ordered chain 1–5 with fallback, compare 2–4 in parallel, per-engine cache,
/// strict one-to-one mapping, cancellation without fallback, glossary and text privacy guard.
public struct TranslationService: TranslationWorkflow {
    private let engines: any TranslationEngineProviding
    private struct Reply: Sendable {
        let text: String?
        let detectedSource: LanguageCode?
    }

    private let cache: ResultCache<[Reply?]>
    private let limiter: EngineLimiter
    private let performance: any PerformanceRecording
    /// On-device language identification; nil when it is not confident. Screenshot lines already in the target language
    /// are not sent to any engine.
    private let languageOf: (@Sendable (String) -> LanguageCode?)?

    public init(
        engines: any TranslationEngineProviding, performance: any PerformanceRecording, languageOf: (@Sendable (String) -> LanguageCode?)? = nil
    ) {
        self.engines = engines
        self.languageOf = languageOf
        cache = ResultCache(maxCount: 256, maxBytes: 8 * 1024 * 1024) { $0.reduce(0) { $0 + ($1?.text?.utf8.count ?? 0) + 64 } }
        limiter = EngineLimiter(cloudLimit: 2)
        self.performance = performance
    }

    public func translate(_ job: TranslationJob, settings: SettingsSnapshot) -> AsyncThrowingStream<TranslationEvent, any Error> {
        translate(job, settings: settings, overridePrivacy: false)
    }

    /// `overridePrivacy` is set only by an explicit "undo and resend" (ADR-0010 §8).
    func translate(_ job: TranslationJob, settings: SettingsSnapshot, overridePrivacy: Bool) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outcome = try await run(job, settings: settings, overridePrivacy: overridePrivacy) { continuation.yield($0) }
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(_ job: TranslationJob, settings: SettingsSnapshot, overridePrivacy: Bool = false, emit: @escaping @Sendable (TranslationEvent) -> Void)
        async throws(AppError) -> TranslationOutcome
    {
        // Screenshot lines that already read in the target language keep their original and cost no engine call.
        guard job.scene == .screenshot, let languageOf else { return try await route(job, settings: settings, overridePrivacy: overridePrivacy, emit: emit) }
        var skipped: [SegmentID: BilingualSegment] = [:]
        for unit in job.units {
            guard let language = languageOf(unit.text), language.isSameLanguage(as: job.to) else { continue }
            skipped[unit.id] = BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .sameLanguageSkipped, from: language, to: job.to)
        }
        guard !skipped.isEmpty else { return try await route(job, settings: settings, overridePrivacy: overridePrivacy, emit: emit) }
        let rest = job.units.filter { skipped[$0.id] == nil }
        guard !rest.isEmpty else {
            let engine = job.routing.engines.first ?? .appleTranslation
            return TranslationOutcome(
                operation: job.operation, routing: job.routing, results: [EngineResult(id: engine, segments: job.units.compactMap { skipped[$0.id] })],
                effective: engine, target: job.to)
        }
        let restJob = TranslationJob(
            operation: job.operation, source: job.source, units: rest, from: job.from, to: job.to, routing: job.routing, prompt: job.prompt,
            glossary: job.glossary, context: job.context, tone: job.tone, cache: job.cache, scene: job.scene)
        var outcome = try await route(restJob, settings: settings, overridePrivacy: overridePrivacy, emit: emit)
        outcome = TranslationOutcome(
            operation: outcome.operation, routing: outcome.routing,
            results: outcome.results.map { result in
                guard !result.segments.isEmpty else { return result }
                let byID = Dictionary(result.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return EngineResult(
                    id: result.id, segments: job.units.compactMap { skipped[$0.id] ?? byID[$0.id] }, error: result.error, skipped: result.skipped,
                    duration: result.duration, fromCache: result.fromCache)
            },
            effective: outcome.effective, target: outcome.target, privacy: outcome.privacy)
        return outcome
    }

    private func route(_ job: TranslationJob, settings: SettingsSnapshot, overridePrivacy: Bool, emit: @escaping @Sendable (TranslationEvent) -> Void)
        async throws(AppError) -> TranslationOutcome
    {
        if Task.isCancelled { throw .cancelled }
        guard !job.units.isEmpty else { throw .translation(.noTranslatableText) }
        if let from = job.from, from.isSameLanguage(as: job.to) {
            let segments = job.units.map { BilingualSegment(id: $0.id, source: $0.text, translated: nil, status: .sameLanguageSkipped, from: from, to: job.to) }
            let engine = job.routing.engines.first ?? .appleTranslation
            return TranslationOutcome(
                operation: job.operation, routing: job.routing, results: [EngineResult(id: engine, segments: segments)], effective: engine,
                target: job.to)
        }
        switch job.routing {
        case .ordered(let ids):
            var results: [EngineResult] = []
            var failures: [EngineFailure] = []
            for id in ids.prefix(EngineRouting.maxOrdered) {
                if Task.isCancelled { throw .cancelled }
                let skip = await engines.skipReason(id, settings: settings)
                if Task.isCancelled { throw .cancelled }
                if let skip {
                    let result = EngineResult(id: id, skipped: skip)
                    results.append(result)
                    failures.append(
                        EngineFailure(
                            engine: id,
                            reason: .engine(skip == .unavailableOnThisOS ? .unavailableOnThisOS(id, minimum: OSVersion(26)) : .notConfigured(id))))
                    emit(.engineFinished(result))
                    continue
                }
                emit(.engineStarted(id))
                let run = await runEngine(id, job: job, settings: settings, overridePrivacy: overridePrivacy)
                if Task.isCancelled || run.result.error == .cancelled { throw .cancelled }
                let result = run.result
                emit(.engineFinished(result))
                results.append(result)
                if result.succeeded {
                    return TranslationOutcome(
                        operation: job.operation, routing: job.routing, results: results, effective: id, target: job.to, privacy: run.privacy)
                }
                if let error = result.error { failures.append(EngineFailure(engine: id, reason: error)) }
            }
            throw .translation(.allEnginesFailed(failures))
        case .compare(let ids):
            let configured = Array(ids.prefix(EngineRouting.compareRange.upperBound))
            let runs = await withTaskGroup(of: (Int, EngineRun).self) { group in
                for (index, id) in configured.enumerated() {
                    group.addTask {
                        if let skip = await engines.skipReason(id, settings: settings) {
                            return (index, EngineRun(result: EngineResult(id: id, skipped: skip), privacy: nil))
                        }
                        if Task.isCancelled { return (index, EngineRun(result: EngineResult(id: id, error: .cancelled), privacy: nil)) }
                        emit(.engineStarted(id))
                        return (index, await runEngine(id, job: job, settings: settings, overridePrivacy: overridePrivacy))
                    }
                }
                var collected: [(Int, EngineRun)] = []
                for await item in group {
                    emit(.engineFinished(item.1.result))
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if Task.isCancelled { throw .cancelled }
            let results = runs.map(\.result)
            guard let first = runs.first(where: \.result.succeeded) else {
                throw .translation(.allEnginesFailed(results.map { EngineFailure(engine: $0.id, reason: $0.error ?? .engine(.notConfigured($0.id))) }))
            }
            return TranslationOutcome(
                operation: job.operation, routing: job.routing, results: results, effective: first.result.id, target: job.to, privacy: first.privacy)
        }
    }

    /// One engine: cache → limiter → deadline → one retry for retryable errors → strict mapping.
    struct EngineRun: Sendable {
        let result: EngineResult
        let privacy: PrivacyReport?
    }

    func runEngine(_ id: EngineID, job: TranslationJob, settings: SettingsSnapshot, overridePrivacy: Bool) async -> EngineRun {
        guard let engine = engines.engine(id, settings: settings) else { return EngineRun(result: EngineResult(id: id, skipped: .unconfigured), privacy: nil) }
        let descriptor = engine.descriptor
        let start = ContinuousClock.now
        let guarded = PrivacyGuard.applies(to: descriptor.locality, settings: settings.privacy, overridden: overridePrivacy)
        let textPlan =
            guarded
            ? PrivacyGuard.protect(job.units, settings: settings.privacy)
            : PrivacyGuard.TextPlan(units: job.units, withheld: [], placeholders: [:], report: .notApplied)
        let glossaryEntries = job.glossary?.matched ?? []
        let usesPromptGlossary = descriptor.capabilities.contains(.glossary)
        var glossaryMaps: [SegmentID: [String: String]] = [:]
        var hits: [SegmentID: [GlossaryEntryID]] = [:]
        var sendUnits: [TranslationUnit] = []
        for unit in textPlan.units {
            hits[unit.id] = glossaryEntries.filter { GlossaryMatcher.contains(unit.text, $0) }.map(\.id)
            if usesPromptGlossary || glossaryEntries.isEmpty {
                sendUnits.append(unit)
            } else {
                let (text, map, _) = GlossaryMatcher.protect(unit.text, glossaryEntries)
                glossaryMaps[unit.id] = map
                sendUnits.append(TranslationUnit(id: unit.id, text: text, kind: unit.kind))
            }
        }
        let prompt = job.scene.map { scene in
            let template = settings.prompts.template(for: id, scene: scene)
            return PromptSnapshot(template: template, digest: CacheKey.digest([template]))
        } ?? job.prompt
        let glossary = usesPromptGlossary ? glossaryEntries.filter {
            !guarded || PrivacyGuard.sensitiveSpans(in: $0.source, settings: settings.privacy).isEmpty &&
                PrivacyGuard.sensitiveSpans(in: $0.target, settings: settings.privacy).isEmpty
        } : []
        let context = settings.privacy.sendContext ? job.context.map {
            TranslationContext(
                appName: PrivacyGuard.safeMetadata($0.appName, guarded: guarded, settings: settings.privacy),
                windowTitle: PrivacyGuard.safeMetadata($0.windowTitle, guarded: guarded, settings: settings.privacy)
            )
        } : nil
        let batch = TranslationBatch(
            units: sendUnits, from: job.from, to: job.to, prompt: descriptor.isLanguageModel ? prompt : nil,
            glossary: glossary, context: descriptor.isLanguageModel ? context : nil, tone: job.tone
        )
        let key = Self.cacheKey(batch, descriptor: descriptor, glossaryVersion: job.glossary?.version ?? 0)
        do {
            try Task.checkCancellation()
            let (replies, fromCache): ([Reply?], Bool)
            if batch.units.isEmpty {
                (replies, fromCache) = ([], false)
            } else {
                (replies, fromCache) = try await cache.value(for: key, force: job.cache == .forceRefresh) {
                    let translated = try await limiter.run(id, local: descriptor.locality == .onDevice) {
                        try await withRetry {
                            try await Deadline.run(descriptor.limits.timeout, engine: id) { try await engine.translate(batch) }
                        }
                    }
                    let byID = Dictionary(translated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let output = batch.units.map { unit in
                        byID[unit.id].map { Reply(text: $0.text, detectedSource: $0.detectedSource) }
                    }
                    if !output.contains(where: { reply in
                        guard let reply else { return false }
                        return reply.text.map { !TranslationCleanup.clean($0).isEmpty } == true ||
                            reply.detectedSource?.isSameLanguage(as: batch.to) == true
                    }) {
                        throw AppError.engine(.invalidResponse(id, detail: "empty translation"))
                    }
                    return output
                }
            }
            try Task.checkCancellation()
            let translated = zip(batch.units, replies).compactMap { unit, reply in
                reply.map { TranslatedUnit(id: unit.id, text: $0.text, detectedSource: $0.detectedSource) }
            }
            let segments = Self.map(
                job.units, translated: translated, to: job.to, from: job.from, withheld: textPlan.withheld,
                placeholders: textPlan.placeholders, glossary: glossaryMaps, hits: hits
            )
            let duration = ContinuousClock.now - start
            performance.record(
                PerformanceSample(
                    budget: fromCache ? Budget.cacheHit : Budget.translationEngine, duration: duration, engine: id.raw, fromCache: fromCache))
            let report =
                guarded
                ? textPlan.report : (overridePrivacy ? PrivacyReport(applied: false, redactedCount: 0, categories: [], overriddenByUser: true) : nil)
            return EngineRun(result: EngineResult(id: id, segments: segments, duration: duration, fromCache: fromCache), privacy: report)
        } catch {
            return EngineRun(result: EngineResult(id: id, error: AppError.from(error), duration: ContinuousClock.now - start), privacy: nil)
        }
    }

    private static func cacheKey(_ batch: TranslationBatch, descriptor: EngineDescriptor, glossaryVersion: Int) -> String {
        let settings = [
            descriptor.id.raw, descriptor.configDigest, batch.from?.bcp47 ?? "auto", batch.to.bcp47,
            batch.prompt?.digest ?? "", String(glossaryVersion), batch.context?.appName ?? "",
            batch.context?.windowTitle ?? "", batch.tone?.rawValue ?? "", String(Contracts.version)
        ]
        let terms = batch.glossary.flatMap { [$0.source, $0.target] }
        return CacheKey.digest(settings + [String(terms.count)] + terms + batch.units.map(\.text))
    }

    /// One-to-one with the job's units; missing → missingInResponse, never the source as a translation (SPEC §02 §8).
    static func map(
        _ units: [TranslationUnit], translated: [TranslatedUnit], to: LanguageCode, from: LanguageCode?, withheld: Set<SegmentID>,
        placeholders: [SegmentID: [String: String]], glossary: [SegmentID: [String: String]], hits: [SegmentID: [GlossaryEntryID]]
    ) -> [BilingualSegment] {
        let byID = Dictionary(translated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return units.map { unit in
            if withheld.contains(unit.id) {
                return BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .failed(.withheldByPrivacyGuard), from: from, to: to)
            }
            guard let result = byID[unit.id] else {
                return BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .failed(.missingInResponse), from: from, to: to)
            }
            let detected = result.detectedSource ?? from
            guard var text = result.text.map(TranslationCleanup.clean), !text.isEmpty else {
                if let detected, detected.isSameLanguage(as: to) {
                    return BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .sameLanguageSkipped, from: detected, to: to)
                }
                return BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .failed(.emptyOutput), from: detected, to: to)
            }
            text = PrivacyGuard.restore(text, glossary[unit.id] ?? [:])
            text = PrivacyGuard.restore(text, placeholders[unit.id] ?? [:])
            // A "translation" that only repeats the source (paths, names, text already in the target language) is not shown.
            if TranslationText.sameContent(text, unit.text) {
                return BilingualSegment(id: unit.id, source: unit.text, translated: nil, status: .sameLanguageSkipped, from: detected, to: to)
            }
            return BilingualSegment(
                id: unit.id, source: unit.text, translated: text, status: .translated, from: detected, to: to, glossaryHits: hits[unit.id] ?? [])
        }
    }

    private func withRetry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as AppError where error.isRetryable {
            if case .engine(.rateLimited(_, let after?)) = error {
                try await Task.sleep(for: min(after, .seconds(5)))
            } else {
                try await Task.sleep(for: .milliseconds(400))
            }
            return try await body()
        }
    }
}

/// Compares a translation with its source ignoring character width, spacing and punctuation (`一行）:` and `一行）：` are the same).
public enum TranslationText {
    public static func sameContent(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        return x.isEmpty || y.isEmpty
            ? a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines) : x == y
    }

    static func normalized(_ text: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !ignored.contains($0) }))
    }
}

/// Removes wrappers models add around translations (TRN-15).
public enum TranslationCleanup {
    public static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Translation:", "翻译：", "Translated text:", "译文："] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if t.count >= 2, let first = t.first, let last = t.last, (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}

/// Deadline via task-group race; timeouts and cancellation stay distinct (ADR-0004 §8).
public enum Deadline {
    public static func run<T: Sendable>(_ timeout: Duration, engine: EngineID, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppError.engine(.timedOut(engine))
            }
            guard let first = try await group.next() else { throw AppError.cancelled }
            group.cancelAll()
            return first
        }
    }
}

/// Per-engine concurrency: on-device backends run one at a time, cloud instances up to `cloudLimit` (SPEC §01 §6).
public actor EngineLimiter {
    private var running: [EngineID: Int] = [:]
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [EngineID: [Waiter]] = [:]
    private let cloudLimit: Int

    public init(cloudLimit: Int) { self.cloudLimit = max(cloudLimit, 1) }

    public func run<T: Sendable>(_ id: EngineID, local: Bool, _ body: @Sendable () async throws -> T) async throws -> T {
        let limit = local ? 1 : cloudLimit
        try Task.checkCancellation()
        if running[id, default: 0] >= limit {
            let token = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id, default: []].append(Waiter(token: token, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(token, engine: id) }
            }
        } else {
            running[id, default: 0] += 1
        }
        defer { release(id) }
        try Task.checkCancellation()
        return try await body()
    }

    private func release(_ id: EngineID) {
        if let waiter = waiters[id]?.first {
            waiters[id]?.removeFirst()
            waiter.continuation.resume()
        } else {
            running[id, default: 1] -= 1
        }
    }

    private func cancelWaiter(_ token: UUID, engine: EngineID) {
        guard let index = waiters[engine]?.firstIndex(where: { $0.token == token }),
              let waiter = waiters[engine]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
