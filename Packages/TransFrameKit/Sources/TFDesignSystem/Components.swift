import AppKit
import SwiftUI

/// Icon-only button with a mandatory text label (visually hidden) and a hover hint (SPEC §05 §3): name, shortcut
/// key caps and an optional one-line explanation.
public struct IconButton: View {
    let title: String
    let systemImage: String
    let keys: [String]
    let detail: String?
    let isActive: Bool
    let role: ButtonRole?
    let action: () -> Void

    public init(
        _ title: String, systemImage: String, shortcutHint: String? = nil, shortcutKeys: [String] = [], detail: String? = nil,
        isActive: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        keys = shortcutKeys + (shortcutHint.map { [$0] } ?? [])
        self.detail = detail
        self.isActive = isActive
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: DS.Size.iconButton - DS.Space.s2, minHeight: DS.Size.iconButton - DS.Space.s2)
                .contentShape(.rect)
        }
        .buttonStyle(IconButtonStyle(isActive: isActive))
        .hoverHint(HoverHintContent(title, keys: keys, detail: detail))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Hover, pressed, disabled, selected and focus states for icon buttons.
public struct IconButtonStyle: ButtonStyle {
    let isActive: Bool
    public init(isActive: Bool = false) { self.isActive = isActive }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isActive: isActive)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(DS.Space.s1)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(background, in: .rect(cornerRadius: DS.Radius.m))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
        }

        private var background: AnyShapeStyle {
            if configuration.isPressed { return AnyShapeStyle(.quaternary) }
            if isActive { return AnyShapeStyle(.tint.opacity(0.18)) }
            if isHovering { return AnyShapeStyle(.quinary) }
            return AnyShapeStyle(.clear)
        }
    }
}

/// `surface.control` + `radius.l` container for engine cards and similar groups.
public struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceControl, in: .rect(cornerRadius: DS.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}

public enum StatusLevel: Sendable, Equatable {
    case ok, warn, error, neutral, busy

    var color: Color {
        switch self {
        case .ok: DS.Palette.statusOK
        case .warn: DS.Palette.statusWarn
        case .error: DS.Palette.statusError
        case .neutral, .busy: DS.Palette.statusNeutral
        }
    }
}

/// 8 pt dot plus a text label; never color alone (SPEC §05 §6.2).
public struct StatusDot: View {
    let level: StatusLevel
    let label: String
    let detail: String?

    public init(_ level: StatusLevel, label: String, detail: String? = nil) {
        self.level = level
        self.label = label
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: DS.Space.s1) {
            if level == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(level.color).frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            }
            Text(label).font(DS.Typography.caption).foregroundStyle(.secondary)
        }
        .help(detail ?? label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(label), \($0)" } ?? label)
    }
}

/// Password field with a show/hide toggle.
public struct SecretField: View {
    let title: String
    let showLabel: String
    let hideLabel: String
    @Binding var text: String
    @State private var isRevealed = false

    public init(_ title: String, text: Binding<String>, showLabel: String, hideLabel: String) {
        self.title = title
        _text = text
        self.showLabel = showLabel
        self.hideLabel = hideLabel
    }

    public var body: some View {
        HStack(spacing: DS.Space.s1) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(DS.Typography.mono)
            IconButton(isRevealed ? hideLabel : showLabel, systemImage: isRevealed ? "eye.slash" : "eye") {
                isRevealed.toggle()
            }
        }
    }
}

/// System "content unavailable" view with an optional action.
public struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ title: String, message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}

/// Keyboard shortcut chip (monospaced, capsule).
public struct KeyCap: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(DS.Typography.monoCaption)
            .padding(.horizontal, DS.Space.s2)
            .padding(.vertical, DS.Space.s1 / 2)
            .background(.quinary, in: Capsule())
    }
}
