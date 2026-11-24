import Foundation
import Testing
import TFDomain
@testable import TFPersistenceInfra

/// Uses a random defaults suite per test; never touches the real preferences domain (SPEC §06 §3).
@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "tf2.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func changesPersistImmediatelyAndReload() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.export.format = .jpeg
        store.general.interfaceLanguage = "ja"
        store.shortcuts[.pickColor] = GlobalShortcut(keyCode: 0x08, modifiers: [.command, .option])
        store.history.limit = 800

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.export.format == .jpeg)
        #expect(reloaded.general.interfaceLanguage == "ja")
        #expect(reloaded.shortcuts[.pickColor].modifiers == [.command, .option])
        #expect(reloaded.history.limit == 800)
    }

    @Test func corruptSegmentFallsBackToDefaultsWithoutAffectingOthers() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "settings.engines")
        let store = SettingsStore(defaults: defaults)
        store.general.playsSound = false
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.engines == EngineSettings())
        #expect(reloaded.general.playsSound == false)
    }

    @Test func resetRestoresDefaultsButKeepsOnboarding() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.onboarding.completed = true
        store.export.format = .heic
        store.annotationDefaults.lineWidth = 9
        store.resetAll()
        #expect(store.export.format == .png)
        #expect(store.annotationDefaults.lineWidth == AnnotationDefaults().lineWidth)
        #expect(store.onboarding.completed)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.export.format == .png)
    }

    @Test func snapshotCopiesEverySegment() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.privacy.guardEnabled = false
        store.languages.capture.target = .specific(LanguageCode("ja"))
        let snapshot = store.snapshot
        #expect(snapshot.privacy.guardEnabled == false)
        #expect(snapshot.languages.capture.target == .specific(LanguageCode("ja")))
    }
}

/// Real keychain with a random service name, removed afterwards (SPEC §06 §3).
@Suite("Keychain", .serialized)
struct KeychainCredentialStoreTests {
    @Test func storeReadRemove() async throws {
        let store = KeychainCredentialStore(service: "com.transframe.v2.tests.\(UUID().uuidString)")
        let ref = CredentialRef("engine.deepl.apiKey")
        #expect(try await store.secret(for: ref) == nil)
        try await store.store("  secret-value  ", for: ref)
        #expect(try await store.secret(for: ref) == "secret-value")
        #expect(await store.hasSecret(for: ref))
        #expect(await store.hasAnySecret())
        try await store.store("next", for: ref)
        #expect(try await store.secret(for: ref) == "next")
        try await store.store("", for: ref)
        #expect(try await store.secret(for: ref) == nil)
        await store.removeAll()
        #expect(await store.hasAnySecret() == false)
    }

    @Test func lockedSessionRefusesReads() async throws {
        let store = KeychainCredentialStore(service: "com.transframe.v2.tests.\(UUID().uuidString)", isUnlocked: { false })
        let ref = CredentialRef("engine.claude.apiKey")
        try await store.store("x", for: ref)
        await #expect(throws: AppError.engine(.credentialLocked)) { try await store.secret(for: ref) }
        #expect(await store.hasSecret(for: ref))
        await store.removeAll()
    }
}
