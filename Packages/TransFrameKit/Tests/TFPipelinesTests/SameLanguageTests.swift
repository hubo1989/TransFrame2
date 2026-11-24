import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("Same-language lines")
struct SameLanguageTests {
    private func job(_ texts: [String], scene: TranslationScene?) -> TranslationJob {
        TranslationJob(
            source: .plainText(purpose: .popup), units: texts.map { TranslationUnit(text: $0) }, from: nil, to: .simplifiedChinese,
            routing: .ordered([.openAICompatible]), scene: scene)
    }

    /// Han text counts as Chinese, everything else as English (stands in for NLLanguageRecognizer).
    private let languageOf: @Sendable (String) -> LanguageCode? = { text in
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? .simplifiedChinese : .english
    }

    @Test func screenshotLinesAlreadyInTheTargetLanguageAreNotSentAndNotShown() async throws {
        let engine = FakeTranslationEngine(.openAICompatible, locality: .cloud, behavior: .translate { "译：" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder(), languageOf: languageOf)
        let request = job(["同步 SPEC 里美化的描述（INP-07）：", "d with code 0", "设置"], scene: .screenshot)
        let outcome = try await service.run(request, settings: SettingsSnapshot()) { _ in }
        #expect(engine.calls.calls.flatMap(\.units).map(\.text) == ["d with code 0"])
        let segments = try #require(outcome.effectiveResult?.segments)
        #expect(segments.map(\.id) == request.units.map(\.id))
        #expect(segments.map(\.status) == [.sameLanguageSkipped, .translated, .sameLanguageSkipped])
        #expect(segments.map(\.translated) == [nil, "译：d with code 0", nil])
    }

    @Test func allLinesInTheTargetLanguageNeedNoEngine() async throws {
        let engine = FakeTranslationEngine(.openAICompatible, locality: .cloud, behavior: .translate { "译：" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder(), languageOf: languageOf)
        let outcome = try await service.run(job(["你好", "世界"], scene: .screenshot), settings: SettingsSnapshot()) { _ in }
        #expect(engine.calls.calls.isEmpty)
        #expect(outcome.effectiveResult?.segments.allSatisfy { $0.status == .sameLanguageSkipped } == true)
    }

    @Test func selectedTextIsStillTranslatedWhateverItsLanguage() async throws {
        let engine = FakeTranslationEngine(.openAICompatible, locality: .cloud, behavior: .translate { "译：" + $0 })
        let service = TranslationService(engines: FakeTranslationEngines([engine]), performance: FakePerformanceRecorder(), languageOf: languageOf)
        _ = try await service.run(job(["你好"], scene: .textSelection), settings: SettingsSnapshot()) { _ in }
        #expect(engine.calls.count == 1)
    }

    @Test func aTranslationThatRepeatsTheSourceIsNotShown() {
        let units = [TranslationUnit(text: "试，同步 SPEC 里美化的描述（INP-07 和内容参数一行）:"), TranslationUnit(text: "/tmp/tf2-shots/scan-mid.png")]
        let mapped = TranslationService.map(
            units,
            translated: [
                TranslatedUnit(id: units[0].id, text: "试，同步 SPEC 里美化的描述（INP-07 和内容参数一行）："),
                TranslatedUnit(id: units[1].id, text: " /tmp/tf2-shots/scan-mid.png "),
            ],
            to: .simplifiedChinese, from: nil, withheld: [], placeholders: [:], glossary: [:], hits: [:])
        #expect(mapped.map(\.status) == [.sameLanguageSkipped, .sameLanguageSkipped])
        #expect(mapped.allSatisfy { $0.translated == nil })
        #expect(TranslationText.sameContent("一行）:", "一行）："))
        #expect(!TranslationText.sameContent("View image", "查看图像"))
        #expect(!TranslationText.sameContent("a", "A"))
    }
}
