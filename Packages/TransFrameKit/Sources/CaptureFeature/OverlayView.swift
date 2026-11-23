import AppKit
import TFDesignSystem
import TFDomain

/// Borderless key window covering one display at shielding level, on every Space and over full-screen apps (CAP-02).
final class OverlayWindow: NSPanel {
    init(display: DisplayDescriptor, primaryHeight: Double) {
        let frame = QuartzConversion.cocoaRect(fromQuartz: display.frame, primaryHeight: primaryHeight)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Events from an overlay view, in Quartz global points.
@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayMouseMoved(_ point: QuartzPoint)
    func overlayMouseDown(_ point: QuartzPoint, clickCount: Int)
    func overlayMouseDragged(_ point: QuartzPoint)
    func overlayMouseUp(_ point: QuartzPoint)
    func overlayRightMouseDown()
    func overlayKeyDown(_ event: NSEvent) -> Bool
}

/// Draws the frozen frame and the selection chrome with layers only (no animation on the hot path, SPEC §05 §1.5).
@MainActor
final class OverlayView: NSView {
    weak var delegate: OverlayViewDelegate?
    let display: DisplayDescriptor
    let frame0: CapturedFrame
    private let imageLayer = CALayer()
    private let scrimLayer = CAShapeLayer()
    private let candidateLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()
    private let magnifier = CALayer()
    private let magnifierImage = CALayer()
    private let magnifierCross = CAShapeLayer()
    private let magnifierLabel = CATextLayer()
    var labelTexts: (candidate: String?, size: String?) = (nil, nil)

    init(frame captured: CapturedFrame) {
        display = captured.display
        frame0 = captured
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: captured.display.frame.width, height: captured.display.frame.height)))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        let backing = Double(captured.image.pixelSize.width) / max(captured.display.frame.width, 1)
        imageLayer.contents = captured.image.cgImage
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        imageLayer.contentsScale = backing
        root.addSublayer(imageLayer)

        scrimLayer.fillRule = .evenOdd
        scrimLayer.fillColor = DS.Overlay.scrim.cgColor
        candidateLayer.fillColor = DS.Overlay.accent.withAlphaComponent(DS.Overlay.candidateFillAlpha).cgColor
        candidateLayer.strokeColor = DS.Overlay.accent.withAlphaComponent(DS.Overlay.candidateStrokeAlpha).cgColor
        candidateLayer.lineWidth = DS.Overlay.selectionLineWidth
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = DS.Overlay.accent.cgColor
        selectionLayer.lineWidth = DS.Overlay.selectionLineWidth
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = DS.Overlay.accent.cgColor
        handlesLayer.lineWidth = 1.5
        for text in [labelLayer, magnifierLabel] {
            text.font = DS.Overlay.labelFont()
            text.fontSize = 12
            text.foregroundColor = DS.Overlay.labelText.cgColor
            text.backgroundColor = DS.Overlay.labelBackground.cgColor
            text.cornerRadius = DS.Radius.s
            text.alignmentMode = .center
            text.contentsScale = backing
            text.isHidden = true
        }
        magnifier.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        magnifier.borderColor = NSColor.white.cgColor
        magnifier.borderWidth = 2
        magnifier.cornerRadius = DS.Radius.m
        magnifier.masksToBounds = true
        magnifier.isHidden = true
        magnifierImage.frame = magnifier.bounds
        magnifierImage.magnificationFilter = .nearest
        magnifierImage.contentsGravity = .resize
        magnifierCross.strokeColor = DS.Overlay.accent.cgColor
        magnifierCross.fillColor = nil
        magnifierCross.lineWidth = 1
        magnifierCross.frame = magnifier.bounds
        magnifier.addSublayer(magnifierImage)
        magnifier.addSublayer(magnifierCross)
        for sub in [scrimLayer, candidateLayer, selectionLayer, handlesLayer, labelLayer, magnifier, magnifierLabel] as [CALayer] {
            sub.frame = bounds
            sub.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(), "string": NSNull()]
            root.addSublayer(sub)
        }
        magnifier.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        setAccessibilityRole(.layoutArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    // MARK: Coordinate conversion (view is y-down at the display's top-left = DisplayLocal)

    func global(_ local: CGPoint) -> QuartzPoint {
        QuartzPoint(x: local.x + display.frame.minX, y: local.y + display.frame.minY)
    }

    func local(_ rect: QuartzRect) -> CGRect {
        rect.raw.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    // MARK: Rendering state

    func render(selection: QuartzRect?, candidate: QuartzRect?, showHandles: Bool, pointer: QuartzPoint, showMagnifier: Bool, hex: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scrim = CGMutablePath()
        scrim.addRect(bounds)
        let localSelection = selection.map(local)
        if let localSelection { scrim.addRect(localSelection) }
        scrimLayer.path = scrim
        selectionLayer.path = localSelection.map { CGPath(rect: $0.insetBy(dx: -1, dy: -1), transform: nil) }
        candidateLayer.path = candidate.map { CGPath(rect: local($0).insetBy(dx: 1, dy: 1), transform: nil) }

        let handles = CGMutablePath()
        if showHandles, let selection {
            let size = DS.Overlay.handleSize
            for point in SelectionModel.handlePoints(selection).values {
                let p = CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
                handles.addRect(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            }
        }
        handlesLayer.path = handles

        let labelText = selection != nil ? labelTexts.size : labelTexts.candidate
        if let labelText, let anchor = localSelection ?? candidate.map(local) {
            labelLayer.string = labelText
            let width = CGFloat(labelText.count) * 7.5 + 16
            var origin = CGPoint(x: anchor.minX, y: anchor.minY - 24)
            if origin.y < 4 { origin.y = anchor.minY + 4 }
            origin.x = min(max(origin.x, 4), bounds.width - width - 4)
            labelLayer.frame = CGRect(x: origin.x, y: origin.y, width: width, height: 20)
            labelLayer.isHidden = !bounds.intersects(anchor)
        } else {
            labelLayer.isHidden = true
        }
        updateMagnifier(pointer: pointer, visible: showMagnifier, hex: hex)
        CATransaction.commit()
    }

    /// Pixel magnifier around the pointer (CAP-11), read from the frozen frame only.
    private func updateMagnifier(pointer: QuartzPoint, visible: Bool, hex: String?) {
        let p = CGPoint(x: pointer.x - display.frame.minX, y: pointer.y - display.frame.minY)
        guard visible, bounds.contains(p) else {
            magnifier.isHidden = true
            magnifierLabel.isHidden = true
            return
        }
        let scale = frame0.pixelScale
        let span = 15
        let center = CGPoint(x: (p.x * scale).rounded(.down), y: (p.y * scale).rounded(.down))
        let cropRect = CGRect(x: center.x - CGFloat(span / 2), y: center.y - CGFloat(span / 2), width: CGFloat(span), height: CGFloat(span))
        magnifierImage.contents = frame0.image.cgImage.cropping(to: cropRect)
        let cross = CGMutablePath()
        let cell = magnifier.bounds.width / CGFloat(span)
        let mid = CGFloat(span / 2) * cell
        cross.addRect(CGRect(x: mid, y: mid, width: cell, height: cell))
        magnifierCross.path = cross
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + 124 > bounds.width { origin.x = p.x - 140 }
        if origin.y + 150 > bounds.height { origin.y = p.y - 170 }
        magnifier.frame = CGRect(origin: origin, size: CGSize(width: 120, height: 120))
        magnifier.isHidden = false
        if let hex {
            magnifierLabel.string = "\(hex)  \(Int(center.x)),\(Int(center.y))"
            magnifierLabel.frame = CGRect(x: origin.x, y: origin.y + 124, width: 120, height: 20)
            magnifierLabel.isHidden = false
        }
    }

    /// HEX of the frozen pixel under a global point (CAP-12).
    func hex(at pointer: QuartzPoint) -> String? {
        let p = CGPoint(x: pointer.x - display.frame.minX, y: pointer.y - display.frame.minY)
        guard bounds.contains(p) else { return nil }
        let scale = frame0.pixelScale
        guard let pixel = frame0.image.cgImage.cropping(to: CGRect(x: (p.x * scale).rounded(.down), y: (p.y * scale).rounded(.down), width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return String(format: "#%02X%02X%02X", data[0], data[1], data[2])
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) { delegate?.overlayMouseMoved(global(convert(event.locationInWindow, from: nil))) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.overlayMouseDown(global(convert(event.locationInWindow, from: nil)), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { delegate?.overlayMouseDragged(global(convert(event.locationInWindow, from: nil))) }
    override func mouseUp(with event: NSEvent) { delegate?.overlayMouseUp(global(convert(event.locationInWindow, from: nil))) }
    override func rightMouseDown(with event: NSEvent) { delegate?.overlayRightMouseDown() }
    /// The frozen screen swallows scrolling so nothing reaches the apps below (CAP-15).
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if delegate?.overlayKeyDown(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { delegate?.overlayKeyDown(event) ?? false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
