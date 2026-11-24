import CoreGraphics
import Foundation
import TFDomain

/// Synthetic images for tests; no fixtures on disk needed.
public enum TestImages {
    public static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    public static func solid(width: Int, height: Int, color: RGBA = .white, scale: Double = 1) -> PixelImage {
        let ctx = context(width: width, height: height)!
        ctx.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return PixelImage(cgImage: ctx.makeImage()!, scale: scale)
    }

    /// Horizontal gradient plus a deterministic checker so crops are distinguishable.
    public static func pattern(width: Int, height: Int, scale: Double = 1, seed: Int = 0) -> PixelImage {
        let ctx = context(width: width, height: height)!
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let v = Double(((x / 8) + (y / 8) + seed) % 5) / 5
                ctx.setFillColor(red: Double(x) / Double(max(width, 1)), green: v, blue: Double(y) / Double(max(height, 1)), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return PixelImage(cgImage: ctx.makeImage()!, scale: scale)
    }

    /// A huge image backed by a zero-filling provider; costs no memory until drawn.
    public static func virtual(width: Int, height: Int, scale: Double = 1) -> PixelImage {
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { _, buffer, _, count in
                memset(buffer, 0, count)
                return count
            },
            releaseInfo: nil
        )
        let provider = CGDataProvider(directInfo: nil, size: off_t(width * height * 4), callbacks: &callbacks)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return PixelImage(cgImage: image, scale: scale)
    }

    /// RGBA bytes of the pixel at (x, y) with the origin at the top-left.
    public static func pixel(_ image: PixelImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let ctx = context(width: 1, height: 1)!
        ctx.draw(image.cgImage, in: CGRect(x: -x, y: -(image.cgImage.height - 1 - y), width: image.cgImage.width, height: image.cgImage.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[1], data[2], data[3])
    }

    /// Byte-for-byte equality of two images after normalizing to RGBA8.
    public static func bytes(_ image: PixelImage) -> [UInt8] {
        let w = image.cgImage.width, h = image.cgImage.height
        let ctx = context(width: w, height: h)!
        ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let count = ctx.bytesPerRow * h
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: count))
    }

    public static func display(
        _ id: UInt32, x: Double, y: Double, width: Double, height: Double, scale: Double = 2, builtin: Bool = false
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: DisplayID(id), localizedName: "Display \(id)", frame: QuartzRect(x: x, y: y, width: width, height: height),
            pixelSize: PixelSize(width: Int(width * scale), height: Int(height * scale)), scale: scale,
            refreshRateHz: 60, isBuiltin: builtin
        )
    }

    /// A frozen frame set whose frames are patterns sized to each display.
    public static func frozen(
        _ displays: [DisplayDescriptor], version: Int = 1, intent: CaptureIntent = .region,
        pointer: QuartzPoint = QuartzPoint(x: 10, y: 10), windows: [WindowCandidate] = []
    ) -> FrozenFrameSet {
        let now = ContinuousClock.now
        let frames = displays.enumerated().map { index, d in
            CapturedFrame(
                display: d, image: pattern(width: d.pixelSize.width, height: d.pixelSize.height, scale: d.scale, seed: index),
                requestedAt: now, completedAt: now
            )
        }
        return FrozenFrameSet(
            request: CaptureRequest(intent: intent, trigger: .programmatic, pointer: pointer),
            topology: DisplayTopology(version: version, displays: displays, primary: displays[0].id),
            frames: frames, windows: windows
        )
    }
}
