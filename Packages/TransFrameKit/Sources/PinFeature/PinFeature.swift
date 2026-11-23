import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol PinCoordinating: AnyObject {
    func pin(_ id: SessionID)
    func restoreInteractions()
    func showAll()
    var count: Int { get }
}

/// Pinned screenshots (PIN-01…PIN-12). At most ten (PIN-10).
@MainActor
public final class PinCoordinator: PinCoordinating {
    public static let limit = 10
    private let services: WorkspaceServices
    private var pins: [UUID: PinController] = [:]

    public init(services: WorkspaceServices) {
        self.services = services
    }

    public var count: Int { pins.count }

    public func pin(_ id: SessionID) {
        guard pins.count < Self.limit else {
            services.errors.toast(ToastModel(.warning, message: services.localizer.string(.pinLimitReached, Self.limit)), near: nil)
            return
        }
        let key = UUID()
        let controller = PinController(services: services, sessionID: id, key: key) { [weak self] in self?.pins[key] = nil }
        pins[key] = controller
        controller.show(offset: Double(pins.count - 1) * 24)
    }

    public func restoreInteractions() { pins.values.forEach { $0.setClickThrough(false) } }
    public func showAll() { pins.values.forEach { $0.bringToFront() } }
}

@MainActor
@Observable
final class PinState {
    var zoom = 1.0
    var opacity = 1.0
    var clickThrough = false
    var keepsOnTop = true
    var hovering = false

    static let zoomRange = 0.25...4.0
    static let opacityRange = 0.2...1.0

    /// Scroll zoom 25–400 % (PIN-03); ⌥-scroll opacity 20–100 % (PIN-04). View state only, never the document.
    func scroll(delta: Double, option: Bool) {
        if option {
            opacity = min(max(opacity + delta * 0.01, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        } else {
            zoom = min(max(zoom * (1 + delta * 0.01), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        }
    }
}

@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private let services: WorkspaceServices
    private let sessionID: SessionID
    private let owner: SessionOwner
    private let state = PinState()
    private let window: PinWindow
    private let canvas: DocumentCanvasView
    private let observer: DocumentObserver
    private let onClose: () -> Void
    private var baseSize = NSSize(width: 200, height: 150)

    init(services: WorkspaceServices, sessionID: SessionID, key: UUID, onClose: @escaping () -> Void) {
        self.services = services
        self.sessionID = sessionID
        owner = .pin(key)
        self.onClose = onClose
        canvas = DocumentCanvasView(render: services.render, sessionID: sessionID, editor: nil, purpose: .pin)
        observer = DocumentObserver(sessions: services.sessions, sessionID: sessionID)
        window = PinWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        // Identifies pins as capture candidates (CAP-22); never shown.
        window.title = PinWindow.identifierTitle
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.handler = self
        let content = PinContentView(canvas: canvas, state: state, actions: PinActions(
            edit: { [weak self] in self?.edit() }, copy: { [weak self] in self?.copyImage() },
            toggleClickThrough: { [weak self] in self?.setClickThrough(!(self?.state.clickThrough ?? false)) },
            toggleOnTop: { [weak self] in self?.toggleOnTop() }, close: { [weak self] in self?.window.close() }
        )).localized(services.localizer)
        window.contentView = NSHostingView(rootView: content)
        canvas.onRender = { [weak self] plan in self?.resize(for: plan) }
        observer.onChange = { [weak self] session in self?.canvas.update(session) }
        Task { await services.sessions.retain(sessionID, by: owner) }
        observer.start()
    }

    func show(offset: Double) {
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 100 + offset, y: screen.visibleFrame.midY - 75 - offset))
        }
        window.orderFrontRegardless()
    }

    /// Pins follow document changes and keep their zoom (PIN-12).
    private func resize(for plan: RenderPlan) {
        let size = NSSize(width: Double(plan.canvas.width) / plan.scale, height: Double(plan.canvas.height) / plan.scale)
        let first = baseSize == NSSize(width: 200, height: 150)
        baseSize = size
        applyZoom(keepCenter: !first)
    }

    func applyZoom(keepCenter: Bool = true) {
        let size = NSSize(width: max(baseSize.width * state.zoom, 1), height: max(baseSize.height * state.zoom, 1))
        var frame = window.frame
        if keepCenter { frame.origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2) }
        frame.size = size
        window.setFrame(frame, display: true)
        window.alphaValue = state.clickThrough ? min(state.opacity, 0.5) : state.opacity
    }

    func scrolled(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        state.scroll(delta: delta, option: event.modifierFlags.contains(.option))
        applyZoom()
    }

    /// Click-through makes the pin semi-transparent; the menu restores interaction (PIN-05, PIN-11).
    func setClickThrough(_ on: Bool) {
        state.clickThrough = on
        window.ignoresMouseEvents = on
        applyZoom()
    }

    func toggleOnTop() {
        state.keepsOnTop.toggle()
        window.level = state.keepsOnTop ? .floating : .normal
    }

    func bringToFront() { window.orderFrontRegardless() }

    func edit() { services.router.route(.openEditor(sessionID, focus: nil)) }

    func copyImage() {
        let export = services.export, id = sessionID, settings = services.settings.snapshot, errors = services.errors, message = services.localizer[.feedbackCopied]
        Task {
            do {
                try await export.copyImage(of: id, settings: settings)
                errors.toast(ToastModel(message: message), near: nil)
            } catch { errors.present(error, near: nil) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        observer.stop()
        let sessions = services.sessions, id = sessionID, owner = owner
        Task { await sessions.release(id, by: owner) }
        onClose()
    }

    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command), key == "c" { copyImage(); return true }
        switch event.keyCode {
        case 53, 51, 117: window.close(); return true
        default: break
        }
        if key == "e", flags.isDisjoint(with: [.command, .option, .control]) { edit(); return true }
        return false
    }
}

final class PinWindow: NSPanel {
    static let identifierTitle = "TF2Pin"
    weak var handler: PinController?
    override var canBecomeKey: Bool { true }
    override func scrollWheel(with event: NSEvent) { handler?.scrolled(event) }
    override func keyDown(with event: NSEvent) { if handler?.key(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handler?.key(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct PinActions {
    let edit: () -> Void
    let copy: () -> Void
    let toggleClickThrough: () -> Void
    let toggleOnTop: () -> Void
    let close: () -> Void
}

struct PinContentView: View {
    let canvas: DocumentCanvasView
    let state: PinState
    let actions: PinActions
    @Environment(Localizer.self) private var l10n
    @State private var hovering = false

    var body: some View {
        CanvasRepresentable(canvas: canvas)
            .overlay(alignment: .top) {
                if hovering {
                    FloatingToolbar {
                        IconButton(l10n[.pinEdit], systemImage: "pencil", shortcutHint: "E", action: actions.edit)
                        IconButton(l10n[.actionCopy], systemImage: "doc.on.doc", shortcutHint: "⌘C", action: actions.copy)
                        IconButton(l10n[.pinClickThrough], systemImage: "cursorarrow.motionlines", isActive: state.clickThrough, action: actions.toggleClickThrough)
                        IconButton(l10n[.pinKeepOnTop], systemImage: "pin", isActive: state.keepsOnTop, action: actions.toggleOnTop)
                        IconButton(l10n[.actionClose], systemImage: "xmark", shortcutHint: "Esc", action: actions.close)
                    }
                    .padding(DS.Space.s1)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.linear(duration: DS.Motion.fast), value: hovering)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l10n[.pinAccessibility])
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let canvas: DocumentCanvasView
    func makeNSView(context: Context) -> DocumentCanvasView { canvas }
    func updateNSView(_ view: DocumentCanvasView, context: Context) {}
}
