import Foundation
import Testing
import TFDomain
import TFDomainTestSupport

@Suite("Settings compatibility and isolation")
struct SettingsCompatibilityTests {
    @Test func builtinDefaultsAndInstanceOverridesKeepLocalityAndIdentitySeparate() throws {
        var settings = EngineSettings()
        let hosts: [(EngineID, String)] = [
            (.mtran, "localhost"), (.openAICompatible, "api.openai.com"), (.claude, "api.anthropic.com"),
            (.gemini, "generativelanguage.googleapis.com"), (.google, "translation.googleapis.com"),
            (.deepl, "api-free.deepl.com"), (.baidu, "fanyi-api.baidu.com"),
        ]
        for (id, hostname) in hosts {
            #expect(settings.config(for: id).host == hostname)
        }
        #expect(settings.config(for: .appleTranslation).host == nil)
        #expect(settings.config(for: .openAICompatible).preset == .openAI)
        #expect(OpenAIPreset.custom.defaultEndpoint.isEmpty)

        let local = CompatibleInstance(name: "Local", config: EngineConfig(endpoint: OpenAIPreset.ollama.defaultEndpoint, model: "fixture"))
        let remote = CompatibleInstance(name: "Remote", config: EngineConfig(endpoint: "https://api.example.invalid/v1", model: "fixture"))
        settings.compatibleInstances = [local, remote]
        settings.builtins[.deepl] = EngineConfig(endpoint: "https://api.deepl.com/v2")
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.config(for: local.engineID).host == "localhost")
        #expect(decoded.config(for: remote.engineID).model == "fixture")
        #expect(decoded.config(for: .deepl).host == "api.deepl.com")
        #expect(local.credential != remote.credential)
        #expect(local.engineID.compatibleInstanceID == local.id)
    }

    @Test func partialRecognitionConfigKeepsDefaultsAndIgnoresUnknownProviders() throws {
        let custom = ModelEndpointConfig(endpoint: "http://[fd00::1234]:11434/v1", model: "fixture-vlm", credential: .analysis(.local))
        let encodedConfig = try JSONEncoder().encode(custom)
        let config = try JSONSerialization.jsonObject(with: encodedConfig)
        let payload = try JSONSerialization.data(withJSONObject: [
            "analysisProvider": "local", "analysisConfigs": ["local": config, "future-provider": config],
            "paddle": ["mode": "accurate", "modelDirectory": "/fixture/paddle-model"],
        ])
        let restored = try JSONDecoder().decode(RecognitionSettings.self, from: payload)
        #expect(restored.analysisProvider == .local)
        #expect(restored.config(for: .local)?.locality == .localNetwork)
        #expect(restored.config(for: .local)?.model == "fixture-vlm")
        #expect(restored.config(for: .openAI)?.locality == .cloud)
        #expect(restored.config(for: .paddle) == nil)
        #expect(restored.analysisConfigs.count == RecognitionSettings.defaultAnalysisConfigs.count)
        #expect(restored.paddle.mode == .accurate && restored.paddle.modelDirectory == "/fixture/paddle-model")
        #expect(restored.paddle.executablePath == nil)
    }

    @Test func shortcutMigrationPreservesRecognizedOverridesAndDefaultsUnsignedEntries() throws {
        let override = GlobalShortcut(keyCode: 0x08, modifiers: [.option, .shift])
        var initial = ShortcutSettings()
        initial[.selection] = override
        let encoded = try JSONEncoder().encode(initial)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let bindings = try #require(original["bindings"] as? [String: Any])
        let selected = try #require(bindings["selection"])
        let old = try JSONSerialization.data(withJSONObject: ["bindings": ["selection": selected, "future-action": selected]])
        let restored = try JSONDecoder().decode(ShortcutSettings.self, from: old)
        #expect(restored.bindings.count == HotkeyAction.allCases.count)
        #expect(restored[.selection].displayString == "⌥⇧C")
        #expect(restored[.selection].keyEquivalent == "c")
        #expect(restored[.fullScreen] == HotkeyAction.fullScreen.defaultShortcut)
        #expect(ShortcutValidation.validate(override, for: .fullScreen, in: restored) == .conflict(.selection))
    }

    @Test @MainActor func frozenWorkflowSettingsSurviveEditsAndProviderFieldsDoNotBleed() {
        let settings = FakeSettings()
        settings.engines.orderedChain = [.mtran]
        settings.languages.capture.target = .specific(LanguageCode("ja"))
        settings.privacy.sendContext = false
        settings.imageHost.provider = .hostCOS
        settings.imageHost.setField("bucket", "fixture-cos", for: .hostCOS)
        settings.imageHost.setField("bucket", "fixture-oss", for: .hostOSS)
        let snapshot = settings.snapshot
        settings.imageHost.setField("bucket", "edited", for: .hostCOS)
        settings.resetAll()

        #expect(snapshot.engines.routing == .ordered([.mtran]))
        #expect(snapshot.languages.capture.target == .specific(LanguageCode("ja")))
        #expect(snapshot.privacy.sendContext == false)
        #expect(snapshot.imageHost.field("bucket", for: .hostCOS) == "fixture-cos")
        #expect(snapshot.imageHost.field("bucket", for: .hostOSS) == "fixture-oss")
        #expect(snapshot.imageHost.field("bucket", for: .hostKodo).isEmpty)
        #expect(CredentialRef.imageHost(.hostCOS, "secret") != .imageHost(.hostOSS, "secret"))
        #expect(settings.snapshot == SettingsSnapshot())
    }
}
