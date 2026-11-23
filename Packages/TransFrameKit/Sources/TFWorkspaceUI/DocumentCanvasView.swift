import AppKit
import Observation
import QuartzCore
import SwiftUI
import TFDesignSystem
import TFDomain

/// Layer-backed canvas that shows a session through the single render executor (ADR-0006) and hosts the
/// shared annotation interaction. Selection handles and drafts are UI overlays and never exported.
@MainActor
public final class DocumentCanvasView: NSView, NSTextFieldDelegate {
    public let editor: AnnotationEditor?
    private let render: any RenderWorkflow
    private let sessionID: SessionID
    private let purpose: RenderPurpose
    public private(set) var session: DocumentSession?
    public private(set) var plan: RenderPlan?
    private let imageLayer = CALayer()
    private var renderTask: Task<Void, Never>?
    private var renderedKey: (revision: Int, hidden: AnnotationID?, translation: Bool)?
    private var textField: NSTextField?
    /// Called after each committed render (pins and previews resize from it).
    public var onRender: ((RenderPlan) -> Void)?
    public var onEscapeUnhandled: (() -> Void)?

    public init(render: any RenderWorkflow, sessionID: SessionID, editor: AnnotationEditor?, purpose: RenderPurpose = .screen) {
        self.render = render
        self.sessionID = sessionID
        self.editor = editor
        self.purpose = purpose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        setAccessibilityRole(.image)
        observeEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { editor != nil }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func update(_ session: DocumentSession) {
        self.session = session
        editor?.update(session)
        scheduleRender()
        updateAccessibility()
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: Rendering

    private func scheduleRender(force: Bool = false) {
        guard let session else { return }
        let hidden = editor?.hiddenID
        let key = (session.editRevision, hidden, session.presentation.showsTranslationOverlay && session.translation != nil)
        if !force, let renderedKey, renderedKey.revision == key.0, renderedKey.hidden == key.1, renderedKey.translation == key.2,
           session.translation == nil || renderedKey.translation == key.2 {
            return
        }
        renderTask?.cancel()
        let render = render, id = sessionID, purpose = purpose, base = session.baseImage
        renderTask = Task { [weak self] in
            guard let plan = try? await render.plan(for: id, purpose: purpose, excluding: hidden.map { [$0] } ?? []) else { return }
            let image = await Self.rasterize(plan, base: base, render: render)
            guard !Task.isCancelled, let self else { return }
            self.plan = plan
            self.renderedKey = key
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = image
            CATransaction.commit()
            self.needsDisplay = true
            self.onRender?(plan)
        }
    }

    /// Off the main actor: draws a plan into a bitmap with the shared executor.
    nonisolated static func rasterize(_ plan: RenderPlan, base: PixelImage, render: any RenderWorkflow) async -> CGImage? {
        guard let context = CGContext(
            data: nil, width: plan.canvas.width, height: plan.canvas.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: base.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) ?? CGContext(
            data: nil, width: plan.canvas.width, height: plan.canvas.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(plan.canvas.height))
        context.scaleBy(x: 1, y: -1)
        render.draw(plan, base: base, in: context)
        return context.makeImage()
    }

    private func observeEditor() {
        guard let editor else { return }
        withObservationTracking {
            _ = editor.draft
            _ = editor.selectedID
            _ = editor.hiddenID
            _ = editor.textEditing
            _ = editor.tool
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleRender()
                self.syncTextField()
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
                self.observeEditor()
            }
        }
    }

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

    // MARK: Overlay drawing (drafts, selection)

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let plan, let session, let editor else { return }
        if let draft = editor.draft {
            context.saveGState()
            context.scaleBy(x: contentScale, y: contentScale)
            let offset = documentOffset
            let layer: RenderLayer = draft.role == .redaction
                ? .redactions([PlacedRedaction(
                    id: draft.id, frame: CanvasRect(draft.bounds.raw.offsetBy(dx: offset.x, dy: offset.y)), source: draft.bounds,
                    style: { if case .mosaic(let m) = draft { .mosaic(blockSize: m.blockSize) } else if case .redaction(let r) = draft { .solid(r.fill) } else { .solid(.black) } }()
                )])
                : .decorations([PlacedAnnotation(annotation: draft, offsetX: offset.x, offsetY: offset.y)])
            let overlayPlan = RenderPlan(
                session: plan.session, editRevision: plan.editRevision, canvas: plan.canvas, scale: plan.scale,
                background: .transparent, layers: [layer], contentFrame: plan.contentFrame
            )
            render.draw(overlayPlan, base: session.baseImage, in: context)
            context.restoreGState()
        }
        if editor.draft == nil, let selected = editor.selected {
            drawSelection(selected, in: context)
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
        for point in AnnotationGeometry.handles(for: annotation).values {
            let p = viewPoint(for: point)
            let handle = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handle)
            context.setStrokeColor(accent)
            context.strokeEllipse(in: handle)
        }
    }

    // MARK: Events

    override public func mouseDown(with event: NSEvent) {
        guard let editor else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        let point = documentPoint(for: convert(event.locationInWindow, from: nil))
        editor.mouseDown(at: point, clickCount: event.clickCount, constrain: event.modifierFlags.contains(.command))
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let editor else { return super.mouseDragged(with: event) }
        let point = documentPoint(for: convert(event.locationInWindow, from: nil))
        editor.mouseDragged(to: point, constrain: event.modifierFlags.contains(.command))
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        guard let editor else { return super.mouseUp(with: event) }
        editor.mouseUp(at: documentPoint(for: convert(event.locationInWindow, from: nil)))
        needsDisplay = true
    }

    override public func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
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
        case .text?, .callout?: .iBeam
        case nil: .arrow
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Inline text (ANN-08)

    private func syncTextField() {
        guard let editor else { return }
        guard let editing = editor.textEditing else {
            textField?.removeFromSuperview()
            textField = nil
            return
        }
        let field = textField ?? NSTextField()
        if textField == nil {
            field.isBordered = true
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
            field.focusRingType = .default
            field.delegate = self
            field.stringValue = editing.text
            field.setAccessibilityLabel(editor.labelForTextField)
            addSubview(field)
            textField = field
        }
        let fontSize = max(editing.fontSize * contentScale, 9)
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(srgbRed: editing.color.red, green: editing.color.green, blue: editing.color.blue, alpha: 1)
        let origin = viewPoint(for: editing.anchor)
        field.frame = CGRect(x: origin.x, y: origin.y, width: max(160, bounds.maxX - origin.x - 4), height: fontSize * 1.5)
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
            editor?.textEditing = nil
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
