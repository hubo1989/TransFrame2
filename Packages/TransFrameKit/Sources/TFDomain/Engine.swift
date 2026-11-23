import Foundation

// MARK: - EngineDescriptor (SPEC §02 §6)

public struct EngineID: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: EngineID, rhs: EngineID) -> Bool { lhs.raw < rhs.raw }

    // §6.1
    public static let visionText = EngineID("vision.text")
    public static let visionDocument = EngineID("vision.document")
    public static let paddleLocal = EngineID("paddle.local")
    public static let paddleCloud = EngineID("paddle.cloud")
    public static let appleTranslation = EngineID("apple.translation")
    public static let mtran = EngineID("mtran")
    public static let openAICompatible = EngineID("openai-compatible")
    public static let claude = EngineID("claude")
    public static let gemini = EngineID("gemini")
    public static let google = EngineID("google")
    public static let deepl = EngineID("deepl")
    public static let baidu = EngineID("baidu")
    public static let appleFoundation = EngineID("apple.foundation")
    public static let nlEmbedding = EngineID("nl.embedding")
    public static let hostPicGo = EngineID("host.picgo")
    public static let hostOSS = EngineID("host.oss")
    public static let hostCOS = EngineID("host.cos")
    public static let hostKodo = EngineID("host.kodo")

    public static func compatible(_ id: UUID) -> EngineID { EngineID("compatible:\(id.uuidString.lowercased())") }
    public var compatibleInstanceID: UUID? {
        guard raw.hasPrefix("compatible:") else { return nil }
        return UUID(uuidString: String(raw.dropFirst("compatible:".count)))
    }
    public var isCompatibleInstance: Bool { compatibleInstanceID != nil }

    /// Built-in translation engines, in the order shown in settings.
    public static let builtInTranslation: [EngineID] = [
        .appleTranslation, .mtran, .openAICompatible, .claude, .gemini, .google, .deepl, .baidu,
    ]
}

public enum EngineRole: String, Sendable, Codable, Hashable, CaseIterable {
    case recognition, translation, textGeneration, embedding, imageHost
}

public enum EngineName: Sendable, Hashable, Codable {
    case localized(String)
    case userDefined(String)
}

public enum EngineLocality: String, Sendable, Codable, Hashable {
    case onDevice, localNetwork, cloud

    /// Runtime classification by endpoint host (SPEC §02 §6.1): loopback → onDevice, private → localNetwork.
    public static func classify(host: String?) -> EngineLocality {
        guard var host = host?.lowercased(), !host.isEmpty else { return .cloud }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return .onDevice }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            if address >> 24 == 127 { return .onDevice }
            if address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8 { return .localNetwork }
            return .cloud
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .onDevice }
                if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) { return .localNetwork }
                return .cloud
            }
        }
        return host.hasSuffix(".local") ? .localNetwork : .cloud
    }

    public var isOnDevice: Bool { self == .onDevice }
}

public enum EngineCapability: String, Sendable, Codable, Hashable {
    case boundingBoxes, confidence, structure, handwriting
    case batch, segmentIDs, autoDetectSource, glossary, context
    case imageInput, streaming
}

public struct EngineRequirements: Sendable, Hashable {
    public let minimumOS: OSVersion?
    public let needsCredential: Bool
    public let needsEndpoint: Bool
    public let needsModelAssets: Bool

    public init(minimumOS: OSVersion? = nil, needsCredential: Bool = false, needsEndpoint: Bool = false, needsModelAssets: Bool = false) {
        self.minimumOS = minimumOS
        self.needsCredential = needsCredential
        self.needsEndpoint = needsEndpoint
        self.needsModelAssets = needsModelAssets
    }

    public func isSupported(on version: OSVersion) -> Bool { minimumOS.map { version >= $0 } ?? true }
}

public struct EngineLimits: Sendable, Hashable {
    public let timeout: Duration
    public let maxConcurrent: Int
    public let maxImageEdge: Int?
    public let maxBatchCharacters: Int?

    public init(timeout: Duration = .seconds(60), maxConcurrent: Int = 2, maxImageEdge: Int? = nil, maxBatchCharacters: Int? = nil) {
        self.timeout = timeout
        self.maxConcurrent = maxConcurrent
        self.maxImageEdge = maxImageEdge
        self.maxBatchCharacters = maxBatchCharacters
    }
}

public enum EngineBilling: String, Sendable, Hashable, Codable { case free, metered }
public enum HealthProbeKind: String, Sendable, Hashable, Codable { case alwaysAvailable, freeEndpoint, none }

public struct EngineDescriptor: Sendable, Identifiable, Hashable {
    public let id: EngineID
    public let roles: Set<EngineRole>
    public let name: EngineName
    public let locality: EngineLocality
    public let capabilities: Set<EngineCapability>
    public let requirements: EngineRequirements
    public let limits: EngineLimits
    public let billing: EngineBilling
    public let probe: HealthProbeKind
    /// Digest of non-secret configuration; part of cache keys.
    public let configDigest: String

    public init(
        id: EngineID, roles: Set<EngineRole>, name: EngineName, locality: EngineLocality,
        capabilities: Set<EngineCapability> = [], requirements: EngineRequirements = EngineRequirements(),
        limits: EngineLimits = EngineLimits(), billing: EngineBilling = .free, probe: HealthProbeKind = .none,
        configDigest: String = ""
    ) {
        self.id = id
        self.roles = roles
        self.name = name
        self.locality = locality
        self.capabilities = capabilities
        self.requirements = requirements
        self.limits = limits
        self.billing = billing
        self.probe = probe
        self.configDigest = configDigest
    }

    /// Large-language-model style engines receive prompts, glossary and context.
    public var isLanguageModel: Bool { capabilities.contains(.context) }
}

// MARK: - Health (SPEC §02 §6.2)

public enum EngineHealth: Sendable, Equatable {
    case available
    case failing(reason: String)
    case unconfigured
    case unverified
    case checking

    public static let cacheLifetime: Duration = .seconds(60)
    public static let probeTimeout: Duration = .seconds(5)
}
