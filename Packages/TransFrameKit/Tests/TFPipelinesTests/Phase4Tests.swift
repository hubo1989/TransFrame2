import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

private func job(_ texts: [String], routing: EngineRouting, from: LanguageCode? = .english, to: LanguageCode = .simplifiedChinese, glossary: [GlossaryEntry] = []) -> TranslationJob {
    TranslationJob(
        operation: OperationID(), source: .plainText(purpose: .popup), units: texts.map { TranslationUnit(text: $0) }, from: from, to: to,
        routing: routing, glossary: glossary.isEmpty ? nil : GlossarySnapshot(version: 1, matched: glossary)
    )
}

@Suite("Translation routing (SPEC §02 §8, TRN-07…TRN-10)")
struct TranslationRoutingTests {
    let settings = SettingsSnapshot()

    @Test func orderedFallsBackAfterFailure() async throws {
        let a = FakeTranslationEngine(.mtran, behavior: .fail(.engine(.unreachable(.mtran))))
        let b = FakeTranslationEngine(.deepl, behavior: .translate { "译:" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([a, b]), performance: FakePerformanceRecorder())
        let outcome = try await service.run(job(["Hello"], routing: .ordered([.mtran, .deepl])), settings: settings) { _ in }
        #expect(outcome.effective == .deepl)
        #expect(outcome.results.count == 2)
        #expect(outcome.effectiveResult?.segments.first?.translated == "译:Hello")
        #expect(a.calls.count == 2) // one retry for a retryable error
    }

    @Test func unconfiguredEnginesAreSkippedNotCalled() async throws {
        let b = FakeTranslationEngine(.deepl, behavior: .translate { $0 + "!" })
        let service = TranslationService(engines: FakeTranslationEngines([b], skipped: [.google: .unconfigured]), performance: FakePerformanceRecorder())
        let outcome = try await service.run(job(["x"], routing: .ordered([.google, .deepl])), settings: settings) { _ in }
        #expect(outcome.results.first?.skipped == .unconfigured)
        #expect(outcome.effective == .deepl)
    }

    @Test func allFailIsAnError() async {
        let a = FakeTranslationEngine(.mtran, behavior: .fail(.engine(.authenticationFailed(.mtran))))
        let service = TranslationService(engines: FakeTranslationEngines([a]), performance: FakePerformanceRecorder())
        await #expect(throws: AppError.self) { try await service.run(job(["x"], routing: .ordered([.mtran])), settings: settings) { _ in } }
    }

    @Test func cancellationDoesNotFallBack() async {
        let slow = FakeTranslationEngine(.mtran, behavior: .delay(.seconds(2)) { $0 })
        let next = FakeTranslationEngine(.deepl, behavior: .translate { $0 })
        let service = TranslationService(engines: FakeTranslationEngines([slow, next]), performance: FakePerformanceRecorder())
        let task = Task { try await service.run(job(["x"], routing: .ordered([.mtran, .deepl])), settings: settings) { _ in } }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.result
        #expect(next.calls.count == 0)
    }

    @Test func compareRunsAllAndPicksFirstSuccessInOrder() async throws {
        let a = FakeTranslationEngine(.mtran, behavior: .fail(.engine(.unreachable(.mtran))))
        let b = FakeTranslationEngine(.deepl, behavior: .translate { "B" + $0 })
        let c = FakeTranslationEngine(.google, behavior: .translate { "C" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([a, b, c]), performance: FakePerformanceRecorder())
        let outcome = try await service.run(job(["x"], routing: .compare([.mtran, .deepl, .google])), settings: settings) { _ in }
        #expect(outcome.results.map(\.id) == [.mtran, .deepl, .google])
        #expect(outcome.effective == .deepl)
        #expect(outcome.results[2].segments.first?.translated == "Cx")
    }

    @Test func sameLanguageJobSkipsEngines() async throws {
        let a = FakeTranslationEngine(.mtran, behavior: .translate { $0 })
        let service = TranslationService(engines: FakeTranslationEngines([a]), performance: FakePerformanceRecorder())
        let outcome = try await service.run(job(["你好"], routing: .ordered([.mtran]), from: .simplifiedChinese), settings: settings) { _ in }
        #expect(outcome.effectiveResult?.segments.first?.status == .sameLanguageSkipped)
        #expect(a.calls.count == 0)
    }

    @Test func secondRequestHitsCache() async throws {
        let a = FakeTranslationEngine(.mtran, behavior: .translate { $0 + "?" })
        let service = TranslationService(engines: FakeTranslationEngines([a]), performance: FakePerformanceRecorder())
        let j = job(["cache me"], routing: .ordered([.mtran]))
        _ = try await service.run(j, settings: settings) { _ in }
        let second = try await service.run(j, settings: settings) { _ in }
        #expect(a.calls.count == 1)
        #expect(second.effectiveResult?.fromCache == true)
    }

    @Test func glossaryIsAppliedForEnginesWithoutGlossarySupport() async throws {
        let a = FakeTranslationEngine(.mtran, behavior: .translate { $0.replacingOccurrences(of: "is", with: "是") })
        let service = TranslationService(engines: FakeTranslationEngines([a]), performance: FakePerformanceRecorder())
        let term = GlossaryEntry(source: "TransFrame", target: "译框", to: .simplifiedChinese)
        let outcome = try await service.run(job(["TransFrame is good"], routing: .ordered([.mtran]), glossary: [term]), settings: settings) { _ in }
        let segment = try #require(outcome.effectiveResult?.segments.first)
        #expect(segment.translated == "译框 是 good")
        #expect(segment.glossaryHits == [term.id])
        #expect(a.calls.calls.first?.units.first?.text.contains("⟦G1⟧") == true)
    }
}

@Suite("Strict mapping")
struct MappingTests {
    @Test func missingAndEmptyAreFailures() {
        let units = [TranslationUnit(text: "a"), TranslationUnit(text: "b"), TranslationUnit(text: "c")]
        let mapped = TranslationService.map(
            units, translated: [TranslatedUnit(id: units[0].id, text: "A"), TranslatedUnit(id: units[2].id, text: "  ")],
            to: .simplifiedChinese, from: .english, withheld: [], placeholders: [:], glossary: [:], hits: [:]
        )
        #expect(mapped[0].status == .translated)
        #expect(mapped[1].status == .failed(.missingInResponse))
        #expect(mapped[1].translated == nil)
        #expect(mapped[2].status == .failed(.emptyOutput))
    }

    @Test func cleanupStripsWrappers() {
        #expect(TranslationCleanup.clean("Translation: \"你好\"") == "你好")
        #expect(TranslationCleanup.clean("  plain ") == "plain")
    }
}

@Suite("Privacy guard (ADR-0010)")
struct PrivacyGuardTests {
    @Test func classifierRules() {
        #expect(SensitiveTextClassifier.luhn("4111111111111111"))
        #expect(!SensitiveTextClassifier.luhn("4111111111111112"))
        #expect(SensitiveTextClassifier.chineseIDChecksum("11010519491231002X"))
        #expect(SensitiveTextClassifier.matches(in: "key sk-proj-abcdefghijklmnopqrstuvwxyz0123").first?.category == .apiKey)
        #expect(SensitiveTextClassifier.matches(in: "mail me: a.b@example.com").contains { $0.category == .email })
        #expect(SensitiveTextClassifier.matches(in: "Total 1,234.56 on 2025-01-02").filter { $0.category == .paymentCard }.isEmpty)
    }

    @Test func textChannelWithholdsAndPlaceholders() {
        var settings = PrivacySettings()
        settings.redactedCategories = [.apiKey, .email]
        let full = TranslationUnit(text: "sk-proj-abcdefghijklmnopqrstuvwxyz0123")
        let partial = TranslationUnit(text: "Write to a.b@example.com today")
        let plan = PrivacyGuard.protect([full, partial], settings: settings)
        #expect(plan.withheld == [full.id])
        #expect(plan.units.count == 1)
        #expect(plan.units[0].text == "Write to ⟦P1⟧ today")
        #expect(PrivacyGuard.restore("写信给 ⟦P1⟧", plan.placeholders[partial.id] ?? [:]) == "写信给 a.b@example.com")
        #expect(plan.report.applied)
    }

    @Test func appliesOnlyToCloudByDefault() {
        let settings = PrivacySettings()
        #expect(PrivacyGuard.applies(to: .cloud, settings: settings, overridden: false))
        #expect(!PrivacyGuard.applies(to: .onDevice, settings: settings, overridden: false))
        #expect(!PrivacyGuard.applies(to: .cloud, settings: settings, overridden: true))
    }
}

@Suite("Recognition normalizer (OCR-13, RES-01)")
struct NormalizerTests {
    private func normalize(_ observations: [RawObservation], sent: SentPayload = .nothing) -> AnalysisResult {
        RecognitionNormalizer.normalize(
            RawRecognition(observations: observations, sent: sent), region: DocumentRect(x: 10, y: 20, width: 400, height: 300),
            session: SessionID(), inputRevision: 0, fingerprint: ContentHash(sha256: Data()),
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
    }

    @Test func filtersNoiseKeepsNumbersAndOffsetsRegion() {
        let result = normalize([
            RawObservation(text: "Hello", box: FrameRect(x: 0, y: 0, width: 50, height: 12)),
            RawObservation(text: "•", box: FrameRect(x: 0, y: 40, width: 5, height: 5)),
            RawObservation(text: "2025-01-02", box: FrameRect(x: 0, y: 80, width: 80, height: 12)),
            RawObservation(text: "blurry", box: FrameRect(x: 0, y: 120, width: 50, height: 12), confidence: 0.1),
        ])
        #expect(result.segments.map(\.text) == ["Hello", "2025-01-02"])
        #expect(result.segments[0].box.minX == 10)
        #expect(result.segments[0].box.minY == 20)
        #expect(Set(result.excluded.map(\.reason)) == [.noise, .lowConfidence])
        #expect(result.segments[1].translatability == .keepOriginal(.numeric))
    }

    @Test func promptLeakageFromModelsIsExcluded() {
        let result = normalize([RawObservation(text: "Here is the JSON with bbox", box: FrameRect(x: 0, y: 0, width: 50, height: 12))], sent: .image)
        #expect(result.segments.isEmpty)
        #expect(result.excluded.first?.reason == .promptLeakage)
    }

    @Test func fragmentsOnOneLineMergeAndLinesFormParagraphs() {
        let result = normalize([
            RawObservation(text: "Hello", box: FrameRect(x: 0, y: 0, width: 40, height: 12)),
            RawObservation(text: "world", box: FrameRect(x: 46, y: 1, width: 40, height: 12)),
            RawObservation(text: "second line", box: FrameRect(x: 0, y: 16, width: 90, height: 12)),
            RawObservation(text: "far away", box: FrameRect(x: 0, y: 200, width: 60, height: 12)),
        ])
        #expect(result.segments.map(\.text) == ["Hello world", "second line", "far away"])
        #expect(result.blocks.count == 2)
        #expect(result.segments[0].parent == result.segments[1].parent)
        #expect(StructureValidation.issues(segments: result.segments, blocks: result.blocks).isEmpty)
    }

    @Test func tilesCoverWithOverlap() {
        let tiles = ImageTiling.tiles(width: 4500, height: 1000)
        #expect(tiles.count == 3)
        #expect(tiles.map { Int($0.minX) } == [0, 1952, 3904])
        #expect(tiles.last?.maxX == 4500)
    }
}

@Suite("Caches, history, actions")
struct SupportTests {
    @Test func cacheEvictsLeastRecentlyUsed() async {
        let cache = ResultCache<String>(maxCount: 2, maxBytes: 1_000) { $0.utf8.count }
        await cache.store("a", for: "1")
        await cache.store("b", for: "2")
        _ = await cache.value(for: "1")
        await cache.store("c", for: "3")
        #expect(await cache.value(for: "2") == nil)
        #expect(await cache.value(for: "1") == "a")
    }

    @Test func cacheCoalescesInFlight() async throws {
        let cache = ResultCache<Int>(maxCount: 4, maxBytes: 100) { _ in 1 }
        let counter = CallLog<Int>()
        async let first = cache.value(for: "k", force: false) { counter.append(1); try await Task.sleep(for: .milliseconds(100)); return 7 }
        try await Task.sleep(for: .milliseconds(20))
        async let second = cache.value(for: "k", force: false) { counter.append(2); return 8 }
        let (a, b) = try await (first, second)
        #expect(a.0 == 7 && b.0 == 7)
        #expect(counter.count == 1)
    }

    @Test func retentionKeepsFavorites() {
        var entries = (0..<5).map { HistoryEntry(kind: .textTranslation, source: "\($0)", result: "r\($0)", isFavorite: $0 == 4) }
        HistoryRetention.trim(&entries, limit: 3)
        #expect(entries.count == 3)
        #expect(entries.contains { $0.isFavorite })
        #expect(entries.map(\.source) == ["0", "1", "4"])
    }

    @Test func csvEscapes() {
        #expect(HistoryExporter.csvField("a,b") == "\"a,b\"")
        #expect(HistoryExporter.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        let csv = HistoryExporter.render([HistoryEntry(kind: .textTranslation, source: "x\ny", result: "z")], as: .csv)
        #expect(csv.hasPrefix("createdAt,kind"))
        #expect(csv.contains("\"x\ny\""))
    }

    @Test func inMemoryStoreMergesDuplicatesKeepingFavorite() async throws {
        let store = InMemoryHistoryStore()
        var first = HistoryEntry(kind: .textTranslation, source: "s", result: "r")
        first.isFavorite = true
        _ = try await store.add(first, limit: 10)
        _ = try await store.add(HistoryEntry(kind: .textTranslation, source: "s", result: "r"), limit: 10)
        let page = try await store.page(HistoryQuery())
        #expect(page.entries.count == 1)
        #expect(page.entries[0].isFavorite)
    }

    @Test func smartActionsFromText() {
        let result = AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: DocumentRect(x: 0, y: 0, width: 10, height: 10),
            segments: [TextSegment(text: "Visit https://example.com or mail hi@example.com", box: DocumentRect(x: 0, y: 0, width: 10, height: 10))],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        let kinds = SmartActionDeriver().actions(for: result).map(\.kind)
        #expect(kinds.contains(.openLink(URL(string: "https://example.com")!)))
        #expect(kinds.contains(.composeEmail("hi@example.com")))
    }

    @Test func lineNumbersStrippedFromCode() {
        #expect(SmartActionDeriver.stripLineNumbers("1 let a = 1\n2 let b = 2\n3 print(a)") == "let a = 1\nlet b = 2\nprint(a)")
    }

    @Test func scrollShiftFindsOverlap() {
        let previous = (0..<100).map { UInt64($0) }
        let current = (30..<130).map { UInt64($0) }
        #expect(ScrollCaptureService.scrollShift(previous: previous, current: current) == 30)
        #expect(ScrollCaptureService.scrollShift(previous: previous, current: (500..<600).map { UInt64($0) }) == nil)
    }

    @Test func glossaryProtectUsesLongestFirst() {
        let a = GlossaryEntry(source: "Trans", target: "T", to: .simplifiedChinese)
        let b = GlossaryEntry(source: "TransFrame", target: "译框", to: .simplifiedChinese)
        let (text, map, hits) = GlossaryMatcher.protect("TransFrame rocks", [a, b])
        #expect(text == "⟦G1⟧ rocks")
        #expect(map["⟦G1⟧"] == "译框")
        #expect(hits == [b.id])
    }
}
