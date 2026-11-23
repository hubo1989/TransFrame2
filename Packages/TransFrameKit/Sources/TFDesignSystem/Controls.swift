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
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
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
        .help(name)
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
