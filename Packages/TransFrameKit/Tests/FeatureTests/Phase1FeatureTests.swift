import Foundation
import Testing
import TFDesignSystem
import TFDomain
import TFDomainTestSupport
import TFLocalization
import TFWorkspaceUI
@testable import MenuBarFeature
@testable import OnboardingFeature
@testable import SettingsFeature

@Suite("Menu model")
@MainActor
struct MenuModelTests {
    @Test func containsEveryEntryWithShortcuts() {
        let l10n = Localizer(preference: "en")
        let items = MenuBuilder.build(shortcuts: ShortcutSettings(), pinCount: 0, localizer: l10n)
        let routes = items.compactMap(\.route)
        #expect(routes == [
            .capture(.region), .capture(.fullDisplay), .capture(.regionThenTranslate), .capture(.scroll),
            .translateSelectedText, .translateAndInsert, .pickColor, .openImage(nil), .openHistory(nil), .openColorHistory,
            .openSettings(nil), .openAbout, .quit,
        ])
        #expect(items.first { $0.route == .capture(.region) }?.shortcut == HotkeyAction.selection.defaultShortcut)
        #expect(items.first { $0.route == .translateSelectedText }?.shortcut == HotkeyAction.textSelectionTranslation.defaultShortcut)
        #expect(items.first { $0.route == .openImage(nil) }?.keyEquivalent?.key == "o")
        #expect(items.first { $0.route == .openHistory(nil) }?.keyEquivalent?.modifiers == [.command, .shift])
        #expect(items.first { $0.route == .quit }?.keyEquivalent?.key == "q")
    }

    @Test func pinSubmenuReflectsCount() {
        let l10n = Localizer(preference: "en")
        let empty = MenuBuilder.build(shortcuts: ShortcutSettings(), pinCount: 0, localizer: l10n)
        guard case .submenu(let children) = empty.first(where: { if case .submenu = $0.kind { true } else { false } })?.kind else {
            Issue.record("no pin submenu"); return
        }
        #expect(children.allSatisfy { !$0.isEnabled })
        let some = MenuBuilder.build(shortcuts: ShortcutSettings(), pinCount: 2, localizer: l10n)
        #expect(some.contains { $0.title == "Pinned Images (2)" })
    }

    @Test func rebuildsWithLanguageAndShortcutChanges() {
        let l10n = Localizer(preference: "en")
        var shortcuts = ShortcutSettings()
        let before = MenuBuilder.build(shortcuts: shortcuts, pinCount: 0, localizer: l10n)
        l10n.setPreference("zh-Hans")
        shortcuts[.selection] = GlobalShortcut(keyCode: 0x00, modifiers: [.control, .option])
        let after = MenuBuilder.build(shortcuts: shortcuts, pinCount: 0, localizer: l10n)
        #expect(after.first?.title == "区域截图")
        #expect(after.first?.title != before.first?.title)
        #expect(after.first?.shortcut?.displayString == "⌃⌥A")
    }
}

@Suite("Settings view model")
@MainActor
struct SettingsViewModelTests {
    private func makeModel() -> (SettingsViewModel, FakeSettings, FakePermissions) {
        let settings = FakeSettings()
        let permissions = FakePermissions(granted: [.screenRecording])
        let l10n = Localizer(preference: "en")
        let router = FakeRouter()
        let presenter = StandardErrorPresenter(localizer: l10n, feedback: FeedbackCenter(), permissions: permissions, router: router)
        let deps = SettingsDependencies(
            settings: settings, localizer: l10n, permissions: permissions, credentials: FakeCredentialStore(),
            unlocker: FakeUnlocker(), catalog: nil, glossary: nil, errors: presenter, router: router
        )
        return (SettingsViewModel(dependencies: deps), settings, permissions)
    }

    @Test func recordsValidShortcutAndRejectsConflictsAndMissingModifiers() {
        let (model, settings, _) = makeModel()
        model.startRecording(.fullScreen)
        let conflict = model.record(RecordedKey(keyCode: 0x15, carbonModifiers: 0x0100 | 0x0200), for: .fullScreen)
        #expect(conflict == .conflict(.selection))
        #expect(model.recording == .fullScreen)
        #expect(model.shortcutMessage?.text.contains("Capture Region") == true)
        #expect(model.record(RecordedKey(keyCode: 0x00, carbonModifiers: 0x0200), for: .fullScreen) == .missingModifier)
        #expect(model.record(RecordedKey(keyCode: 0x00, carbonModifiers: 0x0100 | 0x0800), for: .fullScreen) == .ok)
        #expect(settings.shortcuts[.fullScreen].displayString == "⌥⌘A")
        #expect(model.recording == nil)
        model.resetShortcut(.fullScreen)
        #expect(settings.shortcuts[.fullScreen] == HotkeyAction.fullScreen.defaultShortcut)
    }

    @Test func languageChangeAppliesImmediately() {
        let (model, settings, _) = makeModel()
        model.setInterfaceLanguage("ja")
        #expect(settings.general.interfaceLanguage == "ja")
        #expect(model.l10n.language == "ja")
        model.setInterfaceLanguage(nil)
        #expect(settings.general.interfaceLanguage == nil)
    }

    @Test func permissionsRefreshAndGuide() async {
        let (model, _, permissions) = makeModel()
        await model.refreshPermissions()
        #expect(model.permissionStates[.screenRecording] == true)
        #expect(model.permissionStates[.accessibility] == false)
        permissions.grantWhenGuided.current = true
        model.grant(.accessibility)
        for _ in 0..<50 where model.permissionStates[.accessibility] != true { await Task.yield() }
        #expect(permissions.guided.calls == [.accessibility])
    }

    @Test func resetAllRestoresDefaults() {
        let (model, settings, _) = makeModel()
        settings.export.format = .heic
        model.resetAll()
        #expect(settings.resetCount == 1)
        #expect(settings.export.format == .png)
    }

    @Test func pagesWithoutWorkflowsAreHidden() {
        let (model, _, _) = makeModel()
        #expect(model.pages == [.general, .languages, .shortcuts, .annotations])
    }
}

@Suite("Onboarding")
@MainActor
struct OnboardingTests {
    @Test func threeStepsThenFinishMarksCompletion() async {
        let settings = FakeSettings()
        let permissions = FakePermissions(granted: [])
        let model = OnboardingViewModel(permissions: permissions, settings: settings, appVersion: "2.0.0")
        var finished = false
        model.onFinish = { finished = true }
        #expect(model.step == .welcome)
        model.next()
        #expect(model.step == .permissions)
        await model.refresh()
        #expect(model.skippedPermissions == [.screenRecording, .accessibility])
        permissions.grantWhenGuided.current = true
        await model.grant(.screenRecording, from: nil)
        #expect(model.skippedPermissions == [.accessibility])
        model.next()
        #expect(model.step == .complete)
        model.next()
        #expect(finished)
        #expect(settings.onboarding.completed)
        #expect(settings.onboarding.completedVersion == "2.0.0")
    }

    @Test func backNavigation() {
        let model = OnboardingViewModel(permissions: FakePermissions(), settings: FakeSettings(), appVersion: "2")
        #expect(!model.canGoBack)
        model.next()
        model.back()
        #expect(model.step == .welcome)
    }
}
