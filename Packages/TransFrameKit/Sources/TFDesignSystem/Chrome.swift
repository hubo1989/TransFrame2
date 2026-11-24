import AppKit
import SwiftUI

/// Material and glass tokens (SPEC §05 §2.2). The only place in UI code with an availability check.
public enum ChromeStyle: Sendable {
    /// Floating toolbars, results drawer shell, pin hover bar.
    case floating
    /// Toasts and progress HUDs (not interactive).
    case toast
    /// In-window tool bars.
    case bar
}

public enum ChromeShape: Sendable {
    case rounded(CGFloat)
    case capsule
}

private struct ChromeModifier: ViewModifier {
    let style: ChromeStyle
    let shape: ChromeShape

    func body(content: Content) -> some View {
        switch shape {
        case .capsule: styled(content, in: Capsule(style: .continuous))
        case .rounded(let radius): styled(content, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func styled<S: Shape>(_ content: Content, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            switch style {
            case .floating: content.glassEffect(.regular.interactive(), in: shape)
            case .toast: content.glassEffect(.regular, in: shape)
            case .bar: content.glassEffect(.regular, in: shape)
            }
        } else {
            switch style {
            case .floating:
                content.background(.regularMaterial, in: shape).dsShadow(DS.Shadow.floating)
            case .toast:
                content.background(.thinMaterial, in: shape).dsShadow(DS.Shadow.raised)
            case .bar:
                content.background(.bar, in: shape)
            }
        }
    }
}

public extension View {
    /// `.chrome(.floating)` — glass on macOS 26+, system materials on 15–25.
    func chrome(_ style: ChromeStyle, shape: ChromeShape = .rounded(DS.Radius.l)) -> some View {
        modifier(ChromeModifier(style: style, shape: shape))
    }

    /// Groups glass elements so they blend on macOS 26; a plain container before.
    @ViewBuilder
    func chromeGroup(spacing: CGFloat = DS.Space.s2) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Primary action on floating toolbars: glass prominent on 26+, bordered prominent before.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action on floating toolbars.
    @ViewBuilder
    func floatingActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
