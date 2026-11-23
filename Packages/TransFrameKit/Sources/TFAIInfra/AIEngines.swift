import Foundation
import FoundationModels
import NaturalLanguage
import TFDomain
import TFNetworkInfra

public typealias SecretReader = @Sendable (CredentialRef) async throws(AppError) -> String?

/// Instructions shared by every generator (ADR-0011): never translate unless asked, return only the result.
enum GenerationPrompt {
    static func instructions(_ task: GenerationTask) -> String {
        switch task {
        case .rewrite(let tone):
            let style = switch tone {
            case .formal: "formal and polite"
            case .casual: "casual and conversational"
            case .concise: "as concise as possible"
            }
            return "Rewrite the user's text so it is \(style). Keep the language, meaning, names, numbers and formatting. Reply with the rewritten text only."
        case .polish:
            return "Fix grammar, spelling and awkward phrasing in the user's text. Keep its language and meaning. Reply with the corrected text only."
        case .suggestFileName:
            return "Suggest a short descriptive file name (3–6 words, no extension, no punctuation other than spaces) for a screenshot whose text and context follow. Reply with the name only."
        case .structureRepair:
            return "Repair the structure of this OCR output (tables as Markdown, code fenced, formulas in LaTeX) without changing any words. Reply with the repaired text only."
        }
    }

    static func clean(_ text: String, max: Int) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        return String(t.prefix(max))
    }
}

// MARK: - Apple Foundation Models, macOS 26+ (ADR-0007, AI-06/AI-07)

struct FoundationModelsGenerator: TextGenerating {
    let descriptor = EngineDescriptor(
        id: .appleFoundation, roles: [.textGeneration], name: .localized("engine.name.appleFoundation"), locality: .onDevice,
        requirements: EngineRequirements(minimumOS: OSVersion(26), needsModelAssets: true), limits: EngineLimits(timeout: .seconds(30), maxConcurrent: 1),
        probe: .alwaysAvailable, configDigest: "fm"
    )

    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    func generate(_ request: GenerationRequest) async throws(AppError) -> String {
        guard #available(macOS 26.0, *) else { throw .engine(.unavailableOnThisOS(.appleFoundation, minimum: OSVersion(26))) }
        guard SystemLanguageModel.default.isAvailable else { throw .engine(.assetsMissing(.appleFoundation)) }
        do {
            let session = LanguageModelSession(instructions: GenerationPrompt.instructions(request.task))
            let response = try await session.respond(to: request.input)
            return GenerationPrompt.clean(response.content, max: request.maxOutputCharacters)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .engine(.invalidResponse(.appleFoundation, detail: "generation failed"))
        }
    }
}

// MARK: - Language-model engines through the shared client

struct LLMGenerator: TextGenerating {
    let descriptor: EngineDescriptor
    let client: LLMClient

    func generate(_ request: GenerationRequest) async throws(AppError) -> String {
        let text = try await client.complete(
            system: GenerationPrompt.instructions(request.task), messages: [LLMMessage(role: .user, text: request.input)],
            maxTokens: max(request.maxOutputCharacters / 2, 256), temperature: 0.3
        ).text
        let cleaned = GenerationPrompt.clean(text, max: request.maxOutputCharacters)
        guard !cleaned.isEmpty else { throw .engine(.invalidResponse(descriptor.id, detail: "empty")) }
        return cleaned
    }
}

/// Automatic order: Foundation Models → local LLM engines → cloud LLM engines (ADR-0011 §3).
public struct TextGeneratorProvider: TextGeneratorProviding {
    private let transport: any HTTPTransport
    private let secrets: SecretReader
    private let descriptors: @Sendable (SettingsSnapshot) -> [EngineDescriptor]

    public init(transport: any HTTPTransport, secrets: @escaping SecretReader, descriptors: @escaping @Sendable (SettingsSnapshot) -> [EngineDescriptor]) {
        self.transport = transport
        self.secrets = secrets
        self.descriptors = descriptors
    }

    public func availableGenerators(settings: SettingsSnapshot) async -> [EngineDescriptor] {
        var result: [EngineDescriptor] = []
        if FoundationModelsGenerator.isAvailable { result.append(FoundationModelsGenerator().descriptor) }
        let llms = descriptors(settings).filter { $0.isLanguageModel && settings.engines.config(for: $0.id).isEnabled && !settings.engines.config(for: $0.id).model.isEmpty }
        result += llms.filter { $0.locality == .onDevice } + llms.filter { $0.locality != .onDevice }
        return result
    }

    public func generator(for choice: AIEngineChoice, settings: SettingsSnapshot) async -> (any TextGenerating)? {
        let available = await availableGenerators(settings: settings)
        let pick: EngineDescriptor?
        switch choice {
        case .automatic: pick = available.first
        case .engine(let id): pick = available.first { $0.id == id }
        }
        guard let pick else { return nil }
        if pick.id == .appleFoundation { return FoundationModelsGenerator() }
        let config = settings.engines.config(for: pick.id)
        let wire: LLMWire = pick.id == .claude ? .anthropic : (pick.id == .gemini ? .gemini : (config.apiMode == .responses ? .openAIResponses : .openAIChat))
        let secrets = secrets, credential = CredentialRef.engine(pick.id)
        let client = LLMClient(wire: wire, endpoint: config.endpoint, model: config.model, engine: pick.id, transport: transport) { () throws(AppError) in
            try await secrets(credential)
        }
        return LLMGenerator(descriptor: pick, client: client)
    }
}

// MARK: - On-device sentence embeddings (AI-05)

public struct NaturalLanguageEmbedding: TextEmbedding {
    public let descriptor = EngineDescriptor(
        id: .nlEmbedding, roles: [.embedding], name: .localized("engine.name.nl.embedding"), locality: .onDevice,
        limits: EngineLimits(timeout: .seconds(10), maxConcurrent: 1), probe: .alwaysAvailable, configDigest: "nl.sentence"
    )
    public let dimension = 512

    public init() {}

    public func embed(_ texts: [String], language: LanguageCode?) async throws(AppError) -> [[Float]] {
        try texts.map { text throws(AppError) in
            let lang = language.flatMap { NLLanguage(rawValue: $0.primary) } ?? NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
            guard let model = NLEmbedding.sentenceEmbedding(for: lang) ?? NLEmbedding.sentenceEmbedding(for: .english) else {
                throw .engine(.assetsMissing(.nlEmbedding))
            }
            guard let vector = model.vector(for: String(text.prefix(2000))) else { return [] }
            return vector.map(Float.init)
        }
    }
}
