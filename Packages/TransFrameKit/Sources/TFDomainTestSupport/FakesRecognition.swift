import TFDomain

public struct FakeRecognitionEngine: RecognitionEngine {
    public struct Call: Sendable {
        public let image: PixelImage
        public let hints: [LanguageCode]
        public let detail: AnalysisDetail
    }

    public let descriptor: EngineDescriptor
    public let calls = CallLog<Call>()
    private let respond: @Sendable (Call) async throws(AppError) -> RawRecognition

    public init(
        _ id: EngineID, locality: EngineLocality = .onDevice, maxImageEdge: Int? = nil,
        respond: @escaping @Sendable (Call) async throws(AppError) -> RawRecognition
    ) {
        descriptor = EngineDescriptor(
            id: id, roles: [.recognition], name: .userDefined(id.raw), locality: locality,
            limits: EngineLimits(maxImageEdge: maxImageEdge), configDigest: id.raw
        )
        self.respond = respond
    }

    public func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        let call = Call(image: image, hints: hints, detail: detail)
        calls.append(call)
        return try await respond(call)
    }
}

public struct FakeRecognitionEngines: RecognitionEngineProviding {
    private let engines: [EngineID: FakeRecognitionEngine]

    public init(_ engines: [FakeRecognitionEngine]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.descriptor.id, $0) })
    }

    public func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] { engines.values.map(\.descriptor) }
    public func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any RecognitionEngine)? { engines[id] }

    public func analysisEngine(_ provider: AnalysisProvider, settings: SettingsSnapshot) -> (any RecognitionEngine)? {
        return engines[provider.engineID]
    }
}

public struct FakeCodeDetector: CodeDetecting {
    public let calls = CallLog<PixelImage>()
    private let findings: [DetectedCode]

    public init(_ findings: [DetectedCode]) { self.findings = findings }

    public func codes(in image: PixelImage) async -> [DetectedCode] {
        calls.append(image)
        return findings
    }
}

public struct FakeTextGenerators: TextGeneratorProviding {
    private let configured: (any TextGenerating)?

    public init(_ configured: (any TextGenerating)?) { self.configured = configured }

    public func generator(for choice: AIEngineChoice, settings: SettingsSnapshot) async -> (any TextGenerating)? {
        configured
    }

    public func availableGenerators(settings: SettingsSnapshot) async -> [EngineDescriptor] {
        configured.map { [$0.descriptor] } ?? []
    }
}
