import AppKit
import QuartzCore

/// What the image layer shows.
enum CanvasContents: Sendable {
    case surface(IOSurface)
    case image(CGImage)
}

/// Reusable IOSurfaces for canvas renders. A surface CoreAnimation still reads is never drawn into.
@MainActor
final class CanvasSurfacePool {
    /// Larger canvases (long scroll captures) exceed the GPU texture limit and fall back to a bitmap.
    static let maximumDimension = 16_384
    private var spare: [IOSurface] = []

    func acquire(width: Int, height: Int, space: CGColorSpace) -> IOSurface? {
        guard width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension else { return nil }
        spare.removeAll { $0.width != width || $0.height != height }
        let surface: IOSurface
        if let index = spare.firstIndex(where: { !$0.isInUse }) {
            surface = spare.remove(at: index)
        } else {
            let properties: [IOSurfacePropertyKey: any Sendable] = [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: Self.bgra]
            guard let created = IOSurface(properties: properties) else { return nil }
            surface = created
        }
        if let colorSpace = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpace) }
        return surface
    }

    func recycle(_ surface: IOSurface) {
        spare.append(surface)
        if spare.count > 2 { spare.removeFirst(spare.count - 2) }
    }

    private static let bgra: UInt32 = 0x4247_5241
}

/// Transparent, event-transparent layer for drafts and handles above the canvas image (ANN-09).
@MainActor
final class CanvasOverlayView: NSView {
    weak var canvas: DocumentCanvasView?
    init(canvas: DocumentCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        canvas?.drawOverlay(in: context)
        canvas?.overlayDidDraw()
    }
}
