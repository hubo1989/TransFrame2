import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol CaptureCoordinating: AnyObject {
    func start(_ intent: CaptureIntent, trigger: CaptureTrigger, at instant: ContinuousClock.Instant)
    var isActive: Bool { get }
}

@MainActor
public struct CaptureDependencies {
    public let workspace: WorkspaceServices
    public let capture: any CaptureWorkflow
    public let topology: any DisplayTopologyProviding
    public let permissions: any PermissionChecking & PermissionGuiding
    public let scroll: (any ScrollCaptureWorkflow)?
    public let sound: any SoundPlaying

    public init(
        workspace: WorkspaceServices, capture: any CaptureWorkflow, topology: any DisplayTopologyProviding,
        permissions: any PermissionChecking & PermissionGuiding, scroll: (any ScrollCaptureWorkflow)?, sound: any SoundPlaying
    ) {
        self.workspace = workspace
        self.capture = capture
        self.topology = topology
        self.permissions = permissions
        self.scroll = scroll
        self.sound = sound
    }
}

/// Entry point for every capture intent (CAP-01…CAP-22, INP-*). One session at a time (CAP-03).
@MainActor
public final class CaptureCoordinator: CaptureCoordinating {
    private let deps: CaptureDependencies
    private var controller: CaptureController?
    private var starting = false

    public init(dependencies: CaptureDependencies) {
        deps = dependencies
    }

    public var isActive: Bool { controller != nil || starting }

    public func start(_ intent: CaptureIntent, trigger: CaptureTrigger, at instant: ContinuousClock.Instant) {
        guard !isActive else { return }
        starting = true
        let pointer = deps.topology.pointerLocation()
        Task { [weak self] in
            guard let self else { return }
            defer { self.starting = false }
            guard await deps.permissions.isGranted(.screenRecording) else {
                _ = await deps.permissions.guide(.screenRecording, from: nil)
                return
            }
            let request = CaptureRequest(intent: intent, trigger: trigger, triggerInstant: instant, pointer: pointer)
            do {
                let frames = try await deps.capture.freeze(request)
                if intent == .fullDisplay {
                    try await captureFullDisplay(frames)
                } else {
                    var created: CaptureController?
                    let controller = CaptureController(frames: frames, deps: deps) { [weak self] in
                        if self?.controller === created { self?.controller = nil }
                    }
                    created = controller
                    self.controller = controller
                    starting = false
                    controller.present()
                }
            } catch {
                deps.workspace.errors.present(error, near: nil)
            }
        }
    }

    /// Full screen: no selection UI; the display under the pointer is copied and opened in the editor (CAP-16).
    private func captureFullDisplay(_ frames: FrozenFrameSet) async throws(AppError) {
        guard let display = frames.topology.display(containing: frames.request.pointer) else { throw .capture(.noDisplays) }
        let geometry = SelectionGeometry(rect: display.frame, source: .display(display.id), topologyVersion: frames.topology.version)
        let services = deps.workspace
        let id = try await services.sessions.create(from: frames, selection: geometry)
        let owner = SessionOwner.capture(frames.request.id)
        await services.sessions.retain(id, by: owner)
        defer {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await services.sessions.release(id, by: owner)
            }
        }
        try await services.export.copyImage(of: id, settings: services.settings.snapshot)
        services.router.route(.openEditor(id, focus: nil))
    }
}
