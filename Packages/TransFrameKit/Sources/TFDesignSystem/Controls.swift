import AppKit
import SwiftUI

// MARK: - Shortcut recorder (SET-06). Reports raw key code + Carbon modifier mask
// (cmd 0x100, shift 0x200, option 0x800, control 0x1000).

public struct RecordedKey: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public struct ShortcutRecorder: View {
    let current: String
    let prompt: String
    let recordLabel: String
    let resetLabel: String
    let isRecording: Bool
    let onStart: () -> Void
    let onRecord: (RecordedKey) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    public init(
        current: String, prompt: String, recordLabel: String, resetLabel: String, isRecording: Bool,
        onStart: @escaping () -> Void, onRecord: @escaping (RecordedKey) -> Void, onCancel: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.current = current
        self.prompt = prompt
        self.recordLabel = recordLabel
        self.resetLabel = resetLabel
        self.isRecording = isRecording
        self.onStart = onStart
        self.onRecord = onRecord
        self.onCancel = onCancel
        self.onReset = onReset
    }

    public var body: some View {
        HStack(spacing: DS.Space.s2) {
            Button(action: onStart) {
                Text(isRecording ? prompt : current)
                    .font(isRecording ? DS.Typography.secondary : DS.Typography.mono)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .accessibilityLabel(isRecording ? prompt : "\(recordLabel), \(current)")
            .background {
                if isRecording { KeyCaptureView(onKey: onRecord, onCancel: onCancel).frame(width: 0, height: 0) }
            }
            IconButton(resetLabel, systemImage: "arrow.counterclockwise", action: onReset)
        }
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onKey: (RecordedKey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onKey = onKey
        view.onCancel = onCancel
        DispatchMainLater.focus(view)
        return view
    }

    func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
    }

    final class CaptureNSView: NSView {
        var onKey: ((RecordedKey) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask) {
                onCancel?()
                return
            }
            onKey?(RecordedKey(keyCode: UInt32(event.keyCode), carbonModifiers: Self.carbon(event.modifierFlags)))
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onCancel?()
            return true
        }

        static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var mask: UInt32 = 0
            if flags.contains(.command) { mask |= 0x0100 }
            if flags.contains(.shift) { mask |= 0x0200 }
            if flags.contains(.option) { mask |= 0x0800 }
            if flags.contains(.control) { mask |= 0x1000 }
            return mask
        }
    }
}

/// Defers first-responder assignment until the view is in a window.
@MainActor
enum DispatchMainLater {
    static func focus(_ view: NSView) {
        Task { @MainActor in
            await Task.yield()
            view.window?.makeFirstResponder(view)
        }
    }
}

// MARK: - Color swatches (ANN-03, COL-04)

public struct ColorSwatch: View {
    let color: Color
    let name: String
    let isSelected: Bool
    let size: CGFloat
    let action: () -> Void

    public init(color: Color, name: String, isSelected: Bool, size: CGFloat = DS.Size.swatch, action: @escaping () -> Void) {
        self.color = color
        self.name = name
        self.isSelected = isSelected
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(DS.Palette.separator, lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .hoverHint(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Floating toolbar container (capsule, chrome.floating)

public struct FloatingToolbar<Content: View>: View {
    @ViewBuilder let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: DS.Space.s1) { content }
            .padding(.horizontal, DS.Space.s2)
            .padding(.vertical, DS.Space.s1)
            .frame(minHeight: DS.Size.toolbarHeight)
            .chrome(.floating, shape: .capsule)
            .chromeGroup()
    }
}

public struct ToolbarDivider: View {
    public init() {}
    public var body: some View {
        Divider().frame(height: DS.Size.iconButton - DS.Space.s2).padding(.horizontal, DS.Space.s1 / 2)
    }
}

// MARK: - System color panel (ANN-03, ANN-06)

/// Opens the system color panel for one color. Over high-level windows (the capture overlay) the panel is raised above
/// the host window while this control is on screen, and closed and put back when it goes away, so it never ends up
/// hidden under the overlay or floating over everything afterwards.
public struct SystemColorButton: View {
    let title: String
    let systemImage: String
    let detail: String?
    let color: NSColor
    let supportsOpacity: Bool
    let onChange: (NSColor) -> Void
    @State private var link = ColorPanelLink()

    public init(
        _ title: String, systemImage: String, detail: String? = nil, color: NSColor, supportsOpacity: Bool,
        onChange: @escaping (NSColor) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.color = color
        self.supportsOpacity = supportsOpacity
        self.onChange = onChange
    }

    public var body: some View {
        IconButton(title, systemImage: systemImage, detail: detail) {
            link.open(color: color, supportsOpacity: supportsOpacity, onChange: onChange)
        }
        .background(ColorPanelAnchor(link: link))
        .onDisappear { link.close() }
    }
}

@MainActor
final class ColorPanelLink: NSObject {
    weak var view: NSView?
    private var onChange: ((NSColor) -> Void)?
    private var raised = false
    private var linked = false

    func open(color: NSColor, supportsOpacity: Bool, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = supportsOpacity
        panel.color = color
        panel.isContinuous = true
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        linked = true
        if let window = view?.window, window.level.rawValue >= panel.level.rawValue {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            raised = true
        }
        panel.orderFrontRegardless()
    }

    @objc func colorChanged(_ sender: NSColorPanel) { onChange?(sender.color) }

    func close() {
        guard linked, NSColorPanel.sharedColorPanelExists else { return }
        linked = false
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        if raised {
            panel.level = .floating
            raised = false
        }
        onChange = nil
    }
}

private struct ColorPanelAnchor: NSViewRepresentable {
    let link: ColorPanelLink

    func makeNSView(context: Context) -> NSView {
        let view = PassThrough()
        link.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { link.view = view }

    private final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
