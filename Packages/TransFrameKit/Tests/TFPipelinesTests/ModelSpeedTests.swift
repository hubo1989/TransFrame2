import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

/// Engine provider whose behaviour depends on the configured model, like a real multi-model endpoint.
private struct PerModelEngines: TranslationEngineProviding {
    let delays: [String: Duration]
    let failing: Set<String>

    func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] { [] }
    func skipReason(_ id: EngineID, settings: SettingsSnapshot) async -> SkipReason? { nil }
    func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any TranslationEngine)? {
        let model = settings.engines.config(for: id).model
        if failing.contains(model) { return FakeTranslationEngine(id, behavior: .fail(.engine(.unreachable(id)))) }
        return FakeTranslationEngine(id, behavior: .delay(delays[model] ?? .zero) { "[\(model)] " + $0 })
    }
}

@Suite("Model speed test")
struct ModelSpeedTests {
    private func service(_ engines: PerModelEngines) -> EngineCatalogService {
        let deps = CatalogDependencies()
        return EngineCatalogService(
            translation: engines, discovery: deps, health: deps, recognition: FakeRecognitionEngines([]), paddle: deps,
            generators: nil, uploader: nil, encoder: FakeImageCodec()
        )
    }

    @Test func ranksSuccessesFastestFirstAndKeepsFailures() async {
        let engines = PerModelEngines(delays: ["slow": .milliseconds(300), "fast": .milliseconds(20), "mid": .milliseconds(120)], failing: ["broken"])
        var results: [ModelSpeedResult] = []
        for await result in service(engines).benchmarkModels(.openAICompatible, models: ["slow", "broken", "fast", "mid"], settings: SettingsSnapshot()) {
            results.append(result)
        }
        #expect(results.count == 4)
        let ranked = ModelSpeedResult.ranked(results)
        #expect(ranked.map(\.model) == ["fast", "mid", "slow", "broken"])
        #expect(ranked.last?.duration == nil)
        if case .success(_, let sample) = ranked[0].outcome { #expect(sample.hasPrefix("[fast]")) } else { Issue.record("fast should succeed") }
    }

    @Test func eachModelUsesItsOwnConfiguration() async {
        let engines = PerModelEngines(delays: [:], failing: [])
        var samples: [String: String] = [:]
        for await result in service(engines).benchmarkModels(.openAICompatible, models: ["a", "b"], settings: SettingsSnapshot()) {
            if case .success(_, let sample) = result.outcome { samples[result.model] = sample }
        }
        #expect(samples["a"]?.hasPrefix("[a]") == true)
        #expect(samples["b"]?.hasPrefix("[b]") == true)
    }
}
