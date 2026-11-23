import Foundation
import TFDomain

/// Programmable translation engine: a script of outcomes per call, an optional delay, and a call log.
public final class FakeTranslationEngine: TranslationEngine, @unchecked Sendable {
    public enum Behavior: Sendable {
        case translate(@Sendable (String) -> String?)
        case fail(AppError)
        case delay(Duration, @Sendable (String) -> String?)
    }

    public let descriptor: EngineDescriptor
    public let behavior: Behavior
    public let calls = CallLog<TranslationBatch>()

    public init(_ id: EngineID, locality: EngineLocality = .onDevice, capabilities: Set<EngineCapability> = [.batch], behavior: Behavior) {
        descriptor = EngineDescriptor(id: id, roles: [.translation], name: .userDefined(id.raw), locality: locality, capabilities: capabilities,
                                      limits: EngineLimits(timeout: .seconds(5)), configDigest: id.raw)
        self.behavior = behavior
    }

    public func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        calls.append(batch)
        switch behavior {
        case .fail(let error): throw error
        case .translate(let map):
            return batch.units.map { TranslatedUnit(id: $0.id, text: map($0.text)) }
        case .delay(let duration, let map):
            do { try await Task.sleep(for: duration) } catch { throw .cancelled }
            return batch.units.map { TranslatedUnit(id: $0.id, text: map($0.text)) }
        }
    }
}

public final class FakeTranslationEngines: TranslationEngineProviding, @unchecked Sendable {
    public let engines: [EngineID: FakeTranslationEngine]
    public let skipped: [EngineID: SkipReason]

    public init(_ engines: [FakeTranslationEngine], skipped: [EngineID: SkipReason] = [:]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.descriptor.id, $0) })
        self.skipped = skipped
    }

    public func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] { engines.values.map(\.descriptor) }
    public func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any TranslationEngine)? { engines[id] }
    public func skipReason(_ id: EngineID, settings: SettingsSnapshot) async -> SkipReason? { skipped[id] ?? (engines[id] == nil ? .unconfigured : nil) }
}
