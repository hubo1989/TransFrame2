import AppKit
import Observation
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

/// Routes every `AppRoute` to the owning feature coordinator (SPEC §01 §4).
@MainActor
final class AppCoordinator: AppRouting {
    private let environment: AppEnvironment
    private var services: AppServices!
    private var features: AppFeatures!
    var pinCount: Int { features?.pins.count ?? 0 }
    private var registeredShortcuts: ShortcutSettings?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func attach(services: AppServices, features: AppFeatures) {
        self.services = services
        self.features = features
    }

    // MARK: Launch

    func start(launchedAt: ContinuousClock.Instant) {
        features.menuBar.install()
        services.logger.log(.info, category: "launch", "menu ready in \(ContinuousClock.now - launchedAt)")
        if environment.isSmokeTest {
            // CI launch smoke test (SPEC §06 §6): the marker proves the app reached a usable state.
            print("TF2_MENU_READY")
            NSApp.terminate(nil)
            return
        }
        guard !environment.isUITest else { return }
        Task { await launchSequence() }
    }

    private func launchSequence() async {
        let failed = await registerHotkeys()
        observeShortcuts()
        observeLanguage()
        await checkCoexistence(failedActions: failed)
        if await services.credentials.hasAnySecret() {
            _ = await services.unlocker.unlock(reason: services.localizer[.unlockReason])
        }
        if services.settings.onboarding.completed {
            services.updater.start()
        } else {
            features.onboarding.show { [weak self] in self?.services.updater.start() }
        }
    }

    // MARK: Hotkeys (APP-04, APP-05)

    @discardableResult
    private func registerHotkeys() async -> [HotkeyAction] {
        let shortcuts = services.settings.shortcuts
        registeredShortcuts = shortcuts
        return await services.hotkeys.register(shortcuts.bindings) { [weak self] action, instant in
            MainActor.assumeIsolated { self?.handleHotkey(action, at: instant) }
        }
    }

    private func observeShortcuts() {
        withObservationTracking { _ = services.settings.shortcuts } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if services.settings.shortcuts != registeredShortcuts {
                    let failed = await registerHotkeys()
                    if !failed.isEmpty { presentHotkeyFailure(failed) }
                }
                observeShortcuts()
            }
        }
    }

    private func observeLanguage() {
        withObservationTracking { _ = services.settings.general.interfaceLanguage } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                services.localizer.setPreference(services.settings.general.interfaceLanguage)
                observeLanguage()
            }
        }
    }

    private func handleHotkey(_ action: HotkeyAction, at instant: ContinuousClock.Instant) {
        route(action.route, triggeredAt: instant, trigger: .hotkey)
    }

    // MARK: Coexistence with 1.x (N-14, D24)

    private func checkCoexistence(failedActions: [HotkeyAction]) async {
        let l = services.localizer
        let legacy = await services.runningApps.running(bundleIDs: AppEnvironment.legacyBundleIDs)
        if let first = legacy.first {
            let choice = SystemAlert.present(
                title: l[.coexistenceTitle], message: l[.coexistenceMessage],
                buttons: [
                    AlertButton(l[.coexistenceQuitLegacy]), AlertButton(l[.coexistenceChangeShortcuts]),
                    AlertButton(l[.coexistenceIgnore], role: .cancel),
                ]
            )
            switch choice {
            case 0:
                _ = await services.runningApps.terminate(processID: first.processID)
                try? await Task.sleep(for: .milliseconds(600))
                let stillFailed = await registerHotkeys()
                if !stillFailed.isEmpty { presentHotkeyFailure(stillFailed) }
            case 1: route(.openSettings(.shortcuts))
            default: break
            }
        } else if !failedActions.isEmpty {
            presentHotkeyFailure(failedActions)
        }
    }

    private func presentHotkeyFailure(_ actions: [HotkeyAction]) {
        let l = services.localizer
        let names = actions.map { l.string(rawKey: "hotkey.\($0.rawValue)") }.joined(separator: "、")
        let choice = SystemAlert.present(
            title: l[.hotkeyFailureTitle], message: l.string(.hotkeyFailureMessage, names),
            buttons: [AlertButton(l[.coexistenceChangeShortcuts]), AlertButton(l[.coexistenceIgnore], role: .cancel)]
        )
        if choice == 0 { route(.openSettings(.shortcuts)) }
    }

    // MARK: Routing

    func route(_ route: AppRoute) {
        self.route(route, triggeredAt: .now, trigger: .menu)
    }

    func route(_ route: AppRoute, triggeredAt instant: ContinuousClock.Instant, trigger: CaptureTrigger) {
        switch route {
        case .capture(let intent): features.capture.start(intent, trigger: trigger, at: instant)
        case .pickColor: features.color.pick()
        case .openHistory(let query): features.history.showHistory(query)
        case .openColorHistory: features.history.showColorHistory()
        case .translateSelectedText: features.text.translateSelection()
        case .translateAndInsert: features.text.translateAndInsert()
        case .polishSelection: features.text.polishSelection()
        case .openImage(let url): features.editor.openImage(url)
        case .openEditor(let id, let focus): features.editor.open(id, focus: focus)
        case .pin(let id): features.pins.pin(id)
        case .restorePinInteractions: features.pins.restoreInteractions()
        case .showAllPins: features.pins.showAll()
        case .openSettings(let page): features.settings.show(page: page)
        case .openOnboarding: features.onboarding.show {}
        case .openAbout: features.about.show()
        case .checkForUpdates: services.updater.checkForUpdates()
        case .quit:
            services.hotkeys.unregisterAllNow()
            NSApp.terminate(nil)
        default:
            services.logger.log(.debug, category: "route", "unhandled route")
        }
    }

    func shutdown() {
        services?.hotkeys.unregisterAllNow()
    }
}
