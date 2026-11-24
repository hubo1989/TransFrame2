import AppKit
import Observation
import QuartzCore
import SwiftUI
import TFDesignSystem
import TFDomain

/// Layer-backed canvas that shows a session through the single render executor (ADR-0006) and hosts the
/// shared annotation interaction. Selection handles and drafts are UI overlays and never exported.
///
/// Hot paths (SPEC §05 §3 "逐帧只重画脏区"): renders are rasterized off the main actor straight into reused
/// IOSurfaces (a CGImage as layer contents costs CoreAnimation a copy of the whole bitmap on every commit), one render
/// runs at a time with the newest request winning, and the overlay redraws only the region that changed.
@MainActor
public final class DocumentCanvasView: NSView, NSTextFieldDelegate {
    public let editor: AnnotationEditor?
    private let render: any RenderWorkflow
    private let sessionID: SessionID
    private let purpose: RenderPurpose
    public private(set) var session: DocumentSession?
    public private(set) var plan: RenderPlan?
    private let imageLayer = CALayer()
    /// Drafts and selection handles sit above the rendered image and never take events.
    private lazy var overlayView = CanvasOverlayView(canvas: self)
    /// Smart mosaic scan and found-area animation, above the overlay.
    let scanView = ScanEffectView(frame: .zero)
    private var textField: NSTextField?
    /// Called after each committed render (pins and previews resize from it).
    public var onRender: ((RenderPlan) -> Void)?
    public var onEscapeUnhandled: (() -> Void)?
    /// Host shortcuts get the first look at keys (capture overlay actions), then the annotation editor.
    public var keyHandler: ((NSEvent) -> Bool)?

    public init(render: any RenderWorkflow, sessionID: SessionID, editor: AnnotationEditor?, purpose: RenderPurpose = .screen) {
        self.render = render
        self.sessionID = sessionID
        self.editor = editor
        self.purpose = purpose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        addSubview(overlayView)
        addSubview(scanView)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        setAccessibilityRole(.image)
        editor?.onDisplayChange = { [weak self] change in self?.editorChanged(change) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { editor != nil }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func update(_ session: DocumentSession) {
        let annotationsChanged = self.session?.annotations != session.annotations
        self.session = session
        editor?.update(session)
        scheduleRender()
        if annotationsChanged { updateAccessibility() }
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        overlayView.frame = bounds
        scanView.frame = bounds
        overlayCoverage = .null
        overlayView.needsDisplay = true
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        overlayView.needsDisplay = true
    }

    private func editorChanged(_ change: DisplayChange) {
        if change.contains(.render) { scheduleRender() }
        if change.contains(.overlay) { invalidateOverlay() }
        if change.contains(.text) { syncTextField() }
        if change.contains(.cursor) { window?.invalidateCursorRects(for: self) }
    }

    // MARK: Rendering

    private struct RenderKey: Equatable {
        let revision: Int
        let excluded: Set<AnnotationID>
        let translation: OperationID?
        let engine: EngineID?
        let overlay: Bool
        let beautify: Bool
    }

    private var displayedKey: RenderKey?
    private var inFlightKey: RenderKey?
    private var displayedContents: CanvasContents?
    private let surfaces = CanvasSurfacePool()

    private func currentKey(_ session: DocumentSession) -> RenderKey {
        RenderKey(
            revision: session.editRevision, excluded: editor?.renderExclusions(at: session.editRevision) ?? [],
            translation: session.translation?.operation, engine: session.translation?.effective,
            overlay: session.presentation.showsTranslationOverlay, beautify: session.presentation.beautify)
    }

    /// One render at a time; a request made meanwhile runs when it finishes (latest wins, nothing is drawn twice in parallel).
    private func scheduleRender() {
        guard let session, inFlightKey == nil else { return }
        let key = currentKey(session)
        guard key != displayedKey, let plan = try? render.plan(of: session, purpose: purpose, excluding: key.excluded) else { return }
        let base = session.baseImage
        let space = Self.colorSpace(of: base)
        let surface = surfaces.acquire(width: plan.canvas.width, height: plan.canvas.height, space: space)
        let render = render
        inFlightKey = key
        Task { [weak self] in
            let contents = await Self.rasterize(plan, base: base, render: render, into: surface, space: space)
            self?.finish(key, plan: plan, contents: contents)
        }
    }

    private func finish(_ key: RenderKey, plan: RenderPlan, contents: CanvasContents?) {
        inFlightKey = nil
        guard let contents, let session else { return }
        // A render made for an older state is only worth showing when nothing is on screen yet.
        guard key == currentKey(session) || displayedKey == nil else {
            if case .surface(let surface) = contents { surfaces.recycle(surface) }
            scheduleRender()
            return
        }
        self.plan = plan
        displayedKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch contents {
        case .surface(let surface): imageLayer.contents = surface
        case .image(let image): imageLayer.contents = image
        }
        CATransaction.commit()
        if case .surface(let old)? = displayedContents { surfaces.recycle(old) }
        displayedContents = contents
        editor?.settle(throughRevision: key.revision)
        invalidateOverlay(all: true)
        onRender?(plan)
        scheduleRender()
    }

    nonisolated static func colorSpace(of base: PixelImage) -> CGColorSpace {
        base.cgImage.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Off the main actor: draws a plan with the shared executor into `surface` (or a bitmap when the canvas is too large
    /// for one).
    @concurrent
    nonisolated static func rasterize(
        _ plan: RenderPlan, base: PixelImage, render: any RenderWorkflow, into surface: IOSurface?, space: CGColorSpace
    ) async -> CanvasContents? {
        let width = plan.canvas.width, height = plan.canvas.height
        if let surface {
            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }
            guard let context = CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            draw(plan, base: base, render: render, in: context)
            return .surface(surface)
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(plan, base: base, render: render, in: context)
        return context.makeImage().map(CanvasContents.image)
    }

    private nonisolated static func draw(_ plan: RenderPlan, base: PixelImage, render: any RenderWorkflow, in context: CGContext) {
        context.translateBy(x: 0, y: CGFloat(plan.canvas.height))
        context.scaleBy(x: 1, y: -1)
        render.draw(plan, base: base, in: context)
    }

    // MARK: Smart mosaic feedback (INP-08)

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The image area in view points (without the beautify margin).
    private var contentViewRect: CGRect {
        guard let plan else { return bounds }
        let scale = contentScale
        return CGRect(
            x: plan.contentFrame.minX * scale, y: plan.contentFrame.minY * scale,
            width: plan.contentFrame.width * scale, height: plan.contentFrame.height * scale)
    }

    /// A light band sweeps the image while detection runs.
    public func beginScanning() {
        scanView.frame = bounds
        scanView.beginScanning(in: contentViewRect, reduceMotion: reduceMotion)
    }

    /// Ends the sweep; each found area (document pixels) lights up in turn.
    public func finishScanning(found: [DocumentRect]) {
        scanView.finishScanning(found: found.map(viewRect(for:)), reduceMotion: reduceMotion)
    }

    public var isScanning: Bool { scanView.isScanning }

    // MARK: Coordinates

    /// View points per canvas pixel.
    public var contentScale: CGFloat {
        guard let plan, plan.canvas.width > 0 else { return 1 }
        return bounds.width / CGFloat(plan.canvas.width)
    }

    private var documentOffset: CGPoint {
        guard let plan, let session else { return .zero }
        let visible = session.visibleRect
        return CGPoint(x: plan.contentFrame.minX - visible.minX, y: plan.contentFrame.minY - visible.minY)
    }

    public func documentPoint(for viewPoint: CGPoint) -> DocumentPoint {
        let scale = max(contentScale, 0.0001)
        let offset = documentOffset
        return DocumentPoint(x: viewPoint.x / scale - offset.x, y: viewPoint.y / scale - offset.y)
    }

    public func viewPoint(for point: DocumentPoint) -> CGPoint {
        let offset = documentOffset
        return CGPoint(x: (point.x + offset.x) * contentScale, y: (point.y + offset.y) * contentScale)
    }

    public func viewRect(for rect: DocumentRect) -> CGRect {
        let origin = viewPoint(for: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * contentScale, height: rect.height * contentScale)
    }

    // MARK: Overlay (drafts, unsettled edits, selection chrome) — dirty regions only

    /// View area the overlay painted last; it is cleared when the content moves away.
    private var overlayCoverage: CGRect = .null
    private var lastDraft: Annotation?

    /// Annotations drawn on the overlay, bottom to top: unsettled edits, then the live draft.
    private var overlayAnnotations: [Annotation] {
        guard let editor else { return [] }
        let superseded: Set<AnnotationID> = Set([editor.draft?.id, editor.hiddenID].compactMap { $0 })
        var items = editor.pending.compactMap(\.annotation).filter { !superseded.contains($0.id) }
        if let draft = editor.draft { items.append(draft) }
        return items
    }

    private func coverage(of annotation: Annotation) -> CGRect {
        var rect = viewRect(for: annotation.bounds)
        switch annotation {
        case .text(let t):
            // Glyph metrics are estimated; leave room for wide scripts and overhang.
            rect.size.width *= 1.25
            rect = rect.insetBy(dx: -t.fontSize * contentScale * 0.5, dy: -t.fontSize * contentScale * 0.5)
        case .callout(let c):
            rect = rect.insetBy(dx: -c.fontSize * contentScale * 0.25, dy: -c.fontSize * contentScale * 0.25)
        default:
            break
        }
        return rect.insetBy(dx: -3, dy: -3)
    }

    private func chromeCoverage(_ annotation: Annotation) -> CGRect {
        var rect = viewRect(for: annotation.bounds)
        for point in AnnotationGeometry.handles(for: annotation).values {
            rect = rect.union(CGRect(origin: viewPoint(for: point), size: .zero))
        }
        return rect.insetBy(dx: -(DS.Overlay.handleSize / 2 + 4), dy: -(DS.Overlay.handleSize / 2 + 4))
    }

    private func currentCoverage() -> CGRect {
        var rect = overlayAnnotations.reduce(CGRect.null) { $0.union(coverage(of: $1)) }
        if let target = editor?.chromeTarget { rect = rect.union(chromeCoverage(target)) }
        return rect
    }

    private func invalidateOverlay(all: Bool = false) {
        guard plan != nil else { return }
        let draft = editor?.draft
        defer { lastDraft = draft }
        if all {
            let coverage = currentCoverage()
            dirty(overlayCoverage.union(coverage))
            overlayCoverage = coverage
            return
        }
        // A growing freehand stroke only changes near its tail.
        if case .freehand(let new)? = draft, case .freehand(let old)? = lastDraft, new.id == old.id, new.points.count > old.points.count,
           old.points.count >= 2 {
            let tail = new.points[max(old.points.count - 3, 0)...]
            var box = CGRect(origin: tail.first!.raw, size: .zero)
            for p in tail { box = box.union(CGRect(origin: p.raw, size: .zero)) }
            let pad = new.lineWidth / 2
            let dirtyRect = viewRect(for: DocumentRect(box.insetBy(dx: -pad, dy: -pad))).insetBy(dx: -3, dy: -3)
            dirty(dirtyRect)
            overlayCoverage = overlayCoverage.union(dirtyRect)
            return
        }
        let coverage = currentCoverage()
        dirty(overlayCoverage.union(coverage))
        overlayCoverage = coverage
    }

    /// Overlay region invalidated since the last overlay draw.
    private(set) var pendingOverlayDirty: CGRect = .null

    private func dirty(_ rect: CGRect) {
        let clipped = rect.intersection(overlayView.bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        pendingOverlayDirty = pendingOverlayDirty.union(clipped.integral)
        overlayView.setNeedsDisplay(clipped.integral)
    }

    func overlayDidDraw() { pendingOverlayDirty = .null }

    func drawOverlay(in context: CGContext) {
        guard let plan, let session, let editor else { return }
        let items = overlayAnnotations
        if !items.isEmpty {
            context.saveGState()
            context.scaleBy(x: contentScale, y: contentScale)
            let offset = documentOffset
            let clip = DocumentRect(context.boundingBoxOfClipPath.offsetBy(dx: -offset.x, dy: -offset.y))
            let layers: [RenderLayer] = items.map { Self.trimmed($0, to: clip) }.map { annotation in
                annotation.role == .redaction
                    ? .redactions([PlacedRedaction(
                        id: annotation.id, frame: CanvasRect(annotation.bounds.raw.offsetBy(dx: offset.x, dy: offset.y)), source: annotation.bounds,
                        style: Self.redactionStyle(annotation))])
                    : .decorations([PlacedAnnotation(annotation: annotation, offsetX: offset.x, offsetY: offset.y)])
            }
            let overlayPlan = RenderPlan(
                session: plan.session, editRevision: plan.editRevision, canvas: plan.canvas, scale: plan.scale,
                background: .transparent, layers: layers, contentFrame: plan.contentFrame
            )
            render.draw(overlayPlan, base: session.baseImage, in: context)
            context.restoreGState()
        }
        if let target = editor.chromeTarget { drawSelection(target, in: context) }
    }

    /// A long freehand stroke redrawn for a small dirty region keeps only the points near it (three extra on each side,
    /// so the smoothed curve inside the region is unchanged).
    static func trimmed(_ annotation: Annotation, to clip: DocumentRect) -> Annotation {
        guard case .freehand(var path) = annotation, path.points.count > 64 else { return annotation }
        let box = clip.raw.insetBy(dx: -path.lineWidth, dy: -path.lineWidth)
        var lower: Int?, upper = 0
        for i in 0..<(path.points.count - 1) {
            let a = path.points[i].raw, b = path.points[i + 1].raw
            let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard segment.insetBy(dx: -0.5, dy: -0.5).intersects(box) else { continue }
            if lower == nil { lower = i }
            upper = i + 1
        }
        guard let lower else { return annotation }
        let range = max(lower - 3, 0)...min(upper + 3, path.points.count - 1)
        guard range.count < path.points.count else { return annotation }
        path.points = Array(path.points[range])
        return .freehand(path)
    }

    private static func redactionStyle(_ annotation: Annotation) -> RedactionStyle {
        switch annotation {
        case .mosaic(let m): .mosaic(blockSize: m.blockSize)
        case .redaction(let r): .solid(r.fill)
        default: .solid(.black)
        }
    }

    private func drawSelection(_ annotation: Annotation, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let bounds = viewRect(for: annotation.bounds).insetBy(dx: -2, dy: -2)
        context.setStrokeColor(accent)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(bounds)
        context.setLineDash(phase: 0, lengths: [])
        let size = DS.Overlay.handleSize
        for (handle, point) in AnnotationGeometry.handles(for: annotation) {
            let p = viewPoint(for: point)
            let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            context.setFillColor(handle == .pointer ? accent : NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(handle == .pointer ? NSColor.white.cgColor : accent)
            context.strokeEllipse(in: rect)
        }
    }

    // MARK: Events

    override public func mouseDown(with event: NSEvent) {
        guard let editor else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        let point = documentPoint(for: convert(event.locationInWindow, from: nil))
        editor.mouseDown(at: point, clickCount: event.clickCount, constrain: event.modifierFlags.contains(.command))
        updateCursor(at: point)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let editor else { return super.mouseDragged(with: event) }
        editor.mouseDragged(to: documentPoint(for: convert(event.locationInWindow, from: nil)), constrain: event.modifierFlags.contains(.command))
    }

    override public func mouseUp(with event: NSEvent) {
        guard let editor else { return super.mouseUp(with: event) }
        let point = documentPoint(for: convert(event.locationInWindow, from: nil))
        editor.mouseUp(at: point)
        updateCursor(at: point)
    }

    /// Handles and annotations under the pointer get resize and move cursors (ANN-14).
    override public func mouseMoved(with event: NSEvent) {
        guard editor != nil else { return super.mouseMoved(with: event) }
        updateCursor(at: documentPoint(for: convert(event.locationInWindow, from: nil)))
    }

    override public func cursorUpdate(with event: NSEvent) {
        guard editor != nil else { return super.cursorUpdate(with: event) }
        updateCursor(at: documentPoint(for: convert(event.locationInWindow, from: nil)))
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard editor != nil else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    private var currentCursor: CanvasCursor?

    private func updateCursor(at point: DocumentPoint) {
        guard let editor, editor.textEditing == nil || !(textField?.frame.contains(viewPoint(for: point)) ?? false) else { return }
        let cursor = editor.cursor(at: point)
        guard cursor != currentCursor else { return }
        currentCursor = cursor
        Self.nsCursor(cursor).set()
    }

    static func nsCursor(_ cursor: CanvasCursor) -> NSCursor {
        switch cursor {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .iBeam: .iBeam
        case .move: .openHand
        case .moving: .closedHand
        case .resize(let handle):
            switch handle {
            case .topLeft: .frameResize(position: .topLeft, directions: .all)
            case .top: .frameResize(position: .top, directions: .all)
            case .topRight: .frameResize(position: .topRight, directions: .all)
            case .right: .frameResize(position: .right, directions: .all)
            case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
            case .bottom: .frameResize(position: .bottom, directions: .all)
            case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
            case .left: .frameResize(position: .left, directions: .all)
            case .start, .end, .pointer: .crosshair
            }
        }
    }

    override public func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
        if editor.textEditing == nil, keyHandler?(event) == true { return }
        if event.keyCode == 53 {
            if !editor.cancelStep() { onEscapeUnhandled?() }
            return
        }
        if !editor.handleKey(event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags) {
            super.keyDown(with: event)
        }
    }

    override public func resetCursorRects() {
        guard let editor else { return }
        let cursor: NSCursor = switch editor.tool {
        case .text?: .iBeam
        case nil: .arrow
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
        currentCursor = nil
    }

    // MARK: Inline text (ANN-08)

    private func syncTextField() {
        guard let editor else { return }
        guard let editing = editor.textEditing else {
            if let textField {
                let wasFocused = window?.firstResponder === textField.currentEditor()
                textField.removeFromSuperview()
                self.textField = nil
                if wasFocused { window?.makeFirstResponder(self) }
            }
            return
        }
        textField?.removeFromSuperview()
        let field = NSTextField()
        field.isBordered = true
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        field.focusRingType = .default
        field.delegate = self
        field.stringValue = editing.text
        field.setAccessibilityLabel(editor.labelForTextField)
        let fontSize = max(editing.fontSize * contentScale, 9)
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(srgbRed: editing.color.red, green: editing.color.green, blue: editing.color.blue, alpha: 1)
        let origin = viewPoint(for: editing.anchor)
        field.frame = CGRect(x: origin.x, y: origin.y, width: max(160, bounds.maxX - origin.x - 4), height: fontSize * 1.5)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        editor?.textEditing?.text = field.stringValue
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            editor?.textEditing?.text = textView.string
            editor?.commitText()
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.cancelText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    // MARK: Accessibility (each annotation is exposed as an element, SPEC §05 §6)

    private func updateAccessibility() {
        guard let session else { return }
        let elements: [NSAccessibilityElement] = session.annotations.map { annotation in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(editor?.accessibilityName(annotation.kind) ?? annotation.kind.rawValue)
            element.setAccessibilityFrameInParentSpace(viewRect(for: annotation.bounds))
            return element
        }
        setAccessibilityChildren(elements)
    }
}

extension AnnotationEditor {
    var labelForTextField: String { labelProvider("tool.text") }
    func accessibilityName(_ kind: AnnotationKind) -> String { labelProvider("tool.\(kind.rawValue)") }
}
