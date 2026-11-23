import AppKit
import CoreGraphics
import CoreText
import Foundation
import TFDomain

// MARK: - Text (CoreText). Measuring and drawing share one attribute builder so layout matches pixels.

enum TextDrawing {
    static func attributes(
        fontSize: Double, color: RGBA, alignment: RenderTextAlignment, rightToLeft: Bool, fontName: String? = nil, bold: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        let font: CTFont
        if let fontName, let custom = NSFont(name: fontName, size: fontSize) {
            font = custom as CTFont
        } else {
            font = (bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)) as CTFont
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .natural
        paragraph.alignment = switch alignment {
        case .leading: rightToLeft ? .right : .left
        case .center: .center
        case .trailing: rightToLeft ? .left : .right
        }
        paragraph.lineHeightMultiple = 1.08
        return [.font: font, .foregroundColor: color.cgColor, .paragraphStyle: paragraph]
    }

    static func measure(_ text: String, fontSize: Double, maxWidth: Double, fontName: String? = nil) -> TextMetrics {
        let string = NSAttributedString(
            string: text, attributes: attributes(fontSize: fontSize, color: .black, alignment: .leading, rightToLeft: false, fontName: fontName))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let constraint = CGSize(width: maxWidth.isFinite ? maxWidth : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: CGSize(width: max(size.width.rounded(.up), 1), height: max(size.height.rounded(.up) + 2, 1))),
            transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 1
        return TextMetrics(width: Double(size.width.rounded(.up)), height: Double(size.height.rounded(.up)), lineCount: max(lines, 1))
    }

    /// Draws wrapped text into `rect` of a y-down context.
    static func draw(
        _ text: String, in rect: CGRect, fontSize: Double, color: RGBA, alignment: RenderTextAlignment, rightToLeft: Bool,
        fontName: String? = nil, bold: Bool = false, context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let string = NSAttributedString(
            string: text,
            attributes: attributes(fontSize: fontSize, color: color, alignment: alignment, rightToLeft: rightToLeft, fontName: fontName, bold: bold))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let height = rect.height + 2
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        context.clip(to: rect.insetBy(dx: -1, dy: -1))
        context.translateBy(x: rect.minX, y: rect.minY + height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

// MARK: - Annotations (document pixel geometry; the caller has translated the context to the canvas)

enum AnnotationDrawing {
    typealias Mosaic = (PixelImage, CGRect, Double) -> CGImage?

    static func draw(_ annotation: Annotation, base: PixelImage, mosaic: Mosaic, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation {
        case .rectangle(let a):
            let rect = a.rect.raw.standardized
            if a.isFilled { fill(rect, a.fillColor, context) }
            stroke(CGPath(rect: rect, transform: nil), a.strokeColor, a.lineWidth, context)
        case .ellipse(let a):
            let rect = a.rect.raw.standardized
            if a.isFilled {
                context.setFillColor(a.fillColor.cgColor)
                context.fillEllipse(in: rect)
            }
            stroke(CGPath(ellipseIn: rect, transform: nil), a.strokeColor, a.lineWidth, context)
        case .highlight(let a):
            fill(a.rect.raw.standardized, a.strokeColor.withAlpha(AnnotationPalette.highlightAlpha), context)
        case .line(let a):
            let path = CGMutablePath()
            path.move(to: a.start.raw)
            path.addLine(to: a.end.raw)
            stroke(path, a.color, a.lineWidth, context)
        case .arrow(let a):
            drawArrow(a, context)
        case .freehand(let a):
            stroke(smoothPath(a.points.map(\.raw)), a.color, a.lineWidth, context)
        case .text(let a):
            let width = a.maxWidth ?? TextDrawing.measure(a.text, fontSize: a.fontSize, maxWidth: .greatestFiniteMagnitude, fontName: a.fontName).width + 2
            let metrics = TextDrawing.measure(a.text, fontSize: a.fontSize, maxWidth: width, fontName: a.fontName)
            TextDrawing.draw(
                a.text, in: CGRect(x: a.anchor.x, y: a.anchor.y, width: width, height: metrics.height), fontSize: a.fontSize, color: a.color,
                alignment: .leading, rightToLeft: false, fontName: a.fontName, context: context
            )
        case .numberLabel(let a):
            let rect = CGRect(x: a.center.x - a.diameter / 2, y: a.center.y - a.diameter / 2, width: a.diameter, height: a.diameter)
            context.setFillColor(a.color.cgColor)
            context.fillEllipse(in: rect)
            let textColor: RGBA = RGBA.contrastRatio(.white, a.color) >= RGBA.contrastRatio(.black, a.color) ? .white : .black
            let fontSize = a.diameter * 0.55
            let text = "\(a.number)"
            let metrics = TextDrawing.measure(text, fontSize: fontSize, maxWidth: .greatestFiniteMagnitude)
            TextDrawing.draw(
                text, in: CGRect(x: rect.minX, y: rect.midY - metrics.height / 2, width: rect.width, height: metrics.height),
                fontSize: fontSize, color: textColor, alignment: .center, rightToLeft: false, bold: true, context: context
            )
        case .callout(let a):
            drawCallout(a, context)
        case .mosaic(let a):
            guard let image = mosaic(base, a.rect.raw.standardized, a.blockSize) else { return }
            context.interpolationQuality = .none
            Bitmap.drawImage(
                image, in: a.rect.raw.standardized.integral.intersection(CGRect(x: 0, y: 0, width: base.cgImage.width, height: base.cgImage.height)),
                context: context)
        case .redaction(let a):
            fill(a.rect.raw.standardized, a.fill, context)
        }
    }

    private static func fill(_ rect: CGRect, _ color: RGBA, _ context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    private static func stroke(_ path: CGPath, _ color: RGBA, _ width: Double, _ context: CGContext) {
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }

    static func arrowHead(start: CGPoint, end: CGPoint, lineWidth: Double) -> (tip: CGPoint, left: CGPoint, right: CGPoint, base: CGPoint) {
        // Explicit Double math: CGFloat/Double overloads of cos/sin are ambiguous on Swift 6.2 (Xcode 26.2 floor).
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let ex = Double(end.x), ey = Double(end.y)
        let angle: Double = Foundation.atan2(dy, dx)
        let length: Double = Foundation.hypot(dx, dy)
        let headLength = min(max(lineWidth * 4, 10), max(length * 0.6, 4))
        let spread = Double.pi / 7
        let left = CGPoint(x: ex - headLength * Foundation.cos(angle - spread), y: ey - headLength * Foundation.sin(angle - spread))
        let right = CGPoint(x: ex - headLength * Foundation.cos(angle + spread), y: ey - headLength * Foundation.sin(angle + spread))
        let base = CGPoint(x: ex - headLength * 0.8 * Foundation.cos(angle), y: ey - headLength * 0.8 * Foundation.sin(angle))
        return (end, left, right, base)
    }

    private static func drawArrow(_ a: LineAnnotation, _ context: CGContext) {
        let head = arrowHead(start: a.start.raw, end: a.end.raw, lineWidth: a.lineWidth)
        let shaft = CGMutablePath()
        shaft.move(to: a.start.raw)
        shaft.addLine(to: head.base)
        stroke(shaft, a.color, a.lineWidth, context)
        let triangle = CGMutablePath()
        triangle.move(to: head.tip)
        triangle.addLine(to: head.left)
        triangle.addLine(to: head.right)
        triangle.closeSubpath()
        context.addPath(triangle)
        context.setFillColor(a.color.cgColor)
        context.fillPath()
    }

    /// Quadratic smoothing through midpoints.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func drawCallout(_ a: CalloutAnnotation, _ context: CGContext) {
        let bubble = a.bubble.raw.standardized
        let radius = min(a.fontSize * 0.6, bubble.height / 2)
        let path = CGMutablePath()
        path.addRoundedRect(in: bubble, cornerWidth: radius, cornerHeight: radius)
        if !bubble.contains(a.pointer.raw) {
            let center = CGPoint(x: bubble.midX, y: bubble.midY)
            let base = max(min(bubble.width, bubble.height) * 0.25, 6)
            let angle: Double = Foundation.atan2(Double(a.pointer.y - center.y), Double(a.pointer.x - center.x))
            let perpendicular = angle + .pi / 2
            let half = Double(base) / 2, cx = Double(center.x), cy = Double(center.y)
            let p1 = CGPoint(x: cx + half * Foundation.cos(perpendicular), y: cy + half * Foundation.sin(perpendicular))
            let p2 = CGPoint(x: cx - half * Foundation.cos(perpendicular), y: cy - half * Foundation.sin(perpendicular))
            path.move(to: p1)
            path.addLine(to: a.pointer.raw)
            path.addLine(to: p2)
            path.closeSubpath()
        }
        context.addPath(path)
        context.setFillColor(a.fillColor.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(a.color.cgColor)
        context.setLineWidth(max(a.fontSize / 12, 1))
        context.strokePath()
        let inset = bubble.insetBy(dx: a.fontSize * 0.5, dy: a.fontSize * 0.35)
        let textColor: RGBA = RGBA.contrastRatio(a.color, a.fillColor) >= 3 ? a.color : (RGBA.contrastRatio(.black, a.fillColor) > 4.5 ? .black : .white)
        TextDrawing.draw(a.text, in: inset, fontSize: a.fontSize, color: textColor, alignment: .leading, rightToLeft: false, context: context)
    }
}
