import CoreGraphics
import Foundation

// MARK: - Annotations (SPEC §02 §5.1). Geometry and sizes are in document pixels.

public enum AnnotationRole: String, Sendable, Codable {
    case decoration, redaction
}

public enum AnnotationKind: String, Sendable, Codable, CaseIterable, Hashable {
    case rectangle, ellipse, line, arrow, freehand, highlight, text, numberLabel, callout, mosaic, redaction
}

public struct ShapeAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var rect: DocumentRect
    public var strokeColor: RGBA
    public var lineWidth: Double
    public var isFilled: Bool
    public var fillColor: RGBA

    public init(
        id: AnnotationID = AnnotationID(), rect: DocumentRect, strokeColor: RGBA, lineWidth: Double,
        isFilled: Bool = false, fillColor: RGBA = .clear
    ) {
        self.id = id
        self.rect = rect
        self.strokeColor = strokeColor
        self.lineWidth = lineWidth
        self.isFilled = isFilled
        self.fillColor = fillColor
    }
}

public struct LineAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var start: DocumentPoint
    public var end: DocumentPoint
    public var color: RGBA
    public var lineWidth: Double

    public init(id: AnnotationID = AnnotationID(), start: DocumentPoint, end: DocumentPoint, color: RGBA, lineWidth: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }
}

public struct PathAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var points: [DocumentPoint]
    public var color: RGBA
    public var lineWidth: Double

    public init(id: AnnotationID = AnnotationID(), points: [DocumentPoint], color: RGBA, lineWidth: Double) {
        self.id = id
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }
}

public struct TextAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    /// Top-left of the first line.
    public var anchor: DocumentPoint
    public var maxWidth: Double?
    public var text: String
    public var color: RGBA
    public var fontSize: Double
    public var fontName: String?

    public init(
        id: AnnotationID = AnnotationID(), anchor: DocumentPoint, maxWidth: Double? = nil, text: String,
        color: RGBA, fontSize: Double, fontName: String? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.maxWidth = maxWidth
        self.text = text
        self.color = color
        self.fontSize = fontSize
        self.fontName = fontName
    }
}

public struct NumberLabelAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var center: DocumentPoint
    public var number: Int
    public var color: RGBA
    public var diameter: Double

    public init(id: AnnotationID = AnnotationID(), center: DocumentPoint, number: Int, color: RGBA, diameter: Double) {
        self.id = id
        self.center = center
        self.number = number
        self.color = color
        self.diameter = diameter
    }
}

public struct CalloutAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var bubble: DocumentRect
    public var pointer: DocumentPoint
    public var text: String
    public var color: RGBA
    public var fontSize: Double
    public var fillColor: RGBA

    public init(
        id: AnnotationID = AnnotationID(), bubble: DocumentRect, pointer: DocumentPoint, text: String,
        color: RGBA, fontSize: Double, fillColor: RGBA
    ) {
        self.id = id
        self.bubble = bubble
        self.pointer = pointer
        self.text = text
        self.color = color
        self.fontSize = fontSize
        self.fillColor = fillColor
    }
}

public struct MosaicAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var rect: DocumentRect
    public var blockSize: Double
    /// When true the region is treated as a redaction: solid before upload, composited last.
    public var isPrivacy: Bool

    public init(id: AnnotationID = AnnotationID(), rect: DocumentRect, blockSize: Double, isPrivacy: Bool = false) {
        self.id = id
        self.rect = rect
        self.blockSize = blockSize
        self.isPrivacy = isPrivacy
    }
}

public enum RedactionSource: String, Sendable, Codable, Hashable {
    case user, privacyGuard
}

public struct RedactionAnnotation: Sendable, Codable, Equatable, Hashable {
    public var id: AnnotationID
    public var rect: DocumentRect
    public var fill: RGBA
    public var source: RedactionSource

    public init(id: AnnotationID = AnnotationID(), rect: DocumentRect, fill: RGBA = .black, source: RedactionSource = .user) {
        self.id = id
        self.rect = rect
        self.fill = fill
        self.source = source
    }
}

public enum Annotation: Sendable, Equatable, Hashable, Identifiable, Codable {
    case rectangle(ShapeAnnotation)
    case ellipse(ShapeAnnotation)
    case line(LineAnnotation)
    case arrow(LineAnnotation)
    case freehand(PathAnnotation)
    case highlight(ShapeAnnotation)
    case text(TextAnnotation)
    case numberLabel(NumberLabelAnnotation)
    case callout(CalloutAnnotation)
    case mosaic(MosaicAnnotation)
    case redaction(RedactionAnnotation)

    public var id: AnnotationID {
        switch self {
        case .rectangle(let a), .ellipse(let a), .highlight(let a): a.id
        case .line(let a), .arrow(let a): a.id
        case .freehand(let a): a.id
        case .text(let a): a.id
        case .numberLabel(let a): a.id
        case .callout(let a): a.id
        case .mosaic(let a): a.id
        case .redaction(let a): a.id
        }
    }

    public var kind: AnnotationKind {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .freehand: .freehand
        case .highlight: .highlight
        case .text: .text
        case .numberLabel: .numberLabel
        case .callout: .callout
        case .mosaic: .mosaic
        case .redaction: .redaction
        }
    }

    public var role: AnnotationRole {
        switch self {
        case .redaction: .redaction
        case .mosaic(let m): m.isPrivacy ? .redaction : .decoration
        default: .decoration
        }
    }

    /// True for annotations whose change invalidates analysis input (redactions and privacy mosaics).
    public var affectsAnalysisInput: Bool { role == .redaction }

    /// Axis-aligned bounds in document pixels, including stroke.
    public var bounds: DocumentRect {
        switch self {
        case .rectangle(let a), .ellipse(let a), .highlight(let a):
            return a.rect.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .line(let a), .arrow(let a):
            let r = CGRect(
                x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y),
                width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y)
            )
            let pad = a.lineWidth * (kind == .arrow ? 3 : 0.5)
            return DocumentRect(r.insetBy(dx: -pad, dy: -pad))
        case .freehand(let a):
            guard let first = a.points.first else { return .zero }
            var r = CGRect(origin: first.raw, size: .zero)
            for p in a.points.dropFirst() { r = r.union(CGRect(origin: p.raw, size: .zero)) }
            return DocumentRect(r.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2))
        case .text(let a):
            let lines = max(a.text.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
            let longest = a.text.split(separator: "\n").map(\.count).max() ?? 1
            let width = a.maxWidth ?? Double(max(longest, 1)) * a.fontSize * 0.62
            return DocumentRect(x: a.anchor.x, y: a.anchor.y, width: width, height: Double(lines) * a.fontSize * 1.25)
        case .numberLabel(let a):
            return DocumentRect(x: a.center.x - a.diameter / 2, y: a.center.y - a.diameter / 2, width: a.diameter, height: a.diameter)
        case .callout(let a):
            return a.bubble.union(DocumentRect(x: a.pointer.x, y: a.pointer.y, width: 0, height: 0))
        case .mosaic(let a): return a.rect
        case .redaction(let a): return a.rect
        }
    }

    /// Returns the annotation translated by (dx, dy) document pixels.
    public func translated(dx: Double, dy: Double) -> Annotation {
        switch self {
        case .rectangle(var a): a.rect = a.rect.offsetBy(dx: dx, dy: dy); return .rectangle(a)
        case .ellipse(var a): a.rect = a.rect.offsetBy(dx: dx, dy: dy); return .ellipse(a)
        case .highlight(var a): a.rect = a.rect.offsetBy(dx: dx, dy: dy); return .highlight(a)
        case .line(var a):
            a.start = a.start.offsetBy(dx: dx, dy: dy); a.end = a.end.offsetBy(dx: dx, dy: dy); return .line(a)
        case .arrow(var a):
            a.start = a.start.offsetBy(dx: dx, dy: dy); a.end = a.end.offsetBy(dx: dx, dy: dy); return .arrow(a)
        case .freehand(var a): a.points = a.points.map { $0.offsetBy(dx: dx, dy: dy) }; return .freehand(a)
        case .text(var a): a.anchor = a.anchor.offsetBy(dx: dx, dy: dy); return .text(a)
        case .numberLabel(var a): a.center = a.center.offsetBy(dx: dx, dy: dy); return .numberLabel(a)
        case .callout(var a):
            a.bubble = a.bubble.offsetBy(dx: dx, dy: dy); a.pointer = a.pointer.offsetBy(dx: dx, dy: dy); return .callout(a)
        case .mosaic(var a): a.rect = a.rect.offsetBy(dx: dx, dy: dy); return .mosaic(a)
        case .redaction(var a): a.rect = a.rect.offsetBy(dx: dx, dy: dy); return .redaction(a)
        }
    }
}

/// Default annotation palette, names match 1.x (SPEC §05 §2.1).
public enum AnnotationPalette {
    public static let red = RGBA(red: 1.0, green: 0.231, blue: 0.188)
    public static let orange = RGBA(red: 1.0, green: 0.584, blue: 0.0)
    public static let yellow = RGBA(red: 1.0, green: 0.8, blue: 0.0)
    public static let green = RGBA(red: 0.204, green: 0.78, blue: 0.349)
    public static let blue = RGBA(red: 0.0, green: 0.478, blue: 1.0)
    public static let purple = RGBA(red: 0.686, green: 0.322, blue: 0.871)
    public static let pink = RGBA(red: 1.0, green: 0.176, blue: 0.333)
    public static let white = RGBA.white
    public static let black = RGBA.black

    public static let all: [(name: String, color: RGBA)] = [
        ("red", red), ("orange", orange), ("yellow", yellow), ("green", green), ("blue", blue),
        ("purple", purple), ("pink", pink), ("white", white), ("black", black),
    ]

    /// Highlight is always semi-transparent (SPEC §02 §5.1).
    public static let highlightAlpha = 0.35
}
