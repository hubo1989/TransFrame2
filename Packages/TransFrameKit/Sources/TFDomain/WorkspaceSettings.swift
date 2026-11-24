import Foundation

public enum ResultDisplayMode: String, Sendable, Codable, CaseIterable { case textDrawer, inPlace }

public struct PresentationSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var defaultDisplay: ResultDisplayMode = .inPlace
    public var overlayMode: OverlayMode = .belowOriginal
    /// Choose the on-image mode from the layout (dense lines → replace, spaced lines → below); `overlayMode` applies when off.
    public var automaticOverlay = true

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, defaultDisplay, overlayMode, automaticOverlay }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PresentationSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        defaultDisplay = c.value(.defaultDisplay, default: d.defaultDisplay)
        overlayMode = c.value(.overlayMode, default: d.overlayMode)
        automaticOverlay = c.value(.automaticOverlay, default: d.automaticOverlay)
    }
}

public struct PrivacySettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var guardEnabled = true
    public var redactedCategories: Set<SensitiveCategory> = SensitiveCategory.defaultRedacted
    public var confidenceThreshold = 0.8
    public var guardLocalNetwork = false
    /// Whether app name and window title are sent to language-model engines (AI-04).
    public var sendContext = true
    /// Smart mosaic may use a cloud vision model when explicitly enabled (INP-08).
    public var cloudEnhancedDetection = false

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, guardEnabled, redactedCategories, confidenceThreshold, guardLocalNetwork, sendContext, cloudEnhancedDetection
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrivacySettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        guardEnabled = c.value(.guardEnabled, default: d.guardEnabled)
        redactedCategories = c.value(.redactedCategories, default: d.redactedCategories)
        confidenceThreshold = c.value(.confidenceThreshold, default: d.confidenceThreshold)
        guardLocalNetwork = c.value(.guardLocalNetwork, default: d.guardLocalNetwork)
        sendContext = c.value(.sendContext, default: d.sendContext)
        cloudEnhancedDetection = c.value(.cloudEnhancedDetection, default: d.cloudEnhancedDetection)
    }
}

public enum AIEngineChoice: Sendable, Codable, Equatable, Hashable {
    case automatic
    case engine(EngineID)
}

public struct AISettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var generationEngine: AIEngineChoice = .automatic
    public var defaultTone: ToneStyle?
    /// Off by default so saved names stay `Screenshot <date> at <time>` (EXP-01) unless the user opts in (AI-07).
    public var autoNaming = false
    public var autoNamingAllowsCloud = false
    public var semanticSearch = true
    public var structuredRecognition = true

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generationEngine, defaultTone, autoNaming, autoNamingAllowsCloud, semanticSearch, structuredRecognition
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        generationEngine = c.value(.generationEngine, default: d.generationEngine)
        defaultTone = c.value(.defaultTone, default: d.defaultTone)
        autoNaming = c.value(.autoNaming, default: d.autoNaming)
        autoNamingAllowsCloud = c.value(.autoNamingAllowsCloud, default: d.autoNamingAllowsCloud)
        semanticSearch = c.value(.semanticSearch, default: d.semanticSearch)
        structuredRecognition = c.value(.structuredRecognition, default: d.structuredRecognition)
    }
}

public struct HistorySettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var limit = 500

    public init() {}
    public static let limitRange = 50...5000
    private enum CodingKeys: String, CodingKey { case schemaVersion, limit }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        limit = c.value(.limit, default: 500)
    }
}

public struct ImageHostSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    /// nil disables uploading (the toolbar button stays hidden).
    public var provider: EngineID?
    public var picgoEndpoint = "http://127.0.0.1:36677/upload"
    /// Per-provider non-secret fields: bucket, region, endpoint, accessKeyID, domain, pathPrefix.
    public var fields: [String: [String: String]] = [:]

    public init() {}

    public func field(_ name: String, for provider: EngineID) -> String { fields[provider.raw]?[name] ?? "" }
    public mutating func setField(_ name: String, _ value: String, for provider: EngineID) {
        fields[provider.raw, default: [:]][name] = value
    }

    public static let providers: [EngineID] = [.hostPicGo, .hostOSS, .hostCOS, .hostKodo]

    private enum CodingKeys: String, CodingKey { case schemaVersion, provider, picgoEndpoint, fields }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageHostSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        provider = c.value(.provider, default: d.provider)
        picgoEndpoint = c.value(.picgoEndpoint, default: d.picgoEndpoint)
        fields = c.value(.fields, default: d.fields)
    }
}

public struct OnboardingSettings: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var completed = false
    public var completedVersion: String?

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, completed, completedVersion }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        completed = c.value(.completed, default: false)
        completedVersion = c.value(.completedVersion, default: nil)
    }
}

/// Immutable copy of every segment, for code that runs off the main actor.
public struct SettingsSnapshot: Sendable, Equatable {
    public var general = GeneralSettings()
    public var export = ExportSettings()
    public var shortcuts = ShortcutSettings()
    public var annotationDefaults = AnnotationDefaults()
    public var languages = LanguageSettings()
    public var recognition = RecognitionSettings()
    public var engines = EngineSettings()
    public var prompts = PromptSettings()
    public var presentation = PresentationSettings()
    public var privacy = PrivacySettings()
    public var ai = AISettings()
    public var history = HistorySettings()
    public var imageHost = ImageHostSettings()
    public var onboarding = OnboardingSettings()

    public init() {}
}

/// The single settings owner (SPEC §01 §5). Each segment is an independently observable property.
@MainActor
public protocol SettingsProviding: AnyObject, Sendable {
    var general: GeneralSettings { get set }
    var export: ExportSettings { get set }
    var shortcuts: ShortcutSettings { get set }
    var annotationDefaults: AnnotationDefaults { get set }
    var languages: LanguageSettings { get set }
    var recognition: RecognitionSettings { get set }
    var engines: EngineSettings { get set }
    var prompts: PromptSettings { get set }
    var presentation: PresentationSettings { get set }
    var privacy: PrivacySettings { get set }
    var ai: AISettings { get set }
    var history: HistorySettings { get set }
    var imageHost: ImageHostSettings { get set }
    var onboarding: OnboardingSettings { get set }

    func resetAll()
}

extension SettingsProviding {
    public var snapshot: SettingsSnapshot {
        var s = SettingsSnapshot()
        s.general = general
        s.export = export
        s.shortcuts = shortcuts
        s.annotationDefaults = annotationDefaults
        s.languages = languages
        s.recognition = recognition
        s.engines = engines
        s.prompts = prompts
        s.presentation = presentation
        s.privacy = privacy
        s.ai = ai
        s.history = history
        s.imageHost = imageHost
        s.onboarding = onboarding
        return s
    }
}
