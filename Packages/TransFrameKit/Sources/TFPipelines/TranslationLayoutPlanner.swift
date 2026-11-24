import CoreGraphics
import Foundation
import TFDomain

/// In-place bilingual layout (ADR-0006 "原位渲染"). Pure given the injected text measurer.
/// Order of attempts: fit at the estimated size → wrap → shrink (≥ 60 % and ≥ 9 pt) → omit.
public struct TranslationLayoutPlanner: Sendable {
    let measurer: any TextMeasuring

    public static let minimumScale = 0.6
    public static let minimumPoints = 9.0
    public static let backdropAlpha = 0.88
    public static let replaceHeightTolerance = 1.15

    public init(measurer: any TextMeasuring) {
        self.measurer = measurer
    }

    public func layout(
        analysis: AnalysisResult, translations: [BilingualSegment], mode: OverlayMode,
        offsetX: Double, offsetY: Double, canvas: CanvasRect, scale: Double
    ) -> [TranslationPlacement] {
        let byID = Dictionary(translations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let boxes = analysis.segments.map { CanvasRect($0.box.raw.offsetBy(dx: offsetX, dy: offsetY)) }
        var placements: [TranslationPlacement] = []
        for (index, segment) in analysis.segments.enumerated() {
            guard segment.translatability.isTranslatable,
                  let bilingual = byID[segment.id], bilingual.status == .translated,
                  let text = bilingual.translated?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            let box = boxes[index]
            let estimate = estimatedFontSize(segment, scale: scale)
            let floor = max(estimate * Self.minimumScale, Self.minimumPoints * scale)
            let background = segment.style?.background
            let foreground = textColor(for: segment, background: background)
            let rtl = bilingual.to.isRightToLeft
            let alignment: RenderTextAlignment = rtl ? .trailing : (segment.style?.alignment ?? .leading)
            let monospaced = segment.style?.monospaced ?? false
            switch mode {
            case .belowOriginal:
                let gap = max(2 * scale, 1)
                let top = box.maxY + gap
                let limit = nextObstacleTop(below: box, index: index, boxes: boxes, canvasBottom: canvas.maxY)
                let width = min(max(box.width, estimate * 4), max(canvas.maxX - box.minX, box.width))
                let available = CanvasRect(x: box.minX, y: top, width: width, height: max(limit - top, 0))
                let decision = fit(text, in: available, estimate: estimate, floor: floor, allowGrowDown: true, monospaced: monospaced)
                let backdropColor = (background ?? .white).withAlpha(background == nil ? Self.backdropAlpha : 1)
                placements.append(TranslationPlacement(
                    segment: segment.id, text: text,
                    frame: decision.frame ?? available, fontSize: decision.fontSize, color: foreground,
                    backdrop: .fill(backdropColor), backdropFrame: decision.frame?.insetBy(dx: -2 * scale, dy: -1 * scale),
                    alignment: alignment, fit: decision.fit, isRightToLeft: rtl, monospaced: monospaced
                ))
            case .replaceOriginal:
                // The translation takes the original's place: same background (opaque when sampled), vertically centred, and a
                // single line may use the box's leading (15 %) so it keeps the original size instead of shrinking.
                let decision = fit(text, in: box, estimate: estimate, floor: floor, allowGrowDown: false, monospaced: monospaced,
                                   heightTolerance: Self.replaceHeightTolerance, centred: true)
                let backdrop: Backdrop = background.map { .sampled($0.withAlpha(1)) } ?? .fill(RGBA.white.withAlpha(Self.backdropAlpha))
                placements.append(TranslationPlacement(
                    segment: segment.id, text: text, frame: decision.frame ?? box, fontSize: decision.fontSize, color: foreground,
                    backdrop: backdrop, backdropFrame: decision.fit == .omitted ? nil : coverFrame(for: box, index: index, boxes: boxes, scale: scale),
                    alignment: alignment, fit: decision.fit, isRightToLeft: rtl, monospaced: monospaced
                ))
            }
        }
        return placements
    }

    struct Decision {
        let frame: CanvasRect?
        let fontSize: Double
        let fit: FitDecision
    }

    func fit(
        _ text: String, in area: CanvasRect, estimate: Double, floor: Double, allowGrowDown: Bool, monospaced: Bool = false,
        heightTolerance: Double = 1, centred: Bool = false
    ) -> Decision {
        guard area.width > 1, area.height > 1 else { return Decision(frame: nil, fontSize: estimate, fit: .omitted) }
        func measure(_ size: Double, _ width: Double) -> TextMetrics { measurer.measure(text, fontSize: size, maxWidth: width, monospaced: monospaced) }
        let single = measure(estimate, .greatestFiniteMagnitude)
        if single.width <= area.width, single.height <= area.height * heightTolerance {
            return Decision(frame: frame(in: area, height: single.height, centred: centred), fontSize: estimate, fit: .fits)
        }
        let wrapped = measure(estimate, area.width)
        if wrapped.height <= area.height, wrapped.width <= area.width + 0.5 {
            return Decision(frame: frame(in: area, height: wrapped.height, centred: centred), fontSize: estimate, fit: .wrapped)
        }
        var size = estimate
        while size - 0.5 >= floor {
            size -= 0.5
            let metrics = measure(size, area.width)
            let tolerance = metrics.lineCount == 1 ? heightTolerance : 1
            if metrics.height <= area.height * tolerance, metrics.width <= area.width + 0.5 {
                return Decision(frame: frame(in: area, height: metrics.height, centred: centred), fontSize: size, fit: .shrunk)
            }
        }
        return Decision(frame: nil, fontSize: floor, fit: .omitted)
    }

    /// Top-aligned for text below the original; centred on the original line when replacing it.
    private func frame(in area: CanvasRect, height: Double, centred: Bool = false) -> CanvasRect {
        let h = height.rounded(.up)
        guard centred else { return CanvasRect(x: area.minX, y: area.minY, width: area.width, height: min(h, area.height)) }
        return CanvasRect(x: area.minX, y: area.midY - h / 2, width: area.width, height: h)
    }

    func estimatedFontSize(_ segment: TextSegment, scale: Double) -> Double {
        if let size = segment.style?.fontSize, size > 0 { return size }
        if let first = segment.lines?.first { return max(first.box.height * 0.78, Self.minimumPoints * scale) }
        let lineCount = max(Double(segment.effectiveText.split(separator: "\n").count), 1)
        return max(segment.box.height / lineCount * 0.78, Self.minimumPoints * scale)
    }

    private func textColor(for segment: TextSegment, background: RGBA?) -> RGBA {
        let backdrop = background ?? .white
        if let foreground = segment.style?.foreground, RGBA.contrastRatio(foreground, backdrop) >= 4.5 { return foreground }
        return RGBA.contrastRatio(.black, backdrop) >= RGBA.contrastRatio(.white, backdrop) ? .black : .white
    }

    /// OCR boxes hug the glyphs' x-height band, so ascenders and descenders peek out. The cover grows ~18 % vertically and a
    /// few pixels sideways, but never past the midpoint to a neighbouring line.
    func coverFrame(for box: CanvasRect, index: Int, boxes: [CanvasRect], scale: Double) -> CanvasRect {
        let grow = max(box.height * 0.18, 1 * scale)
        var top = box.minY - grow, bottom = box.maxY + grow
        for (other, candidate) in boxes.enumerated() where other != index {
            guard candidate.minX < box.maxX, candidate.maxX > box.minX else { continue }
            if candidate.maxY <= box.minY + 0.5 { top = max(top, (candidate.maxY + box.minY) / 2) }
            if candidate.minY >= box.maxY - 0.5 { bottom = min(bottom, (box.maxY + candidate.minY) / 2) }
        }
        return CanvasRect(x: box.minX - 2 * scale, y: top, width: box.width + 4 * scale, height: max(bottom - top, box.height))
    }

    /// Top of the nearest box below that overlaps horizontally, or the canvas bottom.
    private func nextObstacleTop(below box: CanvasRect, index: Int, boxes: [CanvasRect], canvasBottom: Double) -> Double {
        var limit = canvasBottom
        for (other, candidate) in boxes.enumerated() where other != index {
            let overlapsHorizontally = candidate.minX < box.maxX && candidate.maxX > box.minX
            if overlapsHorizontally, candidate.minY >= box.maxY - 0.5, candidate.minY < limit { limit = candidate.minY }
        }
        return limit
    }
}
