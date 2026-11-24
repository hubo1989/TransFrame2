import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("Perf R-04 R-05 R-09 O-02 O-03")
struct PipelinePerfTests {
    private func analysis(_ count: Int) -> AnalysisResult {
        AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: DocumentRect(x: 0, y: 0, width: 3840, height: 2160),
            segments: (0..<count).map { i in
                TextSegment(
                    text: "Line \(i) of text", box: DocumentRect(x: Double(i % 4) * 900, y: Double(i / 4) * 80, width: 800, height: 30),
                    style: SegmentStyleHint(fontSize: 24))
            },
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
    }

    @Test func layoutPlan100Segments() async {
        let a = analysis(100)
        let translations = a.segments.map {
            BilingualSegment(id: $0.id, source: $0.text, translated: "第 \($0.text) 行译文", status: .translated, from: .english, to: .simplifiedChinese)
        }
        let layout = TranslationLayoutPlanner(measurer: FakeTextMeasurer())
        await PerfProbe.measure("R-05") {
            _ = layout.layout(
                analysis: a, translations: translations, mode: .belowOriginal, offsetX: 0, offsetY: 0,
                canvas: CanvasRect(x: 0, y: 0, width: 3840, height: 2160), scale: 2)
        }
    }

    @Test func textPipelineOverheadWithZeroLatencyEngine() async throws {
        let engine = FakeTranslationEngine(.mtran, behavior: .translate { "T:" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder())
        var n = 0
        try await PerfProbe.measure("R-04") {
            n += 1
            let job = TranslationJob(
                operation: OperationID(), source: .plainText(purpose: .popup), units: [TranslationUnit(text: "Hello \(n)")], from: .english,
                                     to: .simplifiedChinese, routing: .ordered([.mtran]))
            _ = try await service.run(job, settings: SettingsSnapshot()) { _ in }
        }
    }

    @Test func cacheHit() async throws {
        let engine = FakeTranslationEngine(.mtran, behavior: .translate { $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder())
        let job = TranslationJob(
            operation: OperationID(), source: .plainText(purpose: .popup), units: [TranslationUnit(text: "cached")], from: .english,
            to: .simplifiedChinese, routing: .ordered([.mtran]))
        _ = try await service.run(job, settings: SettingsSnapshot()) { _ in }
        try await PerfProbe.measure("R-09") { _ = try await service.run(job, settings: SettingsSnapshot()) { _ in } }
    }

    @Test func historyFirstPageAndSearch() async throws {
        let store = InMemoryHistoryStore()
        for i in 0..<500 { _ = try await store.add(HistoryEntry(kind: .textTranslation, source: "source \(i)", result: "result \(i)"), limit: 1000) }
        try await PerfProbe.measure("O-02") { _ = try await store.page(HistoryQuery()) }
        var query = HistoryQuery()
        query.text = "result 42"
        try await PerfProbe.measure("O-03") { _ = try await store.page(query) }
    }
}
