import CoreGraphics
import Foundation
import ImageIO
import TFDomain
import UniformTypeIdentifiers

/// Builds the selection image from frozen frames (CAP-17): each slice is cropped from its frame and drawn
/// at the highest participating density; gaps between displays stay transparent.
public struct FrameComposer: FrameComposing {
    public init() {}

    public func compose(_ selection: ResolvedSelection, from frames: FrozenFrameSet) async throws(AppError) -> PixelImage {
        let colorSpace = frames.frames.first?.image.cgImage.colorSpace
        guard let context = Bitmap.context(size: selection.outputSize, colorSpace: colorSpace) else { throw .render(.contextUnavailable) }
        Bitmap.flip(context, height: selection.outputSize.height)
        context.interpolationQuality = .high
        for slice in selection.slices {
            guard let frame = frames.frame(for: slice.display),
                  let crop = frame.image.cgImage.cropping(to: slice.pixels.raw) else { throw .recognition(.imageUnreadable) }
            Bitmap.drawImage(crop, in: slice.destination.raw, context: context)
        }
        guard let image = context.makeImage() else { throw .render(.contextUnavailable) }
        return PixelImage(cgImage: image, scale: selection.outputScale)
    }
}

/// PNG / JPEG / HEIC encoding with DPI metadata so Retina images keep their point size (N-10).
public struct ImageCodec: ImageEncoding, Thumbnailing {
    public init() {}

    public func encode(_ image: PixelImage, format: ExportFormat, quality: Double) throws(AppError) -> Data {
        let data = NSMutableData()
        let type = format.uniformTypeIdentifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw .export(.encodingFailed) }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * image.scale,
            kCGImagePropertyDPIHeight: 72 * image.scale,
        ]
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1) }
        var source = image.cgImage
        if format == .jpeg, source.alphaInfo != .none, source.alphaInfo != .noneSkipLast, source.alphaInfo != .noneSkipFirst {
            source = Self.flattened(source) ?? source
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .export(.encodingFailed) }
        return data as Data
    }

    public func decode(_ data: Data) throws(AppError) -> PixelImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw .recognition(.imageUnreadable) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return PixelImage(cgImage: Self.oriented(image, properties: properties), scale: max(dpi / 72, 1))
    }

    /// Longest edge ≤ maxEdge, JPEG ≤ maxBytes; lowers quality, then size (HIS-11).
    public func thumbnail(of image: PixelImage, maxEdge: Int, maxBytes: Int) -> Data? {
        var edge = maxEdge
        while edge >= 32 {
            guard let scaled = Self.scaled(image.cgImage, maxEdge: edge) else { return nil }
            for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
                if let data = try? encode(PixelImage(cgImage: scaled, scale: 1), format: .jpeg, quality: quality), data.count <= maxBytes {
                    return data
                }
            }
            edge = edge * 3 / 4
        }
        return nil
    }

    static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        let factor = longest > maxEdge ? Double(maxEdge) / Double(longest) : 1
        let size = PixelSize(width: max(Int(Double(image.width) * factor), 1), height: max(Int(Double(image.height) * factor), 1))
        guard let context = Bitmap.context(size: size, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// JPEG has no alpha: composite onto white first (SPEC §02 §4 "导出为 JPEG 时填白").
    static func flattened(_ image: CGImage) -> CGImage? {
        let size = PixelSize(width: image.width, height: image.height)
        guard let context = Bitmap.context(size: size, colorSpace: image.colorSpace) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// Applies EXIF orientation so imported photos open upright.
    static func oriented(_ image: CGImage, properties: [CFString: Any]?) -> CGImage {
        guard let raw = properties?[kCGImagePropertyOrientation] as? UInt32, let orientation = CGImagePropertyOrientation(rawValue: raw),
              orientation != .up else { return image }
        let rotated = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let size = rotated ? PixelSize(width: image.height, height: image.width) : PixelSize(width: image.width, height: image.height)
        guard let context = Bitmap.context(size: size, colorSpace: image.colorSpace) else { return image }
        let w = Double(size.width), h = Double(size.height)
        var transform = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored: transform = transform.translatedBy(x: w, y: h).rotated(by: .pi)
        case .left, .leftMirrored: transform = transform.translatedBy(x: w, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored: transform = transform.translatedBy(x: 0, y: h).rotated(by: -.pi / 2)
        default: break
        }
        if [.upMirrored, .downMirrored].contains(orientation) {
            transform = transform.translatedBy(x: Double(image.width), y: 0).scaledBy(x: -1, y: 1)
        } else if [.leftMirrored, .rightMirrored].contains(orientation) {
            transform = transform.translatedBy(x: Double(image.width), y: 0).scaledBy(x: -1, y: 1)
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
