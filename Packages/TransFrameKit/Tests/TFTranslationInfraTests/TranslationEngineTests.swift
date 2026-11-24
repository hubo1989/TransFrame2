import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
import TFNetworkInfra
@testable import TFTranslationInfra

@Suite("Translation engines")
struct TranslationEngineTests {
    @Test func llmParserToleratesFences() {
        let parsed = LLMResponseParser.translations(from: "```json\n[{\"id\":\"1\",\"translation\":\"你好\"},{\"id\":2,\"translation\":\"世界\"}]\n```")
        #expect(parsed == ["1": "你好", "2": "世界"])
        #expect(LLMResponseParser.translations(from: "sorry").isEmpty)
    }

    @Test func llmEngineMapsByIDAndLeavesMissingNil() async throws {
        let transport = FakeHTTPTransport()
        transport.onAny(json: #"{"choices":[{"message":{"content":"[{\"id\":\"2\",\"translation\":\"B\"}]"},"finish_reason":"stop"}]}"#)
        let client = LLMClient(wire: .openAIChat, endpoint: "http://localhost:1234/v1", model: "m", engine: .openAICompatible, transport: transport) { () throws(AppError) in nil }
        let descriptor = EngineDescriptor(id: .openAICompatible, roles: [.translation], name: .userDefined("x"), locality: .onDevice, configDigest: "")
        let units = [TranslationUnit(text: "a"), TranslationUnit(text: "b")]
        let result = try await LLMTranslationEngine(descriptor: descriptor, client: client).translate(
            TranslationBatch(units: units, from: .english, to: .simplifiedChinese))
        #expect(result.map(\.text) == [nil, "B"])
        #expect(result.map(\.id) == units.map(\.id))
    }

    @Test func batchingRespectsCharacterLimit() {
        let units = (0..<5).map { _ in TranslationUnit(text: String(repeating: "x", count: 40)) }
        #expect(LLMBatching.chunks(units, maxCharacters: 100).map(\.count) == [2, 2, 1])
    }

    @Test func languageCodes() {
        #expect(DeepLEngine.code(.simplifiedChinese, target: true) == "ZH-HANS")
        #expect(DeepLEngine.code(.english, target: false) == "EN")
        #expect(BaiduEngine.code(LanguageCode("ja")) == "jp")
        #expect(MTranLanguage.code(LanguageCode("fr")) == "fr")
    }

    @Test func promptFillsVariables() {
        let batch = TranslationBatch(
            units: [], from: .english, to: .simplifiedChinese,
            prompt: PromptSnapshot(template: "From {source_language} to {target_language}. {glossary}", digest: ""),
                                     glossary: [GlossaryEntry(source: "a", target: "b", to: .simplifiedChinese)])
        let system = LLMPrompt.system(batch: batch)
        #expect(system.contains("From English to Chinese"))
        #expect(system.contains("a → b"))
    }
}
