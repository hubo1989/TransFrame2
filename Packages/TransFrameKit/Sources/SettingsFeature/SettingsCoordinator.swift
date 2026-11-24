import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol SettingsCoordinating: AnyObject {
    func show(page: SettingsPage?)
}

/// Dependencies of the settings window, all Domain protocols (SPEC §01 §3.3).
@MainActor
public struct SettingsDependencies {
    public let settings: any SettingsProviding
    public let localizer: Localizer
    public let permissions: any PermissionChecking & PermissionGuiding
    public let credentials: any CredentialStoring
    public let unlocker: any CredentialUnlocking
    public let catalog: (any EngineCatalogProviding)?
    public let glossary: (any GlossaryWorkflow)?
    public let errors: any ErrorPresenting
    public let router: any AppRouting
    public let pasteboard: (any PasteboardAccessing)?
    public let osVersion: OSVersion

    public init(
        settings: any SettingsProviding, localizer: Localizer, permissions: any PermissionChecking & PermissionGuiding,
        credentials: any CredentialStoring, unlocker: any CredentialUnlocking, catalog: (any EngineCatalogProviding)?,
        glossary: (any GlossaryWorkflow)?, errors: any ErrorPresenting, router: any AppRouting,
        pasteboard: (any PasteboardAccessing)? = nil, osVersion: OSVersion = .current
    ) {
        self.settings = settings
        self.localizer = localizer
        self.permissions = permissions
        self.credentials = credentials
        self.unlocker = unlocker
        self.catalog = catalog
        self.glossary = glossary
        self.errors = errors
        self.router = router
        self.pasteboard = pasteboard
        self.osVersion = osVersion
    }
}

@MainActor
public final class SettingsCoordinator: NSObject, SettingsCoordinating, NSWindowDelegate {
    private let dependencies: SettingsDependencies
    private var window: NSWindow?
    private var model: SettingsViewModel?

    public init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    public func show(page: SettingsPage?) {
        if let window, let model {
            if let page { model.selection = page }
            WindowFactory.present(window)
            return
        }
        let model = SettingsViewModel(dependencies: dependencies)
        if let page { model.selection = page }
        let root = SettingsRootView(model: model).localized(dependencies.localizer)
        let window = WindowFactory.makeWindow(
            title: dependencies.localizer[.settingsTitle], content: root, size: NSSize(width: 760, height: 560),
            minSize: NSSize(width: 680, height: 460), autosaveName: "TF2.SettingsWindow"
        )
        window.delegate = self
        window.toolbarStyle = .unified
        self.window = window
        self.model = model
        WindowFactory.present(window)
        observeTitle()
    }

    private func observeTitle() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            window?.title = dependencies.localizer[.settingsTitle]
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTitle() }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        model?.cancelRecording()
        model = nil
        window = nil
    }
}
