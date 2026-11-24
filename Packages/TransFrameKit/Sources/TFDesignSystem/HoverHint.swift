import AppKit
import Observation
import SwiftUI

/// What a hover hint says: the control's name, its shortcut key caps and a one-line explanation.
public struct HoverHintContent: Equatable, Sendable {
    public let title: String
    public let keys: [String]
    public let detail: String?

    public init(_ title: String, keys: [String] = [], detail: String? = nil) {
        self.title = title
        self.keys = keys
        self.detail = detail
    }

    /// Single-string form for system tooltips outside a hint scope.
    public var plainText: String {
        var text = keys.isEmpty ? title : "\(title) (\(keys.joined(separator: " / ")))"
        if let detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}

/// Shows hover hints of one toolbar in a small floating panel one level above the toolbar's window. System tooltips
/// sit far below the capture overlay's shielding level (and appear late), so floating toolbars use these instead.
/// Install with `.hoverHintScope()`; controls opt in with `.hoverHint(_:)`.
@MainActor
@Observable
public final class HoverHintPresenter {
    /// First hint after resting on a control; once one was shown, neighbours answer at once (like system tooltips).
    static let delay: Duration = .milliseconds(450)
    static let warmWindow: Duration = .milliseconds(800)

    @ObservationIgnored private(set) var panel: NSPanel?
    @ObservationIgnored private var host: NSHostingController<HoverHintView>?
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private weak var current: HoverHintAnchor?
    @ObservationIgnored private var lastHidden: ContinuousClock.Instant?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private(set) var shown: HoverHintContent?

    public init() {}

    func enter(_ content: HoverHintContent, anchor: HoverHintAnchor) {
        current = anchor
        showTask?.cancel()
        let warm = shown != nil || lastHidden.map { ContinuousClock.now - $0 < Self.warmWindow } ?? false
        if warm {
            show(content, anchor: anchor)
            return
        }
        showTask = Task { [weak self, weak anchor] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let anchor else { return }
            self.show(content, anchor: anchor)
        }
    }

    func exit(_ anchor: HoverHintAnchor) {
        guard current === anchor else { return }
        dismiss()
    }

    /// Hides the hint (clicks, keys and scrolling do this automatically).
    public func dismiss() {
        showTask?.cancel()
        showTask = nil
        current = nil
        guard shown != nil else { return }
        shown = nil
        lastHidden = .now
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func show(_ content: HoverHintContent, anchor: HoverHintAnchor) {
        guard current === anchor, let view = anchor.view, let window = view.window, window.isVisible else { return }
        let panel = self.panel ?? makePanel()
        let host = self.host ?? NSHostingController(rootView: HoverHintView(content: content))
        if self.host == nil {
            host.sizingOptions = []
            panel.contentViewController = host
            self.host = host
        }
        host.rootView = HoverHintView(content: content)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 400))
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(anchorRect) }
        let area = window.level.rawValue > NSWindow.Level.mainMenu.rawValue ? screen?.frame : screen?.visibleFrame
        var origin = CGPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.minY - size.height)
        if let area {
            if origin.y < area.minY { origin.y = anchorRect.maxY }
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        }
        panel.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue) + 1)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        shown = content
        if monitor == nil {
            let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.dismiss() }
                return event
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}

/// The hint bubble: name, key caps, explanation.
struct HoverHintView: View {
    let content: HoverHintContent

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
            HStack(spacing: DS.Space.s2) {
                Text(content.title).font(DS.Typography.secondary.weight(.semibold))
                if !content.keys.isEmpty {
                    HStack(spacing: DS.Space.s1 / 2) {
                        ForEach(content.keys, id: \.self) { KeyCap($0) }
                    }
                }
            }
            if let detail = content.detail, !detail.isEmpty {
                Text(detail).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .chrome(.toast, shape: .rounded(DS.Radius.m))
        .padding(DS.Space.s2)
        .accessibilityHidden(true)
    }
}

/// Weak link from a hinted control to the AppKit view that knows its window and screen position.
@MainActor
final class HoverHintAnchor {
    weak var view: NSView?
}

private struct HoverHintAnchorView: NSViewRepresentable {
    let anchor: HoverHintAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct HoverHintModifier: ViewModifier {
    let hint: HoverHintContent
    @Environment(HoverHintPresenter.self) private var presenter: HoverHintPresenter?
    @State private var anchor = HoverHintAnchor()

    func body(content: Content) -> some View {
        if let presenter {
            content
                .background(HoverHintAnchorView(anchor: anchor))
                .onHover { inside in
                    if inside { presenter.enter(hint, anchor: anchor) } else { presenter.exit(anchor) }
                }
                .onDisappear { presenter.exit(anchor) }
                .accessibilityHint(hint.detail ?? "")
        } else {
            content.help(hint.plainText)
        }
    }
}

private struct HoverHintScope: ViewModifier {
    @State private var presenter = HoverHintPresenter()

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .onDisappear { presenter.dismiss() }
    }
}

public extension View {
    /// Hover hint for this control: the scope's floating hint, or a system tooltip outside a scope.
    func hoverHint(_ hint: HoverHintContent) -> some View { modifier(HoverHintModifier(hint: hint)) }

    func hoverHint(_ title: String, keys: [String] = [], detail: String? = nil) -> some View {
        hoverHint(HoverHintContent(title, keys: keys, detail: detail))
    }

    /// Floating hover hints for every `.hoverHint` control inside (toolbars over the capture overlay and the editor).
    func hoverHintScope() -> some View { modifier(HoverHintScope()) }
}
