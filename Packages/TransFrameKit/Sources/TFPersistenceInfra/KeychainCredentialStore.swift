import Foundation
import Security
import TFDomain

/// Keychain-backed secrets (SEC-01): generic passwords, this device only, readable while unlocked.
/// The service name is injected so tests use a random service and the app keeps Debug and Release apart.
/// Reads are gated by the session unlock (APP-06) through `isUnlocked`.
public actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let isUnlocked: @Sendable () async -> Bool

    public init(service: String, isUnlocked: @escaping @Sendable () async -> Bool = { true }) {
        self.service = service
        self.isUnlocked = isUnlocked
    }

    private func baseQuery(_ ref: CredentialRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref.account,
        ]
    }

    public func secret(for ref: CredentialRef) async throws(AppError) -> String? {
        guard await isUnlocked() else { throw .engine(.credentialLocked) }
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: throw .engine(.credentialLocked)
        default: throw .persistence(.storeUnavailable)
        }
    }

    public func store(_ secret: String, for ref: CredentialRef) async throws(AppError) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try await remove(ref)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(ref) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(ref)
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .persistence(.writeFailed) }
    }

    public func remove(_ ref: CredentialRef) async throws(AppError) {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .persistence(.writeFailed) }
    }

    /// Presence check without reading the secret (does not require unlock).
    public func hasSecret(for ref: CredentialRef) async -> Bool {
        var query = baseQuery(ref)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Whether any secret exists for this service; used to decide whether to unlock at launch.
    public func hasAnySecret() async -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes every item of this service. Used by tests to clean up their random service.
    public func removeAll() async {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
