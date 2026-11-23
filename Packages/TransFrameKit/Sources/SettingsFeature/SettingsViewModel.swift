import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
@Observable
public final class SettingsViewModel {
    public var selection: SettingsPage = .general
    public private(set) var permissionStates: [PermissionKind: Bool] = [:]
    public private(set) var recording: HotkeyAction?
    public private(set) var shortcutMessage: (action: HotkeyAction, text: String)?
    public var confirmingReset = false

    @ObservationIgnored public let deps: SettingsDependencies
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    public let engines: EnginesModel

    public init(dependencies: SettingsDependencies) {
        deps = dependencies
        engines = EnginesModel(dependencies: dependencies)
    }

    public var settings: any SettingsProviding { deps.settings }
    public var l10n: Localizer { deps.localizer }
    var bindings: SettingsBindings { SettingsBindings(settings: deps.settings) }

    /// Pages in sidebar order. Pages needing workflows only appear when those are wired.
    public var pages: [SettingsPage] {
        var pages: [SettingsPage] = [.general]
        if deps.catalog != nil { pages += [.engines, .prompts] }
        pages += [.languages, .shortcuts, .annotations]
        if deps.catalog != nil { pages += [.privacy, .ai] }
        if deps.glossary != nil { pages.append(.glossary) }
        if deps.catalog != nil { pages.append(.imageHost) }
        return pages
    }

    // MARK: Permissions (SET-02)

    public func refreshPermissions() async {
        for kind in PermissionKind.allCases {
            let granted = await deps.permissions.isGranted(kind)
            if permissionStates[kind] != granted { permissionStates[kind] = granted }
        }
    }

    public func grant(_ kind: PermissionKind) {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            guard let self else { return }
            _ = await deps.permissions.guide(kind, from: nil)
            await refreshPermissions()
        }
    }

    // MARK: Save location (SET-03)

    public var saveLocation: URL {
        settings.general.saveLocationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    public func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveLocation
        panel.prompt = l10n[.settingsGeneralChoose]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.general.saveLocationPath = url.path
    }

    public func revealSaveLocation() { NSWorkspace.shared.activateFileViewerSelecting([saveLocation]) }

    public func resetSaveLocation() { settings.general.saveLocationPath = nil }

    // MARK: Interface language (SET-04, L10N-03)

    public func setInterfaceLanguage(_ language: String?) {
        settings.general.interfaceLanguage = language
        l10n.setPreference(language)
    }

    // MARK: Shortcuts (SET-06)

    public func startRecording(_ action: HotkeyAction) {
        shortcutMessage = nil
        recording = action
    }

    public func cancelRecording() { recording = nil }

    @discardableResult
    public func record(_ key: RecordedKey, for action: HotkeyAction) -> ShortcutValidation {
        let shortcut = GlobalShortcut(keyCode: key.keyCode, modifiers: ShortcutModifiers(rawValue: key.carbonModifiers))
        let result = ShortcutValidation.validate(shortcut, for: action, in: settings.shortcuts)
        switch result {
        case .ok:
            settings.shortcuts[action] = shortcut
            recording = nil
            shortcutMessage = nil
        case .missingModifier:
            shortcutMessage = (action, l10n[.settingsShortcutsNeedsModifier])
        case .conflict(let other):
            shortcutMessage = (action, l10n.string(.settingsShortcutsConflict, l10n.string(rawKey: "hotkey.\(other.rawValue)")))
        }
        return result
    }

    public func resetShortcut(_ action: HotkeyAction) {
        let validation = ShortcutValidation.validate(action.defaultShortcut, for: action, in: settings.shortcuts)
        if case .conflict(let other) = validation {
            shortcutMessage = (action, l10n.string(.settingsShortcutsConflict, l10n.string(rawKey: "hotkey.\(other.rawValue)")))
            return
        }
        settings.shortcuts[action] = action.defaultShortcut
        shortcutMessage = nil
    }

    // MARK: Reset (SET-08)

    public func resetAll() {
        settings.resetAll()
        l10n.setPreference(settings.general.interfaceLanguage)
        confirmingReset = false
    }
}
