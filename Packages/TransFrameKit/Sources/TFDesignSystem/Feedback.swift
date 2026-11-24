import AppKit
import Observation
import SwiftUI

// MARK: - Toast (the only success feedback, SPEC §05 §3)

public struct ToastModel: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable, Equatable { case success, info, warning, error }
    public let id = UUID()
    public let kind: Kind
    public let message: String
    public let actionTitle: String?

    public init(_ kind: Kind = .success, message: String, actionTitle: String? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
    }

    var systemImage: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .success: DS.Palette.statusOK
        case .info: DS.Palette.accent
        case .warning: DS.Palette.statusWarn
        case .error: DS.Palette.statusError
        }
    }
}

public struct ToastView: View {
    let model: ToastModel
    let action: (() -> Void)?

    public init(_ model: ToastModel, action: (() -> Void)? = nil) {
        self.model = model
        self.action = action
    }

    public var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: model.systemImage).foregroundStyle(model.tint).accessibilityHidden(true)
            Text(model.message).font(DS.Typography.body).lineLimit(2)
            if let title = model.actionTitle, let action {
                Button(title, action: action).buttonStyle(.link)
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .chrome(.toast, shape: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Banner (recoverable errors in place)

public struct BannerView: View {
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let dismissTitle: String
    let onDismiss: () -> Void

    public init(
        title: String, message: String?, actionTitle: String?, action: (() -> Void)?, dismissTitle: String,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.dismissTitle = dismissTitle
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.statusWarn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(title).font(DS.Typography.section)
                if let message { Text(message).font(DS.Typography.secondary).foregroundStyle(.secondary) }
            }
            Spacer(minLength: DS.Space.s2)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
            IconButton(dismissTitle, systemImage: "xmark", action: onDismiss)
        }
        .padding(DS.Space.s3)
        .background(DS.Palette.surfaceControl, in: .rect(cornerRadius: DS.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(DS.Palette.statusWarn.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Progress HUD

public struct ProgressHUDView: View {
    let message: String
    let systemImage: String?

    public init(_ message: String, systemImage: String? = nil) {
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: DS.Space.s2) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.tint).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(message).font(DS.Typography.secondary)
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .chrome(.toast, shape: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Floating feedback presenter (toasts and HUDs that outlive their source window)

/// Hosts toasts and progress HUDs in non-activating floating panels. Created once by the
/// composition root and injected; never steals keyboard focus (SPEC §05 §5).
@MainActor
public final class FeedbackCenter {
    private var toastPanel: NSPanel?
    private var hudPanel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var actionHandler: (() -> Void)?

    public init() {}

    /// Shows a toast near the top of the screen containing `anchor` (Cocoa global point), or the main screen.
    public func toast(_ model: ToastModel, near anchor: CGPoint? = nil, duration: Duration = .seconds(2.2), action: (() -> Void)? = nil) {
        dismissTask?.cancel()
        actionHandler = action
        let view = ToastView(model, action: action.map { handler in { [weak self] in handler(); self?.dismissToast() } })
            .padding(DS.Space.s3)
            .fixedSize()
        let panel = toastPanel ?? Self.makePanel()
        toastPanel = panel
        panel.contentView = NSHostingView(rootView: view)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 48)
        let screen = anchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - DS.Space.s6, width: size.width, height: size.height),
            display: true)
        panel.ignoresMouseEvents = action == nil
        panel.alphaValue = 1
        Self.raise(panel)
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: model.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    public func dismissToast() {
        dismissTask?.cancel()
        toastPanel?.orderOut(nil)
        actionHandler = nil
    }

    /// Shows a HUD next to a Cocoa global rect (e.g. the text caret); appears immediately (O-01).
    public func showHUD(_ message: String, systemImage: String? = nil, near anchor: CGRect?) {
        let panel = hudPanel ?? Self.makePanel()
        hudPanel = panel
        panel.contentView = NSHostingView(rootView: ProgressHUDView(message, systemImage: systemImage).padding(DS.Space.s1).fixedSize())
        let size = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 36)
        let origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - DS.Space.s1)
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + DS.Space.s4, y: mouse.y - size.height - DS.Space.s4)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        var frame = NSRect(origin: origin, size: size)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = true
        Self.raise(panel)
        panel.orderFrontRegardless()
    }

    public func hideHUD() { hudPanel?.orderOut(nil) }

    /// Above every visible window of the app: the capture overlay sits at the shielding level and would hide a floating toast.
    private static func raise(_ panel: NSPanel) {
        let top = NSApp.windows.filter { $0.isVisible && $0 !== panel }.map(\.level.rawValue).max() ?? 0
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, top + 1))
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

// MARK: - Host-less alerts (capture failures, insertion failures)

public struct AlertButton: Sendable {
    public enum Role: Sendable { case normal, cancel, destructive }
    public let title: String
    public let role: Role
    public init(_ title: String, role: Role = .normal) {
        self.title = title
        self.role = role
    }
}

/// The single wrapper around `NSAlert` for situations without a host window (SPEC §05 §3).
@MainActor
public enum SystemAlert {
    /// Returns the index of the chosen button.
    @discardableResult
    public static func present(title: String, message: String, buttons: [AlertButton], style: NSAlert.Style = .warning) -> Int {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        for button in buttons {
            let b = alert.addButton(withTitle: button.title)
            if button.role == .destructive { b.hasDestructiveAction = true }
            if button.role == .cancel { b.keyEquivalent = "\u{1b}" }
        }
        NSApp.activate()
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
