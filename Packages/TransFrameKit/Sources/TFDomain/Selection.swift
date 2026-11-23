import CoreGraphics
import Foundation

// MARK: - SelectionGeometry (SPEC §02 §4)

public enum SelectionSource: Sendable, Equatable, Hashable {
    case freeform
    case window(WindowID)
    case contentBlock(BlockID)
    case display(DisplayID)
}

public struct SelectionGeometry: Sendable, Equatable {
    public let rect: QuartzRect
    public let source: SelectionSource
    public let topologyVersion: Int

    public init(rect: QuartzRect, source: SelectionSource, topologyVersion: Int) {
        self.rect = rect
        self.source = source
        self.topologyVersion = topologyVersion
    }

    public static let minimumPointSize = 5.0
    public static let maximumOutputPixels = 200_000_000
}

public struct ResolvedSelection: Sendable, Equatable {
    public let slices: [Slice]
    public let outputSize: PixelSize
    public let outputScale: Double

    public struct Slice: Sendable, Equatable {
        public let display: DisplayID
        public let local: DisplayLocalRect
        public let pixels: FrameRect
        public let destination: CanvasRect

        public init(display: DisplayID, local: DisplayLocalRect, pixels: FrameRect, destination: CanvasRect) {
            self.display = display
            self.local = local
            self.pixels = pixels
            self.destination = destination
        }
    }

    public init(slices: [Slice], outputSize: PixelSize, outputScale: Double) {
        self.slices = slices
        self.outputSize = outputSize
        self.outputScale = outputScale
    }
}

extension SelectionGeometry {
    /// Pure function: the same input always yields the same output (SPEC §02 §4).
    public func resolve(in frames: FrozenFrameSet) throws(AppError) -> ResolvedSelection {
        guard topologyVersion == frames.topology.version else { throw .capture(.topologyChanged) }
        let selection = rect.standardized
        guard selection.width >= Self.minimumPointSize, selection.height >= Self.minimumPointSize else {
            throw .capture(.selectionTooSmall)
        }

        let hits: [(CapturedFrame, QuartzRect)] = frames.frames.compactMap { frame in
            selection.intersection(frame.display.frame).map { (frame, $0) }
        }
        guard !hits.isEmpty else { throw .capture(.selectionOutOfBounds) }

        let outputScale = hits.map { $0.0.pixelScale }.max() ?? 1
        let outputWidth = Int((selection.width * outputScale).rounded(.up))
        let outputHeight = Int((selection.height * outputScale).rounded(.up))
        guard outputWidth.multipliedReportingOverflow(by: outputHeight).partialValue <= Self.maximumOutputPixels,
              outputWidth <= Self.maximumOutputPixels, outputHeight <= Self.maximumOutputPixels
        else { throw .capture(.outputTooLarge) }
        let outputBounds = CanvasRect(PixelSize(width: outputWidth, height: outputHeight).bounds)

        var slices: [ResolvedSelection.Slice] = []
        for (frame, intersection) in hits {
            let origin = frame.display.frame.origin
            let local = DisplayLocalRect(intersection.raw.offsetBy(dx: -origin.x, dy: -origin.y))
            let frameBounds = FrameRect(frame.image.pixelSize.bounds)
            guard let pixels = local.scaledOutward(by: frame.pixelScale, to: FramePixel.self).intersection(frameBounds) else { continue }
            // The destination follows the rounded source pixels so slices are not squeezed and neighbours never overlap
            // (CAP-17); parts outside the canvas are clipped when drawn.
            let scale = frame.pixelScale
            let sourcePoints = CGRect(
                x: pixels.minX / scale + origin.x, y: pixels.minY / scale + origin.y,
                width: pixels.width / scale, height: pixels.height / scale
            )
            let destination = CanvasRect(
                x: (sourcePoints.minX - selection.minX) * outputScale, y: (sourcePoints.minY - selection.minY) * outputScale,
                width: sourcePoints.width * outputScale, height: sourcePoints.height * outputScale
            )
            guard destination.intersects(outputBounds) else { continue }
            slices.append(.init(display: frame.display.id, local: local, pixels: pixels, destination: destination))
        }
        guard !slices.isEmpty else { throw .capture(.selectionOutOfBounds) }
        return ResolvedSelection(
            slices: slices, outputSize: PixelSize(width: outputWidth, height: outputHeight), outputScale: outputScale
        )
    }
}

// MARK: - Cocoa ↔ Quartz conversion (pure, used by capture and system infra)

public enum QuartzConversion {
    /// Converts a Cocoa global rect (origin bottom-left of the primary display, y up) to Quartz global.
    /// - Parameter primaryHeight: height in points of the primary display (the one at Cocoa origin).
    public static func quartzRect(fromCocoa rect: CGRect, primaryHeight: Double) -> QuartzRect {
        QuartzRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func cocoaRect(fromQuartz rect: QuartzRect, primaryHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func quartzPoint(fromCocoa point: CGPoint, primaryHeight: Double) -> QuartzPoint {
        QuartzPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func cocoaPoint(fromQuartz point: QuartzPoint, primaryHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
