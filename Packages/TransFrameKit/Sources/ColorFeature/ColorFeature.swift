import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol ColorPickCoordinating: AnyObject {
    func pick()
}

/// Screen color picking: system sampler → copy HEX → history → toast with a history link (COL-01, COL-02).
@MainActor
public final class ColorCoordinator: ColorPickCoordinating {
    private let workflow: any ColorPickWorkflow
    private let settings: any SettingsProviding
    private let localizer: Localizer
    private let errors: any ErrorPresenting
    private let router: any AppRouting
    private var picking = false

    public init(workflow: any ColorPickWorkflow, settings: any SettingsProviding, localizer: Localizer, errors: any ErrorPresenting, router: any AppRouting) {
        self.workflow = workflow
        self.settings = settings
        self.localizer = localizer
        self.errors = errors
        self.router = router
    }

    public func pick() {
        guard !picking else { return }
        picking = true
        Task {
            defer { picking = false }
            do {
                guard let color = try await workflow.pickAndCopy(settings: settings.snapshot) else { return }
                errors.toast(
                    ToastModel(message: localizer.string(.feedbackColorCopied, color.hexString), actionTitle: localizer[.colorViewHistory]), near: nil
                ) { [router] in
                    router.route(.openColorHistory)
                }
            } catch {
                errors.present(error, near: nil) { [weak self] in self?.pick() }
            }
        }
    }
}
