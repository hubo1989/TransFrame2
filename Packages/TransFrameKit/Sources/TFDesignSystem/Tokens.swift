import AppKit
import SwiftUI

/// Design tokens (SPEC §05 §2). Feature code references these instead of literals.
public enum DS {
    public enum Space {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s5: CGFloat = 20
        public static let s6: CGFloat = 24
        public static let s7: CGFloat = 32
        public static let s8: CGFloat = 40
    }

    public enum Radius {
        public static let s: CGFloat = 4
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
    }

    public enum Size {
        /// Minimum hit target for icon buttons.
        public static let iconButton: CGFloat = 28
        public static let statusDot: CGFloat = 8
        public static let swatch: CGFloat = 18
        public static let gridSwatch: CGFloat = 48
        public static let toolbarHeight: CGFloat = 36
        public static let thumbnail: CGFloat = 48
        public static let settingsSidebar: CGFloat = 200
        public static let formLabel: CGFloat = 160
    }

    public enum Motion {
        public static let fast: Double = 0.12
        public static let standard: Double = 0.2
        public static let slow: Double = 0.35
        public static let snappy = Animation.snappy(duration: standard)
        public static let smooth = Animation.smooth(duration: standard)

        /// Respects Reduce Motion: positional animations become opacity-only or none.
        public static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? .linear(duration: fast) : base
        }
    }

    public enum Typography {
        public static let hero = Font.largeTitle
        public static let title = Font.title2
        public static let section = Font.headline
        public static let body = Font.body
        public static let secondary = Font.subheadline
        public static let caption = Font.caption
        public static let micro = Font.caption2
        public static let mono = Font.body.monospaced()
        public static let monoCaption = Font.caption.monospaced()
        /// Large symbol illustrations (onboarding, empty states).
        public static let illustration = Font.system(size: 56, weight: .regular)
    }

    /// Semantic colors. Status colors are for icons and dots only, never body text.
    public enum Palette {
        public static let primary = Color.primary
        public static let secondary = Color.secondary
        public static let accent = Color.accentColor
        public static let surfaceWindow = Color(nsColor: .windowBackgroundColor)
        public static let surfaceControl = Color(nsColor: .controlBackgroundColor)
        public static let separator = Color(nsColor: .separatorColor)
        public static let statusOK = Color(nsColor: .systemGreen)
        public static let statusWarn = Color(nsColor: .systemOrange)
        public static let statusError = Color(nsColor: .systemRed)
        public static let statusNeutral = Color(nsColor: .systemGray)
        public static let destructive = Color(nsColor: .systemRed)
    }

    /// Overlay colors drawn on frozen screen content; independent of appearance.
    public enum Overlay {
        public static let scrimAlpha: CGFloat = 0.4
        public static let selectionLineWidth: CGFloat = 2
        public static let candidateFillAlpha: CGFloat = 0.08
        public static let candidateStrokeAlpha: CGFloat = 0.5
        public static let handleSize: CGFloat = 8
        public static var accent: NSColor { .controlAccentColor }
        public static let scrim = NSColor.black.withAlphaComponent(scrimAlpha)
        public static let labelBackground = NSColor.black.withAlphaComponent(0.72)
        public static let labelText = NSColor.white
        /// Fixed pixel font for overlay labels (whitelisted, SPEC §05 §2.3).
        public static func labelFont(size: CGFloat = 12) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
    }

    public enum Shadow {
        public struct Spec: Sendable {
            public let radius: CGFloat
            public let y: CGFloat
            public let opacity: Double
        }
        public static let raised = Spec(radius: 6, y: 2, opacity: 0.2)
        public static let floating = Spec(radius: 12, y: 4, opacity: 0.25)
    }
}

public extension View {
    func dsShadow(_ spec: DS.Shadow.Spec) -> some View {
        shadow(color: .black.opacity(spec.opacity), radius: spec.radius, y: spec.y)
    }
}
