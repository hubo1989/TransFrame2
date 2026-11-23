import Foundation
import NaturalLanguage
import os
import TFDomain
import TFNetworkInfra
import Translation

// MARK: - Apple Translation (TRN-01, TRN-18), macOS 26+ only (ADR-0007, D6)

struct AppleTranslationEngine: TranslationEngine {
    let descriptor: EngineDescriptor

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        guard #available(macOS 26.0, *) else { throw .engine(.unavailableOnThisOS(descriptor.id, minimum: OSVersion(26))) }
        var results: [TranslatedUnit] = []
        let grouped = Dictionary(grouping: batch.units) { unit in batch.from ?? LanguageDetection.detect(unit.text) ?? .english }
        var byID: [SegmentID: TranslatedUnit] = [:]
        for (source, units) in grouped {
            if source.isSameLanguage(as: batch.to) {
                for unit in units { byID[unit.id] = TranslatedUnit(id: unit.id, text: nil, detectedSource: source) }
                continue
            }
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source.bcp47), to: Locale.Language(identifier: batch.to.bcp47))
            guard status == .installed else {
                throw status == .unsupported ? .translation(.unsupportedPair) : .engine(.assetsMissing(descriptor.id))
            }
            do {
                let session = TranslationSession(installedSource: Locale.Language(identifier: source.bcp47), target: Locale.Language(identifier: batch.to.bcp47))
                let requests = units.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.description) }
                for response in try await session.translations(from: requests) {
                    if let unit = units.first(where: { $0.id.description == response.clientIdentifier }) {
                        byID[unit.id] = TranslatedUnit(id: unit.id, text: response.targetText, detectedSource: source)
                    }
                }
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .engine(.invalidResponse(descriptor.id, detail: "translation session failed"))
            }
        }
        results = batch.units.map { byID[$0.id] ?? TranslatedUnit(id: $0.id, text: nil) }
        return results
    }
}

public enum LanguageDetection {
    public static func detect(_ text: String) -> LanguageCode? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        switch language {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return LanguageCode("zh-Hant")
        default: return LanguageCode(language.rawValue)
        }
    }
}

public struct AppleLanguageAvailability: LanguageAvailabilityChecking {
    public init() {}
    public func status(from: LanguageCode?, to: LanguageCode) async -> LanguagePairStatus {
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: to.bcp47)
        let status: LanguageAvailability.Status
        if let from {
            status = await availability.status(from: Locale.Language(identifier: from.bcp47), to: target)
        } else {
            status = (try? await availability.status(for: "Hello", to: target)) ?? .unsupported
        }
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        default: return .unsupported
        }
    }
}

// MARK: - Factory (TranslationEngineProviding)

/// Builds engines from the settings snapshot at request time (configuration frozen per request).
public struct TranslationEngineFactory: TranslationEngineProviding, ModelDiscovering {
    private let transport: any HTTPTransport
    private let secrets: SecretReader
    private let os: OSVersion

    public init(transport: any HTTPTransport, secrets: @escaping SecretReader, os: OSVersion = .current) {
        self.transport = transport
        self.secrets = secrets
        self.os = os
    }

    public func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] {
        EngineID.builtInTranslation.map { descriptor($0, settings: settings) }
            + settings.engines.compatibleInstances.map { descriptor($0.engineID, settings: settings) }
    }

    func descriptor(_ id: EngineID, settings: SettingsSnapshot) -> EngineDescriptor {
        let config = settings.engines.config(for: id)
        let locality = EngineLocality.classify(host: config.host)
        let name: EngineName = settings.engines.compatibleInstances.first { $0.engineID == id }.map { .userDefined($0.name) } ?? .localized("engine.name.\(id.raw)")
        let digest = "\(id.raw)|\(config.host ?? "")|\(config.model)|\(config.apiMode.rawValue)"
        switch id {
        case .appleTranslation:
            return EngineDescriptor(
                id: id, roles: [.translation], name: name, locality: .onDevice, capabilities: [.batch, .segmentIDs],
                requirements: EngineRequirements(minimumOS: OSVersion(26), needsModelAssets: true), limits: EngineLimits(timeout: .seconds(30), maxConcurrent: 1),
                billing: .free, probe: .alwaysAvailable, configDigest: digest
            )
        case .mtran:
            return EngineDescriptor(
                id: id, roles: [.translation], name: name, locality: locality, capabilities: [.autoDetectSource],
                requirements: EngineRequirements(needsEndpoint: true), limits: EngineLimits(timeout: .seconds(30), maxConcurrent: 1),
                billing: .free, probe: .freeEndpoint, configDigest: digest
            )
        case .google, .deepl, .baidu:
            return EngineDescriptor(
                id: id, roles: [.translation], name: name, locality: .cloud, capabilities: [.batch, .autoDetectSource],
                requirements: EngineRequirements(needsCredential: true), limits: EngineLimits(timeout: .seconds(30)),
                billing: .metered, probe: .none, configDigest: digest
            )
        default:
            let local = locality == .onDevice
            return EngineDescriptor(
                id: id, roles: [.translation, .recognition, .textGeneration], name: name, locality: locality,
                capabilities: [.batch, .segmentIDs, .autoDetectSource, .glossary, .context, .imageInput],
                requirements: EngineRequirements(needsCredential: !local, needsEndpoint: true), limits: EngineLimits(timeout: .seconds(120)),
                billing: local ? .free : .metered, probe: .freeEndpoint, configDigest: digest
            )
        }
    }

    public func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any TranslationEngine)? {
        let config = settings.engines.config(for: id)
        let descriptor = descriptor(id, settings: settings)
        let secrets = secrets
        let credential = CredentialRef.engine(id)
        let key: @Sendable () async throws(AppError) -> String? = { () throws(AppError) in try await secrets(credential) }
        switch id {
        case .appleTranslation: return AppleTranslationEngine(descriptor: descriptor)
        case .mtran: return MTranServerEngine(descriptor: descriptor, endpoint: config.endpoint, transport: transport, token: key)
        case .google: return GoogleEngine(descriptor: descriptor, endpoint: config.endpoint, transport: transport, key: key)
        case .deepl: return DeepLEngine(descriptor: descriptor, endpoint: config.endpoint, transport: transport, key: key)
        case .baidu: return BaiduEngine(descriptor: descriptor, endpoint: config.endpoint, appID: config.options["appID"] ?? "", transport: transport, key: key)
        default:
            guard id.isCompatibleInstance ? settings.engines.compatibleInstances.contains(where: { $0.engineID == id }) : true else { return nil }
            return LLMTranslationEngine(descriptor: descriptor, client: client(for: id, config: config, key: key))
        }
    }

    func client(for id: EngineID, config: EngineConfig, key: @escaping @Sendable () async throws(AppError) -> String?) -> LLMClient {
        let wire: LLMWire = switch id {
        case .claude: .anthropic
        case .gemini: .gemini
        default: config.apiMode == .responses ? .openAIResponses : .openAIChat
        }
        return LLMClient(wire: wire, endpoint: config.endpoint, model: config.model, engine: id, transport: transport, apiKey: key)
    }

    /// Why an engine cannot run now (TRN-09, TRN-01): unconfigured, wrong OS, or deleted instance.
    public func skipReason(_ id: EngineID, settings: SettingsSnapshot) async -> SkipReason? {
        if id.isCompatibleInstance, !settings.engines.compatibleInstances.contains(where: { $0.engineID == id }) { return .instanceDeleted }
        let descriptor = descriptor(id, settings: settings)
        if !descriptor.requirements.isSupported(on: os) { return .unavailableOnThisOS }
        let config = settings.engines.config(for: id)
        if !config.isEnabled { return .unconfigured }
        if descriptor.requirements.needsEndpoint, config.endpoint.trimmingCharacters(in: .whitespaces).isEmpty { return .unconfigured }
        if id == .baidu, (config.options["appID"] ?? "").isEmpty { return .unconfigured }
        if descriptor.requirements.needsCredential, !Endpoint.isLoopback(config.endpoint) {
            let secret = try? await secrets(.engine(id))
            if secret?.isEmpty ?? true { return .unconfigured }
        }
        return nil
    }

    public func models(endpoint: String, credential: CredentialRef?, engine: EngineID) async throws(AppError) -> [String] {
        let secrets = secrets
        let wire: LLMWire = engine == .claude ? .anthropic : (engine == .gemini ? .gemini : .openAIChat)
        let client = LLMClient(wire: wire, endpoint: endpoint, model: "", engine: engine, transport: transport) { () throws(AppError) in
            guard let credential else { return nil }
            return try await secrets(credential)
        }
        return try await client.listModels()
    }
}

// MARK: - Health probes (TRN-11): four states, 60 s cache, free endpoints only

public actor EngineHealthProber: EngineHealthProbing {
    private let factory: TranslationEngineFactory
    private let transport: any HTTPTransport
    private var cache: [EngineID: (EngineHealth, ContinuousClock.Instant)] = [:]

    public init(factory: TranslationEngineFactory, transport: any HTTPTransport) {
        self.factory = factory
        self.transport = transport
    }

    public func cachedHealth(of id: EngineID) async -> EngineHealth? {
        guard let (health, at) = cache[id], ContinuousClock.now - at < EngineHealth.cacheLifetime else { return nil }
        return health
    }

    public func health(of id: EngineID, settings: SettingsSnapshot, forceRefresh: Bool) async -> EngineHealth {
        if !forceRefresh, let cached = await cachedHealth(of: id) { return cached }
        let result = await probe(id, settings: settings)
        cache[id] = (result, .now)
        return result
    }

    private func probe(_ id: EngineID, settings: SettingsSnapshot) async -> EngineHealth {
        if let skip = await factory.skipReason(id, settings: settings) {
            return skip == .unavailableOnThisOS ? .failing(reason: "os") : .unconfigured
        }
        let descriptor = factory.descriptor(id, settings: settings)
        let config = settings.engines.config(for: id)
        switch descriptor.probe {
        case .alwaysAvailable:
            return .available
        case .none:
            return .unverified
        case .freeEndpoint:
            do {
                if id == .mtran {
                    guard let url = Endpoint.url(config.endpoint, appending: "/health") else { return .unconfigured }
                    let response = try await transport.send(HTTPRequest(url: url, timeout: EngineHealth.probeTimeout), engine: id)
                    return response.status < 500 ? .available : .failing(reason: "HTTP \(response.status)")
                }
                _ = try await factory.models(endpoint: config.endpoint, credential: .engine(id), engine: id)
                return .available
            } catch let error as AppError {
                return .failing(reason: error.leafKey)
            } catch {
                return .failing(reason: "invariant")
            }
        }
    }
}
