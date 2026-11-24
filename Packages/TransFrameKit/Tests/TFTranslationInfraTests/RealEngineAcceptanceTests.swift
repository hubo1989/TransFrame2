import Foundation
import Testing
import TFDomain
import TFNetworkInfra
@testable import TFTranslationInfra

/// Real-engine acceptance (SPEC §06 R rows). Runs only through `Scripts/acceptance.sh`, which reads the key from the Keychain at run
/// time and passes it in the environment of this process only. Nothing is logged or written.
@Suite("Real engine acceptance", .enabled(if: ProcessInfo.processInfo.environment["TF_ACCEPT_ENDPOINT"] != nil))
struct RealEngineAcceptanceTests {
    let env = ProcessInfo.processInfo.environment

    func client() -> LLMClient {
        let key = env["TF_ACCEPT_KEY"]
        let wire: LLMWire = env["TF_ACCEPT_API"] == "responses" ? .openAIResponses : .openAIChat
        return LLMClient(wire: wire, endpoint: env["TF_ACCEPT_ENDPOINT"] ?? "", model: env["TF_ACCEPT_MODEL"] ?? "", engine: .openAICompatible,
                         transport: URLSessionTransport()) { () throws(AppError) in key }
    }

    @Test func listsModels() async throws {
        let models = try await client().listModels()
        #expect(!models.isEmpty)
    }

    @Test func translatesBatchOneToOne() async throws {
        let descriptor = EngineDescriptor(id: .openAICompatible, roles: [.translation], name: .userDefined("acceptance"), locality: .cloud,
                                          capabilities: [.batch, .segmentIDs, .glossary], configDigest: "acceptance")
        let units = ["Good morning.", "The invoice is due on Friday.", "Open Settings to change the shortcut."].map { TranslationUnit(text: $0) }
        let start = ContinuousClock.now
        let result = try await LLMTranslationEngine(descriptor: descriptor, client: client())
            .translate(TranslationBatch(units: units, from: .english, to: .simplifiedChinese))
        let elapsed = ContinuousClock.now - start
        #expect(result.map(\.id) == units.map(\.id))
        #expect(result.allSatisfy { ($0.text ?? "").contains(where: { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }) })
        print("TF_ACCEPT translate 3 units: \(elapsed)")
    }

    /// Optional: `TF_ACCEPT_MODELS=a,b,c` times the same three-sentence batch on each model (what Settings › Speed Test does).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TF_ACCEPT_MODELS"] != nil))
    func speedOfModels() async throws {
        let names = (env["TF_ACCEPT_MODELS"] ?? "").split(separator: ",").map(String.init)
        let descriptor = EngineDescriptor(id: .openAICompatible, roles: [.translation], name: .userDefined("acceptance"), locality: .cloud,
                                          capabilities: [.batch, .segmentIDs], configDigest: "acceptance")
        for name in names {
            let key = env["TF_ACCEPT_KEY"]
            let client = LLMClient(wire: .openAIChat, endpoint: env["TF_ACCEPT_ENDPOINT"] ?? "", model: name, engine: .openAICompatible,
                                   transport: URLSessionTransport()) { () throws(AppError) in key }
            let units = ["Good morning.", "The meeting moved to Friday at 3 pm.", "Open Settings to change the shortcut."].map { TranslationUnit(text: $0) }
            let start = ContinuousClock.now
            do {
                let out = try await LLMTranslationEngine(descriptor: descriptor, client: client)
                    .translate(TranslationBatch(units: units, from: .english, to: .simplifiedChinese))
                print("TF_ACCEPT speed \(name): \(ContinuousClock.now - start) → \(out.compactMap(\.text).joined(separator: " | "))")
            } catch {
                print("TF_ACCEPT speed \(name): failed \(error.leafKey) after \(ContinuousClock.now - start)")
            }
        }
    }
}
