import CoreGraphics
import Foundation
import TFDomain

/// Pure geometry for annotation interaction: hit testing, handles, resize, ⌘ constraints (ANN-09, ANN-12).
public enum AnnotationGeometry {
    public static func rect(from a: DocumentPoint, to b: DocumentPoint, square: Bool) -> DocumentRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return DocumentRect(CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy)))
    }

    /// Snaps a line to multiples of 45°.
    public static func snap45(_ start: DocumentPoint, _ end: DocumentPoint) -> DocumentPoint {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        let length = start.distance(to: end)
        return DocumentPoint(x: start.x + length * cos(snapped), y: start.y + length * sin(snapped))
    }

    static func box(of annotation: Annotation) -> DocumentRect? {
        switch annotation {
        case .rectangle(let a), .ellipse(let a), .highlight(let a): a.rect
        case .mosaic(let a): a.rect
        case .redaction(let a): a.rect
        case .callout(let a): a.bubble
        default: nil
        }
    }

    public static func handles(for annotation: Annotation) -> [AnnotationHandle: DocumentPoint] {
        switch annotation {
        case .line(let l), .arrow(let l): return [.start: l.start, .end: l.end]
        default:
            guard let r = box(of: annotation)?.standardized else { return [:] }
            return [
                .topLeft: DocumentPoint(x: r.minX, y: r.minY), .top: DocumentPoint(x: r.midX, y: r.minY),
                .topRight: DocumentPoint(x: r.maxX, y: r.minY), .right: DocumentPoint(x: r.maxX, y: r.midY),
                .bottomRight: DocumentPoint(x: r.maxX, y: r.maxY), .bottom: DocumentPoint(x: r.midX, y: r.maxY),
                .bottomLeft: DocumentPoint(x: r.minX, y: r.maxY), .left: DocumentPoint(x: r.minX, y: r.midY),
            ]
        }
    }

    /// Moves one handle; with ⌘ the box keeps its aspect ratio (ANN-12).
    public static func resize(_ annotation: Annotation, handle: AnnotationHandle, to p: DocumentPoint, constrain: Bool) -> Annotation {
        switch annotation {
        case .line(var l):
            if handle == .start { l.start = constrain ? snap45(l.end, p) : p } else { l.end = constrain ? snap45(l.start, p) : p }
            return .line(l)
        case .arrow(var l):
            if handle == .start { l.start = constrain ? snap45(l.end, p) : p } else { l.end = constrain ? snap45(l.start, p) : p }
            return .arrow(l)
        default:
            guard let r = box(of: annotation)?.standardized.raw else { return annotation }
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch handle {
            case .topLeft: minX = p.x; minY = p.y
            case .top: minY = p.y
            case .topRight: maxX = p.x; minY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; maxY = p.y
            case .bottom: maxY = p.y
            case .bottomLeft: minX = p.x; maxY = p.y
            case .left: minX = p.x
            case .start, .end: break
            }
            var new = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            if constrain, r.width > 0, r.height > 0, [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle) {
                let ratio = r.width / r.height
                if new.width / max(new.height, 0.0001) > ratio { new.size.width = new.height * ratio } else { new.size.height = new.width / ratio }
                if handle == .topLeft || handle == .bottomLeft { new.origin.x = maxX - new.width }
                if handle == .topLeft || handle == .topRight { new.origin.y = maxY - new.height }
            }
            return withBox(annotation, DocumentRect(new))
        }
    }

    static func withBox(_ annotation: Annotation, _ rect: DocumentRect) -> Annotation {
        switch annotation {
        case .rectangle(var a): a.rect = rect; return .rectangle(a)
        case .ellipse(var a): a.rect = rect; return .ellipse(a)
        case .highlight(var a): a.rect = rect; return .highlight(a)
        case .mosaic(var a): a.rect = rect; return .mosaic(a)
        case .redaction(var a): a.rect = rect; return .redaction(a)
        case .callout(var a): a.bubble = rect; return .callout(a)
        default: return annotation
        }
    }

    /// Applies the current style to an annotation (ANN-13).
    public static func restyle(_ annotation: Annotation, with style: AnnotationStyle, scale: Double) -> Annotation {
        let width = style.lineWidth * scale
        switch annotation {
        case .rectangle(var a):
            a.strokeColor = style.color; a.lineWidth = width; a.isFilled = style.isFilled; a.fillColor = style.fillColor
            return .rectangle(a)
        case .ellipse(var a):
            a.strokeColor = style.color; a.lineWidth = width; a.isFilled = style.isFilled; a.fillColor = style.fillColor
            return .ellipse(a)
        case .highlight(var a): a.strokeColor = style.color; return .highlight(a)
        case .line(var a): a.color = style.color; a.lineWidth = width; return .line(a)
        case .arrow(var a): a.color = style.color; a.lineWidth = width; return .arrow(a)
        case .freehand(var a): a.color = style.color; a.lineWidth = width; return .freehand(a)
        case .text(var a): a.color = style.color; a.fontSize = style.fontSize * scale; return .text(a)
        case .numberLabel(var a): a.color = style.color; return .numberLabel(a)
        case .callout(var a): a.color = style.color; a.fontSize = style.fontSize * scale; return .callout(a)
        case .mosaic(var a): a.blockSize = style.mosaicBlockSize * scale; return .mosaic(a)
        case .redaction: return annotation
        }
    }

    public static func hit(_ annotation: Annotation, point p: DocumentPoint, tolerance: Double) -> Bool {
        switch annotation {
        case .line(let l), .arrow(let l):
            return distance(p, segment: (l.start, l.end)) <= max(tolerance, l.lineWidth)
        case .freehand(let f):
            guard f.points.count > 1 else { return f.points.first.map { $0.distance(to: p) <= tolerance } ?? false }
            return zip(f.points, f.points.dropFirst()).contains { distance(p, segment: ($0, $1)) <= max(tolerance, f.lineWidth) }
        case .numberLabel(let n):
            return n.center.distance(to: p) <= n.diameter / 2 + tolerance / 2
        case .ellipse(let e) where !e.isFilled:
            let r = e.rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            return abs(d - 1) * min(r.width, r.height) / 2 <= tolerance
        case .rectangle(let rect) where !rect.isFilled:
            let outer = rect.rect.standardized.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.rect.standardized.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        default:
            return annotation.bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }

    static func distance(_ p: DocumentPoint, segment: (DocumentPoint, DocumentPoint)) -> Double {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
