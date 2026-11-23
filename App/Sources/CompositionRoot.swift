import AboutFeature
import AppKit
import CaptureFeature
import ColorFeature
import EditorFeature
import HistoryFeature
import MenuBarFeature
import PinFeature
import OnboardingFeature
import SettingsFeature
import TextTranslationFeature
import TFAIInfra
import TFDesignSystem
import TFDomain
import TFCaptureInfra
import TFLocalization
import TFNetworkInfra
import TFPersistenceInfra
import TFPipelines
import TFRecognitionInfra
import TFRenderInfra
import TFSystemInfra
import TFTranslationInfra
import TFUploadInfra
import TFWorkspaceUI

/// The only place that names concrete Infrastructure types (SPEC §01 §4, ADR-0003).
/// Order: infrastructure → pipelines → feature coordinators → app coordinator.
@MainActor
final class CompositionRoot {
    let environment: AppEnvironment
    let coordinator: AppCoordinator

    // Process-wide single instances, created here and injected (no singletons outside App/).
    let settings: SettingsStore
    let localizer: Localizer
    let feedback = FeedbackCenter()
    let permissions: PermissionService
    let hotkeys = HotkeyCenter()
    let unlocker = SessionUnlocker()
    let credentials: KeychainCredentialStore
    let updater: SparkleUpdater
    let runningApps = RunningAppService()
    let logger: OSEventLogger
    let errors: StandardErrorPresenter
    let performance = PerformanceRecorder()
    let topology = DisplayTopologyService()
    let pasteboard = SystemPasteboard()
    let sound = SystemSound()
    let renderer = CoreGraphicsRenderer()
    let codec = ImageCodec()
    let files = FileExporter()
    let sessions = DocumentSessionStore(composer: FrameComposer())

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = SettingsStore(defaults: .standard)
        localizer = Localizer(preference: settings.general.interfaceLanguage)
        permissions = PermissionService(appURL: environment.appURL)
        let unlocker = self.unlocker
        credentials = KeychainCredentialStore(service: environment.credentialService) {
            await MainActor.run { unlocker.isUnlocked }
        }
        updater = SparkleUpdater(bundle: .main)
        logger = OSEventLogger(subsystem: environment.bundleID)
        errors = StandardErrorPresenter(localizer: localizer, feedback: feedback, permissions: permissions, router: nil)

        let coordinator = AppCoordinator(environment: environment)
        self.coordinator = coordinator

        let features = makeFeatures(makePipelines())
        errors.attach(router: coordinator)
        coordinator.attach(services: AppServices(
            settings: settings, localizer: localizer, hotkeys: hotkeys, permissions: permissions, unlocker: unlocker,
            credentials: credentials, updater: updater, runningApps: runningApps, errors: errors, feedback: feedback, logger: logger
        ), features: features)
    }

    private struct Pipelines {
        let snapshotter: ScreenSnapshotter
        let capture: CaptureService
        let colorPick: ColorPickService
        let history: HistoryService
        let workspace: WorkspaceServices
        let glossary: GlossaryService
        let textTranslation: TextTranslationService
        let catalog: EngineCatalogService
    }

    private func makePipelines() -> Pipelines {
        // Pipelines over infrastructure.
        let snapshotter = ScreenSnapshotter(topology: topology, windows: WindowEnumerator())
        let render = RenderService(sessions: sessions, planner: RenderPlanner(measurer: renderer), executor: renderer, performance: performance)
        let history = makeHistory()
        let transport = URLSessionTransport()
        let credentials = credentials
        let secrets: @Sendable (CredentialRef) async throws(AppError) -> String? = { ref throws(AppError) in try await credentials.secret(for: ref) }
        let detector = LocalSensitiveContentDetector()
        let guardian = PrivacyGuard(detector: detector)
        let uploader = ImageUploader(transport: transport, secrets: secrets)
        let translationEngines = TranslationEngineFactory(transport: transport, secrets: secrets)
        let generators = TextGeneratorProvider(transport: transport, secrets: secrets) { [translationEngines] in translationEngines.descriptors(for: $0) }
        let namer = makeNamer(generators)
        let export = ExportService(
            sessions: sessions, render: render, pasteboard: pasteboard, encoder: codec, files: files, sound: sound,
            uploader: uploader, history: history, namer: namer,
            guardian: guardian, defaultDirectory: { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
        )
        let colorPick = ColorPickService(sampler: ScreenColorSampler(), pasteboard: pasteboard, history: history)
        let capture = CaptureService(snapshotter: snapshotter, blocks: LocalContentBlockDetector(), performance: performance)
        let recognitionEngines = RecognitionEngineFactory(transport: transport, secrets: secrets)
        let recognition = RecognitionService(
            sessions: sessions, render: render, engines: recognitionEngines, guardian: guardian, performance: performance
        )
        let translation = TranslationService(engines: translationEngines, performance: performance)
        let glossaryStore = GlossaryFileStore(url: environment.isUITest ? nil : environment.supportDirectory.appending(path: "Glossary.json"))
        let glossary = GlossaryService(store: glossaryStore, sessions: sessions)
        let pipeline = DocumentPipelineService(
            sessions: sessions, recognition: recognition, translation: translation, history: history, thumbnails: codec,
            glossary: glossaryStore, codes: VisionCodeDetector(), detector: detector
        )
        Task { await snapshotter.prewarm() }
        let workspace = WorkspaceServices(
            sessions: sessions, render: render, export: export, pipeline: pipeline, glossary: glossary, colorPick: colorPick,
            pasteboard: pasteboard, settings: settings, localizer: localizer, errors: errors, router: coordinator, performance: performance
        )
        let textAccess = AccessibilityTextService(pasteboard: pasteboard)
        let textTranslation = TextTranslationService(
            capturer: textAccess, inserter: textAccess, pasteboard: pasteboard, translation: translation, pipeline: pipeline,
            history: history, generators: generators
        )
        let catalog = EngineCatalogService(
            translation: translationEngines, discovery: translationEngines,
            health: EngineHealthProber(factory: translationEngines, transport: transport), recognition: recognitionEngines,
            paddle: PaddleInstallationService(), generators: generators, uploader: uploader, encoder: codec
        )
        return Pipelines(
            snapshotter: snapshotter, capture: capture, colorPick: colorPick, history: history, workspace: workspace,
            glossary: glossary, textTranslation: textTranslation, catalog: catalog
        )
    }

    private func makeNamer(_ generators: TextGeneratorProvider) -> FileNamer {
        FileNamer { session, settings in
            guard let generator = await generators.generator(for: settings.ai.generationEngine, settings: settings),
                  generator.descriptor.locality == .onDevice || settings.ai.autoNamingAllowsCloud else { return nil }
            let input = PrivacyGuard.namingInput(session: session, settings: settings, locality: generator.descriptor.locality)
            guard !input.isEmpty else { return nil }
            return try? await generator.generate(GenerationRequest(task: .suggestFileName, input: input, maxOutputCharacters: 60))
        }
    }

    private func makeHistory() -> HistoryService {
        do {
            let directory = environment.isUITest ? nil : environment.supportDirectory
            let store = try SwiftDataHistoryStore.open(directory: directory)
            return HistoryService(
                store: store, files: files, embedding: NaturalLanguageEmbedding(),
                index: store, storeOwnsIndex: true, performance: performance
            )
        } catch {
            errors.present(error, near: nil)
            return HistoryService(store: InMemoryHistoryStore(), files: files, performance: performance)
        }
    }

    private func makeFeatures(_ pipelines: Pipelines) -> AppFeatures {
        let sessions = sessions, codec = codec, coordinator = coordinator
        let workspace = pipelines.workspace, textTranslation = pipelines.textTranslation
        let snapshotter = pipelines.snapshotter, capture = pipelines.capture
        let history = pipelines.history, colorPick = pipelines.colorPick
        let catalog = pipelines.catalog, glossary = pipelines.glossary
        return AppFeatures(
            menuBar: MenuBarCoordinator(
                settings: settings, localizer: localizer, router: coordinator,
                image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil),
                pinCount: { [weak coordinator] in coordinator?.pinCount ?? 0 },
                canPolish: { [textTranslation] settings in await textTranslation.canPolish(settings: settings) }
            ),
            settings: SettingsCoordinator(dependencies: SettingsDependencies(
                settings: settings, localizer: localizer, permissions: permissions, credentials: credentials,
                unlocker: unlocker, catalog: catalog, glossary: glossary, errors: errors, router: coordinator, pasteboard: pasteboard
            )),
            onboarding: OnboardingCoordinator(
                permissions: permissions, settings: settings, localizer: localizer, appVersion: environment.version
            ),
            about: AboutCoordinator(
                info: AppInfo(version: environment.version, build: environment.build, copyright: environment.copyright, projectURL: environment.projectURL),
                localizer: localizer, router: coordinator, canCheckForUpdates: { [updater] in updater.canCheckForUpdates }
            ),
            capture: CaptureCoordinator(dependencies: CaptureDependencies(
                workspace: workspace, capture: capture, topology: topology, permissions: permissions,
                scroll: ScrollCaptureService(capturer: snapshotter, sessions: sessions), sound: sound
            )),
            editor: EditorCoordinator(services: workspace) { url throws(AppError) in
                guard let data = try? Data(contentsOf: url) else { throw .recognition(.imageUnreadable) }
                let image = try codec.decode(data)
                return await sessions.create(importing: image, name: url.lastPathComponent)
            },
            pins: PinCoordinator(services: workspace),
            history: HistoryCoordinator(workflow: history, colors: colorPick, settings: settings, localizer: localizer, errors: errors, pasteboard: pasteboard),
            text: TextTranslationCoordinator(
                workflow: textTranslation, settings: settings, localizer: localizer, feedback: feedback, errors: errors,
                permissions: permissions, pasteboard: pasteboard
            ),
            color: ColorCoordinator(workflow: colorPick, settings: settings, localizer: localizer, errors: errors, router: coordinator)
        )
    }

}

struct AppServices {
    let settings: SettingsStore
    let localizer: Localizer
    let hotkeys: HotkeyCenter
    let permissions: PermissionService
    let unlocker: SessionUnlocker
    let credentials: KeychainCredentialStore
    let updater: SparkleUpdater
    let runningApps: RunningAppService
    let errors: StandardErrorPresenter
    let feedback: FeedbackCenter
    let logger: OSEventLogger
}

struct AppFeatures {
    let menuBar: MenuBarCoordinator
    let settings: SettingsCoordinator
    let onboarding: OnboardingCoordinator
    let about: AboutCoordinator
    let capture: CaptureCoordinator
    let editor: EditorCoordinator
    let pins: PinCoordinator
    let history: HistoryCoordinator
    let text: TextTranslationCoordinator
    let color: ColorCoordinator
}
