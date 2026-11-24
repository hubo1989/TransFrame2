import Foundation
import Observation

// MARK: - Settings segments (SPEC §02 §14.2). Every segment decodes missing keys to defaults.

extension KeyedDecodingContainer {
    @inlinable
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }
}

/// Reference to a secret in the keychain. The secret itself never lives in settings.
public struct CredentialRef: Sendable, Codable, Hashable, CustomStringConvertible {
    public let account: String
    public init(_ account: String) { self.account = account }
    public var description: String { account }

    public static func engine(_ id: EngineID, _ field: String = "apiKey") -> CredentialRef { CredentialRef("engine.\(id.raw).\(field)") }
    public static func analysis(_ provider: AnalysisProvider) -> CredentialRef { CredentialRef("analysis.\(provider.rawValue).apiKey") }
    public static func imageHost(_ id: EngineID, _ field: String) -> CredentialRef { CredentialRef("host.\(id.raw).\(field)") }
}

public struct GeneralSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    /// nil means the Desktop.
    public var saveLocationPath: String?
    /// nil means follow the system (L10N-02).
    public var interfaceLanguage: String?
    public var playsSound = true
    /// Capture highlights the window under the pointer for click selection and double-click save (CAP-05, CAP-13).
    public var detectsWindows = true

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, saveLocationPath, interfaceLanguage, playsSound, detectsWindows }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        saveLocationPath = c.value(.saveLocationPath, default: d.saveLocationPath)
        interfaceLanguage = c.value(.interfaceLanguage, default: d.interfaceLanguage)
        playsSound = c.value(.playsSound, default: d.playsSound)
        detectsWindows = c.value(.detectsWindows, default: d.detectsWindows)
    }
}

public struct ExportSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var format: ExportFormat = .png
    public var jpegQuality = 0.9
    public var heicQuality = 0.9

    public init() {}
    public func quality(for format: ExportFormat) -> Double {
        switch format {
        case .png: 1
        case .jpeg: jpegQuality
        case .heic: heicQuality
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, format, jpegQuality, heicQuality }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        format = c.value(.format, default: d.format)
        jpegQuality = c.value(.jpegQuality, default: d.jpegQuality)
        heicQuality = c.value(.heicQuality, default: d.heicQuality)
    }
}

public struct ShortcutSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var bindings: [HotkeyAction: GlobalShortcut] = [:]

    public init() {
        for action in HotkeyAction.allCases { bindings[action] = action.defaultShortcut }
    }

    public subscript(action: HotkeyAction) -> GlobalShortcut {
        get { bindings[action] ?? action.defaultShortcut }
        set { bindings[action] = newValue }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, bindings }
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        let stored: [String: GlobalShortcut] = c.value(.bindings, default: [:])
        for (key, value) in stored { if let action = HotkeyAction(rawValue: key) { bindings[action] = value } }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }), forKey: .bindings)
    }
}

public struct AnnotationDefaults: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var strokeColor = AnnotationPalette.red
    /// Points; converted to document pixels with the base image scale when an annotation is created.
    public var lineWidth = 3.0
    public var fontSize = 16.0
    public var isFilled = false
    public var fillColor = AnnotationPalette.red.withAlpha(0.25)
    public var mosaicBlockSize = 12.0

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, strokeColor, lineWidth, fontSize, isFilled, fillColor, mosaicBlockSize }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnnotationDefaults()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        strokeColor = c.value(.strokeColor, default: d.strokeColor)
        lineWidth = c.value(.lineWidth, default: d.lineWidth)
        fontSize = c.value(.fontSize, default: d.fontSize)
        isFilled = c.value(.isFilled, default: d.isFilled)
        fillColor = c.value(.fillColor, default: d.fillColor)
        mosaicBlockSize = c.value(.mosaicBlockSize, default: d.mosaicBlockSize)
    }

    public static let lineWidthRange = 1.0...20.0
    public static let fontSizeRange = 8.0...96.0
    public static let mosaicRange = 4.0...48.0
}

public struct LanguagePair: Sendable, Codable, Equatable, Hashable {
    /// nil means automatic detection.
    public var source: LanguageCode?
    public var target: TargetLanguage
    public init(source: LanguageCode? = nil, target: TargetLanguage) {
        self.source = source
        self.target = target
    }
}

public struct LanguageSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var capture = LanguagePair(target: .followSystem)
    public var insert = LanguagePair(target: .specific(.english))

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, capture, insert }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LanguageSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        capture = c.value(.capture, default: d.capture)
        insert = c.value(.insert, default: d.insert)
    }
}

public enum PaddleMode: String, Sendable, Codable, CaseIterable { case fast, accurate }

public struct PaddleSettings: Sendable, Codable, Equatable {
    public var mode: PaddleMode = .fast
    /// nil means search PATH and common install locations.
    public var executablePath: String?
    /// Local model directory for the accurate mode (OCR-05).
    public var modelDirectory: String?
    public var cloudEndpoint = ""
    public var cloudCredential = CredentialRef.engine(.paddleCloud, "token")

    public init() {}
    private enum CodingKeys: String, CodingKey { case mode, executablePath, modelDirectory, cloudEndpoint, cloudCredential }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PaddleSettings()
        mode = c.value(.mode, default: d.mode)
        executablePath = c.value(.executablePath, default: d.executablePath)
        modelDirectory = c.value(.modelDirectory, default: d.modelDirectory)
        cloudEndpoint = c.value(.cloudEndpoint, default: d.cloudEndpoint)
        cloudCredential = c.value(.cloudCredential, default: d.cloudCredential)
    }
}

/// Analysis engine for screenshot translation (OCR-07), plus the on-device Vision engines.
public enum AnalysisProvider: String, Sendable, Codable, CaseIterable, Hashable {
    case vision, visionDocument, openAI, claude, gemini, local, paddle

    public var engineID: EngineID {
        switch self {
        case .vision: .visionText
        case .visionDocument: .visionDocument
        case .openAI, .local: .openAICompatible
        case .claude: .claude
        case .gemini: .gemini
        case .paddle: .paddleLocal
        }
    }
    public var isLanguageModel: Bool { [.openAI, .claude, .gemini, .local].contains(self) }
}

public enum OpenAIAPIMode: String, Sendable, Codable, CaseIterable { case chat, responses }

public struct ModelEndpointConfig: Sendable, Codable, Equatable, Hashable {
    public var endpoint: String
    public var model: String
    public var apiMode: OpenAIAPIMode
    public var credential: CredentialRef

    public init(endpoint: String, model: String, apiMode: OpenAIAPIMode = .chat, credential: CredentialRef) {
        self.endpoint = endpoint
        self.model = model
        self.apiMode = apiMode
        self.credential = credential
    }

    public var host: String? { URL(string: endpoint)?.host }
    public var locality: EngineLocality { EngineLocality.classify(host: host) }
}

public struct RecognitionSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    /// Engine used by the "Recognize" action (N-11): Vision or PaddleOCR.
    public var ocrEngine: EngineID = .visionText
    public var paddle = PaddleSettings()
    public var analysisProvider: AnalysisProvider = .vision
    public var analysisConfigs: [AnalysisProvider: ModelEndpointConfig] = RecognitionSettings.defaultAnalysisConfigs

    public init() {}

    public static let defaultAnalysisConfigs: [AnalysisProvider: ModelEndpointConfig] = [
        .openAI: ModelEndpointConfig(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini", credential: .analysis(.openAI)),
        .claude: ModelEndpointConfig(endpoint: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5", credential: .analysis(.claude)),
        .gemini: ModelEndpointConfig(
            endpoint: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash", credential: .analysis(.gemini)
        ),
        .local: ModelEndpointConfig(endpoint: "http://localhost:11434/v1", model: "qwen2.5vl", credential: .analysis(.local)),
    ]

    public func config(for provider: AnalysisProvider) -> ModelEndpointConfig? {
        analysisConfigs[provider] ?? Self.defaultAnalysisConfigs[provider]
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, ocrEngine, paddle, analysisProvider, analysisConfigs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecognitionSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        ocrEngine = c.value(.ocrEngine, default: d.ocrEngine)
        paddle = c.value(.paddle, default: d.paddle)
        analysisProvider = c.value(.analysisProvider, default: d.analysisProvider)
        let stored: [String: ModelEndpointConfig] = c.value(.analysisConfigs, default: [:])
        var configs = d.analysisConfigs
        for (k, v) in stored { if let p = AnalysisProvider(rawValue: k) { configs[p] = v } }
        analysisConfigs = configs
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(ocrEngine, forKey: .ocrEngine)
        try c.encode(paddle, forKey: .paddle)
        try c.encode(analysisProvider, forKey: .analysisProvider)
        try c.encode(Dictionary(uniqueKeysWithValues: analysisConfigs.map { ($0.key.rawValue, $0.value) }), forKey: .analysisConfigs)
    }
}

public enum OpenAIPreset: String, Sendable, Codable, CaseIterable { case openAI, ollama, custom

    public var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }
}

public struct EngineConfig: Sendable, Codable, Equatable, Hashable {
    public var isEnabled: Bool
    public var endpoint: String
    public var model: String
    public var apiMode: OpenAIAPIMode
    public var preset: OpenAIPreset?
    /// Engine specific non-secret fields (e.g. Baidu app ID, DeepL plan).
    public var options: [String: String]

    public init(
        isEnabled: Bool = true, endpoint: String = "", model: String = "", apiMode: OpenAIAPIMode = .chat,
        preset: OpenAIPreset? = nil, options: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.model = model
        self.apiMode = apiMode
        self.preset = preset
        self.options = options
    }

    public var host: String? { URL(string: endpoint)?.host }

    public static func defaults(for id: EngineID) -> EngineConfig {
        switch id {
        case .mtran: EngineConfig(endpoint: "http://localhost:8989")
        case .openAICompatible: EngineConfig(endpoint: OpenAIPreset.openAI.defaultEndpoint, model: "gpt-4o-mini", preset: .openAI)
        case .claude: EngineConfig(endpoint: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5")
        case .gemini: EngineConfig(endpoint: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        case .google: EngineConfig(endpoint: "https://translation.googleapis.com/language/translate/v2")
        case .deepl: EngineConfig(endpoint: "https://api-free.deepl.com/v2")
        case .baidu: EngineConfig(endpoint: "https://fanyi-api.baidu.com/api/trans/vip/translate", options: ["appID": ""])
        default: EngineConfig()
        }
    }
}

public struct CompatibleInstance: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var config: EngineConfig

    public init(id: UUID = UUID(), name: String, config: EngineConfig = EngineConfig(endpoint: "http://localhost:11434/v1")) {
        self.id = id
        self.name = name
        self.config = config
    }

    public var engineID: EngineID { .compatible(id) }
    public var credential: CredentialRef { .engine(engineID) }
    public static let maximumCount = 5
}

public enum TranslationMode: String, Sendable, Codable, CaseIterable { case ordered, compare }

public struct EngineSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var mode: TranslationMode = .ordered
    public var orderedChain: [EngineID] = [.appleTranslation]
    public var compareGroup: [EngineID] = [.appleTranslation, .openAICompatible]
    public var builtins: [EngineID: EngineConfig] = [:]
    public var compatibleInstances: [CompatibleInstance] = []

    public init() {}

    public func config(for id: EngineID) -> EngineConfig {
        if let instance = compatibleInstances.first(where: { $0.engineID == id }) { return instance.config }
        return builtins[id] ?? EngineConfig.defaults(for: id)
    }

    public var routing: EngineRouting {
        switch mode {
        case .ordered: .ordered(Array(orderedChain.prefix(EngineRouting.maxOrdered)))
        case .compare: .compare(Array(compareGroup.prefix(EngineRouting.compareRange.upperBound)))
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, mode, orderedChain, compareGroup, builtins, compatibleInstances }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        mode = c.value(.mode, default: d.mode)
        orderedChain = c.value(.orderedChain, default: d.orderedChain)
        compareGroup = c.value(.compareGroup, default: d.compareGroup)
        let stored: [String: EngineConfig] = c.value(.builtins, default: [:])
        builtins = Dictionary(uniqueKeysWithValues: stored.map { (EngineID($0.key), $0.value) })
        compatibleInstances = c.value(.compatibleInstances, default: d.compatibleInstances)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(mode, forKey: .mode)
        try c.encode(orderedChain, forKey: .orderedChain)
        try c.encode(compareGroup, forKey: .compareGroup)
        try c.encode(Dictionary(uniqueKeysWithValues: builtins.map { ($0.key.raw, $0.value) }), forKey: .builtins)
        try c.encode(compatibleInstances, forKey: .compatibleInstances)
    }
}

public struct PromptKey: Sendable, Codable, Hashable {
    public let engine: EngineID
    public let scene: TranslationScene
    public init(engine: EngineID, scene: TranslationScene) {
        self.engine = engine
        self.scene = scene
    }
}

public struct PromptSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var custom: [PromptKey: String] = [:]

    public init() {}

    /// Variables available in templates (TRN-13).
    public static let variables = ["{source_language}", "{target_language}", "{text}", "{glossary}", "{context}"]

    public static let defaultTemplate = """
    You are a professional translator. Translate the text from {source_language} to {target_language}. \
    Preserve meaning, tone, numbers, code, URLs and line breaks. Return only the translation.
    {glossary}
    {context}
    """

    public func template(for engine: EngineID, scene: TranslationScene) -> String {
        custom[PromptKey(engine: engine, scene: scene)] ?? Self.defaultTemplate
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, custom }
    private struct Entry: Codable { let engine: EngineID; let scene: TranslationScene; let template: String }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        let entries: [Entry] = c.value(.custom, default: [])
        custom = Dictionary(entries.map { (PromptKey(engine: $0.engine, scene: $0.scene), $0.template) }, uniquingKeysWith: { $1 })
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        let entries = custom.map { Entry(engine: $0.key.engine, scene: $0.key.scene, template: $0.value) }
            .sorted { ($0.engine.raw, $0.scene.rawValue) < ($1.engine.raw, $1.scene.rawValue) }
        try c.encode(entries, forKey: .custom)
    }
}
