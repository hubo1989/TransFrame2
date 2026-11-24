import Foundation
import Testing
import TFDesignSystem
import TFDomain
import TFDomainTestSupport
import TFLocalization
import TFWorkspaceUI
@testable import SettingsFeature

/// A locked keychain must never turn into blank fields that delete stored keys on Save (review: Codex P1).
@Suite("Locked secrets")
@MainActor
struct LockedSecretsTests {
    @Test func lockedSecretsAreNotSavedAsEmptyAndReloadAfterUnlock() async throws {
        let ref = CredentialRef.engine(.deepl)
        let credentials = FakeCredentialStore([ref: "stored-key"])
        credentials.failure.current = .engine(.credentialLocked)
        let unlocker = FakeUnlocker()
        let l10n = Localizer(preference: "en")
        let router = FakeRouter()
        let deps = SettingsDependencies(
            settings: FakeSettings(), localizer: l10n, permissions: FakePermissions(), credentials: credentials, unlocker: unlocker, catalog: nil,
            glossary: nil,
            errors: StandardErrorPresenter(localizer: l10n, feedback: FeedbackCenter(), permissions: FakePermissions(), router: router),
            router: router)
        let model = EnginesModel(dependencies: deps)
        model.loadSecret(ref)
        for _ in 0..<100 where !model.unreadableSecrets.contains(ref) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.unreadableSecrets.contains(ref))
        #expect(model.secrets[ref] == nil)
        #expect(model.locked)
        credentials.failure.current = nil
        model.saveSecret(ref)
        try await Task.sleep(for: .milliseconds(50))
        #expect(credentials.secrets.current[ref] == "stored-key", "an empty field over an unreadable secret deletes nothing")
        await model.unlock()
        for _ in 0..<100 where model.secrets[ref] == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.secrets[ref] == "stored-key")
        #expect(model.unreadableSecrets.isEmpty)
    }
}
