import AboutFeature
import AppKit
import MenuBarFeature
import OnboardingFeature
import SettingsFeature
import TFDesignSystem
import TFDomain
import TFLocalization
import TFPersistenceInfra
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
            )
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
}
