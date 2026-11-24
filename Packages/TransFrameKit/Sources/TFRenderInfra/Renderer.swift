import AppKit
import CoreGraphics
import CoreText
import Foundation
import os
import TFDomain

/// The single render executor (ADR-0006): screen, clipboard, file, pin, thumbnail and analysis input
/// all draw through `draw(_:base:in:)`. Deterministic for a given plan, base image and fonts.
public final class CoreGraphicsRenderer: RenderPlanExecuting, TextMeasuring {
    /// Mosaic grids belong to `base`; a different base image resets the cache, so reused object addresses never match (review-1 P2-8).
    private struct MosaicState: @unchecked Sendable {
        var base: CGImage?
        var grids: [Int: CGImage] = [:]
    }
    private let mosaicCache = OSAllocatedUnfairLock<MosaicState>(initialState: MosaicState())

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

    /// Transparent margin (or a matte for JPEG) with the content's shadow; the content itself is clipped to the rounded rect.
    private func drawBeautifyBackground(_ style: BeautifyStyle, canvas: CGRect, content: CGRect, scale: Double, in context: CGContext) {
        if case .matte(let color) = style {
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        }
        let radius = BeautifyStyle.cornerRadius * scale
        context.saveGState()
        // Shadow offsets ignore the CTM: in device space (y up) a negative offset falls below the content of the y-down plan.
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: BeautifyStyle.shadowRadius * scale, color: CGColor(gray: 0, alpha: 0.35))
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
            // A sampled backdrop replaces the original background, so it stays nearly square; a fill reads as a label.
            let isSampled = if case .sampled = placement.backdrop { true } else { false }
            let radius = isSampled ? min(1 * scale, backdropRect.height / 6) : min(3 * scale, backdropRect.height / 4)
            context.addPath(CGPath(roundedRect: backdropRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        TextDrawing.draw(
            placement.text, in: placement.frame.raw, fontSize: placement.fontSize, color: placement.color,
            alignment: placement.alignment, rightToLeft: placement.isRightToLeft, monospaced: placement.monospaced, context: context
        )
    }

    private func drawRedaction(_ item: PlacedRedaction, base: PixelImage, in context: CGContext) {
        switch item.style {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(item.frame.raw)
        case .mosaic(let blockSize):
            guard let tile = mosaic(base, item.source.raw, blockSize) else { return }
            let dx = item.frame.minX - item.source.minX, dy = item.frame.minY - item.source.minY
            context.saveGState()
            context.clip(to: item.frame.raw)
            context.interpolationQuality = .none
            Bitmap.drawImage(tile.image, in: tile.cover.offsetBy(dx: dx, dy: dy), context: context)
            context.restoreGState()
        }
    }

    // MARK: Mosaic (one pixelated grid per base image and block size)

    /// Pixelated tile covering `rect` (document pixels): `image` is drawn into `cover` with nearest-neighbour scaling and
    /// clipped to the region. Blocks sit on the image grid, so a mosaic being dragged or resized does not re-grid
    /// (no shimmering), and all regions of one block size share a single downsample.
    func mosaic(_ base: PixelImage, _ rect: CGRect, _ blockSize: Double) -> AnnotationDrawing.MosaicTile? {
        let bounds = CGRect(x: 0, y: 0, width: base.cgImage.width, height: base.cgImage.height)
        let region = rect.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let block = max(Int(blockSize.rounded()), 2)
        guard let grid = mosaicGrid(base, block: block) else { return nil }
        let c0 = Int(region.minX) / block, r0 = Int(region.minY) / block
        let c1 = (Int(region.maxX) + block - 1) / block, r1 = (Int(region.maxY) + block - 1) / block
        guard let image = grid.cropping(to: CGRect(x: c0, y: r0, width: c1 - c0, height: r1 - r0)) else { return nil }
        let cover = CGRect(x: c0 * block, y: r0 * block, width: (c1 - c0) * block, height: (r1 - r0) * block)
        return AnnotationDrawing.MosaicTile(image: image, cover: cover, region: region)
    }

    private func mosaicGrid(_ base: PixelImage, block: Int) -> CGImage? {
        let image = base.cgImage
        if let cached = mosaicCache.withLock({ state -> CGImage? in
            if state.base !== image { state = MosaicState(base: image) }
            return state.grids[block]
        }) { return cached }
        let columns = (image.width + block - 1) / block, rows = (image.height + block - 1) / block
        guard let small = Bitmap.context(size: PixelSize(width: columns, height: rows), colorSpace: image.colorSpace) else { return nil }
        small.interpolationQuality = .medium
        // Stretched first so a partial last column or row is opaque, then the exactly aligned pass on top.
        small.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        let width = Double(image.width) / Double(block), height = Double(image.height) / Double(block)
        small.draw(image, in: CGRect(x: 0, y: Double(rows) - height, width: width, height: height))
        guard let grid = small.makeImage() else { return nil }
        mosaicCache.withLock { state in
            guard state.base === image else { return }
            if state.grids.count >= 8 { state.grids.removeAll() }
            state.grids[block] = grid
        }
        return grid
    }

    // MARK: TextMeasuring (same attributes as drawing)

    public func measure(_ text: String, fontSize: Double, maxWidth: Double, monospaced: Bool) -> TextMetrics {
        TextDrawing.measure(text, fontSize: fontSize, maxWidth: maxWidth, monospaced: monospaced)
    }

    public func measure(_ text: String, fontSize: Double, maxWidth: Double) -> TextMetrics {
        TextDrawing.measure(text, fontSize: fontSize, maxWidth: maxWidth)
    }
}

// MARK: - Bitmap helpers

enum Bitmap {
    static func context(size: PixelSize, colorSpace: CGColorSpace?) -> CGContext? {
        let space = (colorSpace.map { $0.supportsOutput && $0.model == .rgb } == true ? colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
