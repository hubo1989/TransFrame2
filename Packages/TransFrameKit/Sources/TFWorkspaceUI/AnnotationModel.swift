import Foundation
import TFDomain

/// Tools in toolbar order; digits 1–9 follow this order (EDT-03), letters follow 1.x (EDT-02).
public enum AnnotationTool: String, CaseIterable, Sendable, Hashable {
    case rectangle, ellipse, line, arrow, freehand, highlight, mosaic, text, numberLabel, redaction, callout

    public init?(kind: AnnotationKind) { self.init(rawValue: kind.rawValue) }

    public var shortcutKey: Character {
        switch self {
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .freehand: "d"
        case .highlight: "h"
        case .mosaic: "m"
        case .text: "t"
        case .numberLabel: "n"
        case .redaction: "x"
        case .callout: "b"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .freehand: "scribble"
        case .highlight: "highlighter"
        case .mosaic: "square.grid.3x3"
        case .text: "character.textbox"
        case .numberLabel: "1.circle"
        case .redaction: "eye.slash"
        case .callout: "bubble.left"
        }
    }

    public static func forKey(_ character: Character) -> AnnotationTool? {
        let lower = Character(character.lowercased())
        if let digit = lower.wholeNumberValue, (1...9).contains(digit) { return allCases[digit - 1] }
        return allCases.first { $0.shortcutKey == lower }
    }

    /// Key caps for the tool's hint: its letter (unless the host reserves it for an action) and its digit.
    public func shortcutKeys(reserved: Set<Character> = []) -> [String] {
        var keys: [String] = []
        if !reserved.contains(shortcutKey) { keys.append(String(shortcutKey).uppercased()) }
        if let index = Self.allCases.firstIndex(of: self), index < 9 { keys.append("\(index + 1)") }
        return keys
    }

    /// Style bar controls that apply to this tool's annotations (ANN-04…ANN-07).
    public var styleControls: StyleControls {
        switch self {
        case .rectangle, .ellipse: [.color, .lineWidth, .fill]
        case .line, .arrow, .freehand: [.color, .lineWidth]
        case .highlight: [.color]
        case .mosaic: [.mosaic]
        case .text, .callout, .numberLabel: [.color, .fontSize]
        case .redaction: []
        }
    }
}

public struct StyleControls: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let color = StyleControls(rawValue: 1 << 0)
    public static let lineWidth = StyleControls(rawValue: 1 << 1)
    public static let fontSize = StyleControls(rawValue: 1 << 2)
    public static let fill = StyleControls(rawValue: 1 << 3)
    public static let mosaic = StyleControls(rawValue: 1 << 4)
    public static let all: StyleControls = [.color, .lineWidth, .fontSize, .fill, .mosaic]
}

/// Current style, in points (converted to document pixels with the image scale).
public struct AnnotationStyle: Equatable, Sendable {
    /// A fill that is the stroke color at this alpha follows the stroke color (the default fill).
    public static let autoFillAlpha = 0.25

    public var color: RGBA
    public var lineWidth: Double
    public var fontSize: Double
    public var isFilled: Bool
    public var fillColor: RGBA
    public var mosaicBlockSize: Double

    public init(defaults: AnnotationDefaults) {
        color = defaults.strokeColor
        lineWidth = defaults.lineWidth
        fontSize = defaults.fontSize
        isFilled = defaults.isFilled
        fillColor = defaults.fillColor
        mosaicBlockSize = defaults.mosaicBlockSize
    }

    public var asDefaults: AnnotationDefaults {
        var d = AnnotationDefaults()
        d.strokeColor = color
        d.lineWidth = lineWidth
        d.fontSize = fontSize
        d.isFilled = isFilled
        d.fillColor = fillColor
        d.mosaicBlockSize = mosaicBlockSize
        return d
    }

    /// Number label diameter in document pixels; follows the text size (ANN-16).
    public func numberDiameter(scale: Double) -> Double { max(fontSize * 1.6, 18) * scale }

    /// This style with the given fields taken from `other`.
    public func applying(_ fields: Set<StyleField>, from other: AnnotationStyle) -> AnnotationStyle {
        var s = self
        if fields.contains(.color) { s.color = other.color }
        if fields.contains(.lineWidth) { s.lineWidth = other.lineWidth }
        if fields.contains(.fontSize) { s.fontSize = other.fontSize }
        if fields.contains(.fill) { s.isFilled = other.isFilled; s.fillColor = other.fillColor }
        if fields.contains(.mosaic) { s.mosaicBlockSize = other.mosaicBlockSize }
        return s
    }
}

/// Handle positions for resizing (eight around a box, the two endpoints of a line, the callout pointer).
public enum AnnotationHandle: Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end, pointer
}

public struct TextEditingState: Equatable {
    public var annotationID: AnnotationID?
    public var anchor: DocumentPoint
    public var text: String
    public var fontSize: Double
    public var color: RGBA
    public var isCallout: Bool

    /// Same field on screen (typing changes only `text`).
    func isSameField(as other: TextEditingState?) -> Bool {
        guard let other else { return false }
        return annotationID == other.annotationID && anchor == other.anchor && isCallout == other.isCallout
    }
}

/// A committed edit the store has not echoed back yet. The canvas keeps drawing `annotation` above the image (and
/// keeps `hidden` out of renders of `baseRevision` or older) until it shows a newer revision, so nothing flickers
/// between the end of a gesture and the store round trip.
public struct PendingEdit: Equatable, Sendable {
    public let id = UUID()
    public let annotation: Annotation?
    public let hidden: AnnotationID?
    public let baseRevision: Int
}

/// What changed for the canvas (delivered synchronously, batched per input event).
public struct DisplayChange: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let overlay = DisplayChange(rawValue: 1 << 0)
    public static let render = DisplayChange(rawValue: 1 << 1)
    public static let cursor = DisplayChange(rawValue: 1 << 2)
    public static let text = DisplayChange(rawValue: 1 << 3)
}

public enum CanvasCursor: Equatable, Sendable {
    case arrow, crosshair, iBeam, move, moving
    case resize(AnnotationHandle)
}
