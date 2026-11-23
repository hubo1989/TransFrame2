import AboutFeature
import AppKit
import CaptureFeature
import ColorFeature
import EditorFeature
import MenuBarFeature
import PinFeature
import OnboardingFeature
import SettingsFeature
import TFDesignSystem
import TFDomain
import TFCaptureInfra
import TFLocalization
import TFPersistenceInfra
import TFPipelines
import TFRenderInfra
import TFSystemInfra
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

        // Pipelines over infrastructure.
        let snapshotter = ScreenSnapshotter(topology: topology, windows: WindowEnumerator())
        let render = RenderService(sessions: sessions, planner: RenderPlanner(measurer: renderer), executor: renderer, performance: performance)
        let history = HistoryService(store: InMemoryHistoryStore(), files: files, performance: performance)
        let export = ExportService(
            sessions: sessions, render: render, pasteboard: pasteboard, encoder: codec, files: files, sound: sound,
            uploader: nil, history: history, namer: FileNamer(),
            defaultDirectory: { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
        )
        let colorPick = ColorPickService(sampler: ScreenColorSampler(), pasteboard: pasteboard, history: history)
        let capture = CaptureService(snapshotter: snapshotter, blocks: nil, performance: performance)
        Task { await snapshotter.prewarm() }
        let workspace = WorkspaceServices(
            sessions: sessions, render: render, export: export, pipeline: nil, glossary: nil, colorPick: colorPick,
            pasteboard: pasteboard, settings: settings, localizer: localizer, errors: errors, router: coordinator, performance: performance
        )
        let sessions = sessions, codec = codec

        let features = AppFeatures(
            menuBar: MenuBarCoordinator(
                settings: settings, localizer: localizer, router: coordinator,
                image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil),
                pinCount: { [weak coordinator] in coordinator?.pinCount ?? 0 }
            ),
            settings: SettingsCoordinator(dependencies: SettingsDependencies(
                settings: settings, localizer: localizer, permissions: permissions, credentials: credentials,
                unlocker: unlocker, catalog: nil, glossary: nil, errors: errors, router: coordinator
            )),
            onboarding: OnboardingCoordinator(
                permissions: permissions, settings: settings, localizer: localizer, appVersion: environment.version
            ),
            about: AboutCoordinator(
                info: AppInfo(version: environment.version, build: environment.build, copyright: environment.copyright, projectURL: environment.projectURL),
                localizer: localizer, router: coordinator, canCheckForUpdates: { [updater] in updater.canCheckForUpdates }
            ),
            capture: CaptureCoordinator(dependencies: CaptureDependencies(
                workspace: workspace, capture: capture, topology: topology, permissions: permissions, scroll: nil, sound: sound
            )),
            editor: EditorCoordinator(services: workspace) { url throws(AppError) in
                guard let data = try? Data(contentsOf: url) else { throw .recognition(.imageUnreadable) }
                let image = try codec.decode(data)
                return await sessions.create(importing: image, name: url.lastPathComponent)
            },
            pins: PinCoordinator(services: workspace),
            color: ColorCoordinator(workflow: colorPick, settings: settings, localizer: localizer, errors: errors, router: coordinator)
        )
        errors.attach(router: coordinator)
        coordinator.attach(services: AppServices(
            settings: settings, localizer: localizer, hotkeys: hotkeys, permissions: permissions, unlocker: unlocker,
            credentials: credentials, updater: updater, runningApps: runningApps, errors: errors, feedback: feedback, logger: logger
        ), features: features)
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
    let color: ColorCoordinator
}
