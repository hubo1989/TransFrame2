import AppKit
import CoreGraphics
import CoreText
import Foundation
import os
import TFDomain

/// The single render executor (ADR-0006): screen, clipboard, file, pin, thumbnail and analysis input
/// all draw through `draw(_:base:in:)`. Deterministic for a given plan, base image and fonts.
public final class CoreGraphicsRenderer: RenderPlanExecuting, TextMeasuring {
    private let mosaicCache = OSAllocatedUnfairLock<[MosaicKey: CGImage]>(initialState: [:])

    public init() {}

    // MARK: RenderPlanExecuting

    public func image(for plan: RenderPlan, base: PixelImage) async throws(AppError) -> PixelImage {
        guard plan.canvas.pixelCount <= RenderPlan.maximumCanvasPixels else { throw .render(.canvasTooLarge) }
        guard let context = Bitmap.context(size: plan.canvas, colorSpace: base.cgImage.colorSpace) else {
            throw .render(.contextUnavailable)
        }
        Bitmap.flip(context, height: plan.canvas.height)
        draw(plan, base: base, in: context)
        guard let image = context.makeImage() else { throw .render(.contextUnavailable) }
        return PixelImage(cgImage: image, scale: plan.scale)
    }

    public func draw(_ plan: RenderPlan, base: PixelImage, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: plan.canvas.width, height: plan.canvas.height)
        let content = plan.contentFrame.raw
        var contentClip = CGPath(rect: content, transform: nil)

        switch plan.background {
        case .transparent:
            break
        case .white:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(canvas)
        case .beautify(let style):
            drawBeautifyBackground(style, canvas: canvas, content: content, scale: plan.scale, in: context)
            let radius = BeautifyStyle.cornerRadius * plan.scale
            contentClip = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        context.saveGState()
        context.addPath(contentClip)
        context.clip()
        for layer in plan.layers {
            switch layer {
            case .base(let source, let destination):
                drawBase(base, source: source.raw, destination: destination.raw, in: context)
            case .translation(let translation):
                for placement in translation.placements where placement.fit != .omitted {
                    drawPlacement(placement, scale: plan.scale, in: context)
                }
            case .decorations(let items):
                for item in items {
                    context.saveGState()
                    context.translateBy(x: item.offsetX, y: item.offsetY)
                    AnnotationDrawing.draw(item.annotation, base: base, mosaic: mosaic, in: context)
                    context.restoreGState()
                }
            case .redactions(let items):
                for item in items { drawRedaction(item, base: base, in: context) }
            }
        }
        context.restoreGState()
    }

    // MARK: Layers

    private func drawBase(_ base: PixelImage, source: CGRect, destination: CGRect, in context: CGContext) {
        let full = CGRect(x: 0, y: 0, width: base.cgImage.width, height: base.cgImage.height)
        let image = source.equalTo(full) ? base.cgImage : (base.cgImage.cropping(to: source) ?? base.cgImage)
        Bitmap.drawImage(image, in: destination, context: context)
    }

    private func drawBeautifyBackground(_ style: BeautifyStyle, canvas: CGRect, content: CGRect, scale: Double, in context: CGContext) {
        guard case .gradient(let start, let end) = style else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [start.cgColor, end.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: canvas.minX, y: canvas.minY), end: CGPoint(x: canvas.maxX, y: canvas.maxY), options: [])
        }
        let radius = BeautifyStyle.cornerRadius * scale
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 6 * scale), blur: BeautifyStyle.shadowRadius * scale, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    private func drawPlacement(_ placement: TranslationPlacement, scale: Double, in context: CGContext) {
        let backdropRect = (placement.backdropFrame ?? placement.frame).raw
        switch placement.backdrop {
        case .none: break
        case .fill(let color), .sampled(let color):
            context.setFillColor(color.cgColor)
            let radius = min(3 * scale, backdropRect.height / 4)
            context.addPath(CGPath(roundedRect: backdropRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        TextDrawing.draw(
            placement.text, in: placement.frame.raw, fontSize: placement.fontSize, color: placement.color,
            alignment: placement.alignment, rightToLeft: placement.isRightToLeft, context: context
        )
    }

    private func drawRedaction(_ item: PlacedRedaction, base: PixelImage, in context: CGContext) {
        switch item.style {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(item.frame.raw)
        case .mosaic(let blockSize):
            if let image = mosaic(base, item.source.raw, blockSize) {
                context.saveGState()
                context.interpolationQuality = .none
                Bitmap.drawImage(image, in: item.frame.raw, context: context)
                context.restoreGState()
            }
        }
    }

    // MARK: Mosaic (cached by region + block size + base image)

    private struct MosaicKey: Hashable {
        let image: ObjectIdentifier
        let x: Int, y: Int, width: Int, height: Int
        let block: Int
    }

    /// Small pixelated image; drawn scaled up with nearest-neighbour interpolation.
    private func mosaic(_ base: PixelImage, _ rect: CGRect, _ blockSize: Double) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.cgImage.width, height: base.cgImage.height)
        let region = rect.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let block = max(Int(blockSize.rounded()), 2)
        let key = MosaicKey(
            image: ObjectIdentifier(base.cgImage), x: Int(region.minX), y: Int(region.minY),
            width: Int(region.width), height: Int(region.height), block: block
        )
        if let cached = mosaicCache.withLock({ $0[key] }) { return cached }
        guard let crop = base.cgImage.cropping(to: region) else { return nil }
        let size = PixelSize(width: max(Int(region.width) / block, 1), height: max(Int(region.height) / block, 1))
        guard let small = Bitmap.context(size: size, colorSpace: crop.colorSpace) else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let result = small.makeImage()
        if let result {
            mosaicCache.withLock { cache in
                if cache.count > 64 { cache.removeAll() }
                cache[key] = result
            }
        }
        return result
    }

    // MARK: TextMeasuring (same attributes as drawing)

    public func measure(_ text: String, fontSize: Double, maxWidth: Double) -> TextMetrics {
        TextDrawing.measure(text, fontSize: fontSize, maxWidth: maxWidth)
    }
}

// MARK: - Bitmap helpers

enum Bitmap {
    static func context(size: PixelSize, colorSpace: CGColorSpace?) -> CGContext? {
        let space = (colorSpace?.supportsOutput == true ? colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Makes the context's origin the top-left with y pointing down.
    static func flip(_ context: CGContext, height: Int) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// Draws an image upright into a rect of a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
