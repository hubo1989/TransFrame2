import Foundation
import Observation
import TFDomain

/// The single `SettingsProviding` instance (SPEC §01 §5). Every segment is stored as its own JSON
/// blob and written immediately on change (SET-10). The defaults domain is injected so tests never
/// touch real preferences (SPEC §06 §3).
@MainActor
@Observable
public final class SettingsStore: SettingsProviding {
    public var general: GeneralSettings { didSet { persist(general, oldValue, "general") } }
    public var export: ExportSettings { didSet { persist(export, oldValue, "export") } }
    public var shortcuts: ShortcutSettings { didSet { persist(shortcuts, oldValue, "shortcuts") } }
    public var annotationDefaults: AnnotationDefaults { didSet { persist(annotationDefaults, oldValue, "annotationDefaults") } }
    public var languages: LanguageSettings { didSet { persist(languages, oldValue, "languages") } }
    public var recognition: RecognitionSettings { didSet { persist(recognition, oldValue, "recognition") } }
    public var engines: EngineSettings { didSet { persist(engines, oldValue, "engines") } }
    public var prompts: PromptSettings { didSet { persist(prompts, oldValue, "prompts") } }
    public var presentation: PresentationSettings { didSet { persist(presentation, oldValue, "presentation") } }
    public var privacy: PrivacySettings { didSet { persist(privacy, oldValue, "privacy") } }
    public var ai: AISettings { didSet { persist(ai, oldValue, "ai") } }
    public var history: HistorySettings { didSet { persist(history, oldValue, "history") } }
    public var imageHost: ImageHostSettings { didSet { persist(imageHost, oldValue, "imageHost") } }
    public var onboarding: OnboardingSettings { didSet { persist(onboarding, oldValue, "onboarding") } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let prefix: String
    @ObservationIgnored private var isResetting = false

    public init(defaults: UserDefaults, keyPrefix: String = "settings.") {
        self.defaults = defaults
        prefix = keyPrefix
        func load<T: Decodable>(_ name: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: keyPrefix + name) else { return fallback }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }
        let d = SettingsSnapshot()
        general = load("general", d.general)
        export = load("export", d.export)
        shortcuts = load("shortcuts", d.shortcuts)
        annotationDefaults = load("annotationDefaults", d.annotationDefaults)
        languages = load("languages", d.languages)
        recognition = load("recognition", d.recognition)
        engines = load("engines", d.engines)
        prompts = load("prompts", d.prompts)
        presentation = load("presentation", d.presentation)
        privacy = load("privacy", d.privacy)
        ai = load("ai", d.ai)
        history = load("history", d.history)
        imageHost = load("imageHost", d.imageHost)
        onboarding = load("onboarding", d.onboarding)
    }

    private func persist<T: Encodable & Equatable>(_ value: T, _ old: T, _ name: String) {
        guard value != old || isResetting, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: prefix + name)
    }

    /// Restores every segment to its default (SET-08). Onboarding state is kept so the guide does not reappear.
    public func resetAll() {
        let d = SettingsSnapshot()
        let keepOnboarding = onboarding
        isResetting = true
        general = d.general
        export = d.export
        shortcuts = d.shortcuts
        annotationDefaults = d.annotationDefaults
        languages = d.languages
        recognition = d.recognition
        engines = d.engines
        prompts = d.prompts
        presentation = d.presentation
        privacy = d.privacy
        ai = d.ai
        history = d.history
        imageHost = d.imageHost
        onboarding = keepOnboarding
        isResetting = false
    }
}
